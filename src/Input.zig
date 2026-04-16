const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;
const Application = @import("Application.zig");

const Input = @This();

move_forward: bool = false, // W
move_left: bool = false, // A
move_backward: bool = false, // S
move_right: bool = false, // D
move_up: bool = false, // SPACE
move_down: bool = false, // LEFT SHIFT

cursor_pos: struct { x: f64, y: f64 } = undefined,

mouse_middle_down: ?struct {
    just_pressed: bool = true,
} = null,
mouse_right_down: ?struct {
    just_pressed: bool = true,
    down_pos: struct { x: f64, y: f64 },
} = null,

scroll_dy: f32 = 0.0,

uniform: *c.WGPUBufferImpl = undefined,
uniform_bg: *c.WGPUBindGroupImpl = undefined,

pub fn init(self: *Input, window: *c.GLFWwindow) void {
    var cursor_pos_x: f64 = undefined;
    var cursor_pos_y: f64 = undefined;
    c.glfwGetCursorPos(window, &cursor_pos_x, &cursor_pos_y);
    self.cursor_pos = .{
        .x = cursor_pos_x,
        .y = cursor_pos_y,
    };
}

pub const Uniform = struct {
    cursor_pos: extern struct { x: u32, y: u32 }, // in framebuffer units
};

// Uniform buffer is not yet written to; call `upload` to write to it
pub fn initGpu(self: *Input, device: *c.WGPUDeviceImpl) *c.WGPUBindGroupLayoutImpl {
    self.uniform =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("input"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(Uniform),
        }) orelse @panic("ERROR: Failed to create input uniform buffer");

    const bg_layout =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("input"),
            .entryCount = 1,
            .entries = &.{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Compute,
                .buffer = .{
                    .type = c.WGPUBufferBindingType_Uniform,
                    .minBindingSize = @sizeOf(Uniform),
                },
            },
        }) orelse
        @panic("ERROR: Failed to create input uniform bind group layout");

    self.uniform_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("input"),
            .layout = bg_layout,
            .entryCount = 1,
            .entries = &.{
                .binding = 0,
                .buffer = self.uniform,
                .offset = 0,
                .size = @sizeOf(Uniform),
            },
        }) orelse @panic("ERROR: Failed to create input uniform bind group");

    return bg_layout;
}

// No deinit; browser takes care of cleanup

pub fn upload(
    self: Input,
    queue: *c.WGPUQueueImpl,
    window_width_scale: u32,
    window_height_scale: u32,
) void {
    const uniform: Uniform =
        .{ .cursor_pos = .{
            .x = @intFromFloat(
                self.cursor_pos.x * @as(f64, @floatFromInt(window_width_scale)),
            ),
            .y = @intFromFloat(
                self.cursor_pos.y * @as(f64, @floatFromInt(window_height_scale)),
            ),
        } };
    c.wgpuQueueWriteBuffer(
        queue,
        self.uniform,
        0,
        &uniform,
        @sizeOf(Uniform),
    );
}

pub fn attachToApp(_: Input, app: *Application) void {
    c.glfwSetWindowUserPointer(app.window, app);
    _ = c.glfwSetCursorPosCallback(app.window, cursorPosCallback);
    _ = c.glfwSetCursorEnterCallback(app.window, cursorEnterCallback);
    _ = c.glfwSetMouseButtonCallback(app.window, mouseButtonCallback);
    _ = c.glfwSetScrollCallback(app.window, scrollCallback);
    _ = c.glfwSetKeyCallback(app.window, keyCallback);
}

pub fn reset(self: *Input) void {
    if (self.mouse_middle_down) |*mmd| {
        mmd.just_pressed = false;
    }
    if (self.mouse_right_down) |*mrd| {
        mrd.just_pressed = false;
    }
    self.scroll_dy = 0.0;
}

pub fn cursorNdc(self: Input, window_width: u32, window_height: u32) math.Vec2 {
    return .{
        .x = @as(f32, @floatCast(self.cursor_pos.x /
            @as(f64, @floatFromInt(window_width)))) * 2.0 - 1.0,
        .y = 1.0 - @as(f32, @floatCast(self.cursor_pos.y /
            @as(f64, @floatFromInt(window_height)))) * 2.0,
    };
}

pub fn middleMouseButtonJustPressed(self: Input) bool {
    if (self.mouse_middle_down) |mmd| {
        if (mmd.just_pressed) {
            return true;
        }
    }
    return false;
}

fn cursorPosCallback(window: ?*c.GLFWwindow, x: f64, y: f64) callconv(.c) void {
    std.debug.assert(window != null);
    const app: *Application =
        @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
    app.input.cursor_pos = .{
        .x = x,
        .y = y,
    };
}

fn cursorEnterCallback(window: ?*c.GLFWwindow, entered: c_int) callconv(.c) void {
    std.debug.assert(window != null);
    const app: *Application =
        @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
    const cursor_exit = entered == c.GLFW_FALSE;
    if (cursor_exit) {
        app.input.mouse_middle_down = null;
        app.input.mouse_right_down = null;
    }
}

fn mouseButtonCallback(
    window: ?*c.GLFWwindow,
    button: c_int,
    action: c_int,
    mods: c_int,
) callconv(.c) void {
    _ = mods;
    std.debug.assert(window != null);
    const app: *Application =
        @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
    if (button == c.GLFW_MOUSE_BUTTON_RIGHT) blk: {
        if (action == c.GLFW_RELEASE) {
            app.input.mouse_right_down = null;
            break :blk;
        }
        std.debug.assert(action == c.GLFW_PRESS);

        app.input.mouse_right_down =
            .{ .down_pos = .{
                .x = app.input.cursor_pos.x,
                .y = app.input.cursor_pos.y,
            } };
    } else if (button == c.GLFW_MOUSE_BUTTON_MIDDLE) blk: {
        if (action == c.GLFW_RELEASE) {
            app.input.mouse_middle_down = null;
            break :blk;
        }
        std.debug.assert(action == c.GLFW_PRESS);

        app.input.mouse_middle_down = .{};
    }
}

fn scrollCallback(window: ?*c.GLFWwindow, dx: f64, dy: f64) callconv(.c) void {
    std.debug.assert(window != null);
    _ = dx;
    const app: *Application =
        @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));
    app.input.scroll_dy += @floatCast(dy);
}

fn keyCallback(
    window: ?*c.GLFWwindow,
    key: c_int,
    scancode: c_int,
    action: c_int,
    mods: c_int,
) callconv(.c) void {
    _ = scancode;
    _ = mods;
    std.debug.assert(window != null);
    const app: *Application =
        @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window)));

    const pressed =
        switch (action) {
            c.GLFW_PRESS, c.GLFW_REPEAT => true,
            c.GLFW_RELEASE => false,
            else => unreachable,
        };

    switch (key) {
        c.GLFW_KEY_W => app.input.move_forward = pressed,
        c.GLFW_KEY_A => app.input.move_left = pressed,
        c.GLFW_KEY_S => app.input.move_backward = pressed,
        c.GLFW_KEY_D => app.input.move_right = pressed,
        c.GLFW_KEY_SPACE => app.input.move_up = pressed,
        c.GLFW_KEY_LEFT_SHIFT => app.input.move_down = pressed,
        else => {},
    }
}
