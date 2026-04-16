const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;
const Input = @import("Input.zig");

const Camera = @This();

focal_length: f32 = 1.0, // `> 0.0`
z_near: f32 = 0.01,
z_far: f32 = 100_000.0, // `> z_near`

pos: math.Vec3 = .{ .x = 7_920.0, .y = 10_000.0, .z = 11_160.0 },

yaw: f32 = 0.0,
pitch: f32 = -0.5 * std.math.pi + 1.0e-6, // in [-0.5pi + 1.0e-6, 0.5pi - 1.0e-6]

move_speed: f32 = 5.0, // meters per second
rotate_sensitivity: f32 = std.math.pi,
zoom_sensitivity: f32 = 300.0,

// Reads are valid iff `input.mouse_right_down != null`
yaw_drag_start: f32 = undefined,
pitch_drag_start: f32 = undefined,

// `terrain_grab != null` only if `input.mouse_middle_down != null`
terrain_grab: ?math.Vec3 = null,

uniform: ?*c.WGPUBufferImpl = null,
uniform_bg: ?*c.WGPUBindGroupImpl = null,

pub fn update(
    self: *Camera,
    input: Input,
    window_width: u32,
    window_height: u32,
    dt: f32,
) void {
    std.debug.assert(window_width >= 1);
    std.debug.assert(window_height >= 1);

    // TODO: Add easing animations

    // Rotate
    if (input.mouse_right_down) |mrd| blk: {
        if (mrd.just_pressed) {
            self.yaw_drag_start = self.yaw;
            self.pitch_drag_start = self.pitch;
            break :blk;
        }
        const offset_x: f32 = @floatCast(input.cursor_pos.x - mrd.down_pos.x);
        const offset_y: f32 = @floatCast(input.cursor_pos.y - mrd.down_pos.y);
        self.yaw =
            self.yaw_drag_start -
            offset_x / @as(f32, @floatFromInt(window_height)) *
                self.rotate_sensitivity;
        self.pitch =
            self.pitch_drag_start -
            offset_y / @as(f32, @floatFromInt(window_height)) *
                self.rotate_sensitivity;
        self.pitch =
            std.math.clamp(
                self.pitch,
                -std.math.pi * 0.5 + 1.0e-6,
                std.math.pi * 0.5 - 1.0e-6,
            );
    }

    // Zoom
    const aspect =
        @as(f32, @floatFromInt(window_width)) /
        @as(f32, @floatFromInt(window_height));
    const cursor_ndc = input.cursorNdc(window_width, window_height);
    const along =
        self.rotateVec((math.Vec3{
            .x = cursor_ndc.x * aspect,
            .y = cursor_ndc.y,
            .z = self.focal_length,
        }).normalize());
    self.pos =
        self.pos.add(along.scale(input.scroll_dy * self.zoom_sensitivity));

    // Move by key press
    const forward = self.forwardVec();
    const right = self.rightVec();
    const up: math.Vec3 = .unit_y;
    const speed = self.move_speed * dt;

    var direction: math.Vec3 = .zero;

    if (input.move_forward) {
        direction = direction.add(forward);
    }
    if (input.move_backward) {
        direction = direction.sub(forward);
    }
    if (input.move_left) {
        direction = direction.sub(right);
    }
    if (input.move_right) {
        direction = direction.add(right);
    }
    if (input.move_up) {
        direction = direction.add(up);
    }
    if (input.move_down) {
        direction = direction.sub(up);
    }

    if (direction.mag2() > 1.0e-6) {
        self.pos = self.pos.add(direction.normalize().scale(speed));
    }

    // Move by panning
    if (input.mouse_middle_down == null) {
        self.terrain_grab = null;
    }
    if (self.terrain_grab) |tg| blk: {
        const camera_ray = self.rayFromCursor(cursor_ndc, aspect);
        const t = camera_ray.intersectXZPlane(tg.y) orelse break :blk;
        if (t < 1.0e-6) {
            break :blk;
        }
        const intersection = camera_ray.at(t);
        self.pos = self.pos.sub(intersection.sub(tg));
    }
}

pub const Uniform = extern struct {
    view: math.Mat4,
    proj: math.Mat4,
};

// Uniform buffer is not yet written to; call `upload` to write to it
pub fn initGpu(
    self: *Camera,
    device: *c.WGPUDeviceImpl,
) *c.WGPUBindGroupLayoutImpl {
    self.uniform =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("camera"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(Uniform),
        }) orelse @panic("ERROR: Failed to create camera uniform buffer");

    const bg_layout =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("camera"),
            .entryCount = 1,
            .entries = &.{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Vertex,
                .buffer = .{
                    .type = c.WGPUBufferBindingType_Uniform,
                    .minBindingSize = @sizeOf(Uniform),
                },
            },
        }) orelse
        @panic("ERROR: Failed to create camera uniform bind group layout");

    self.uniform_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("camera"),
            .layout = bg_layout,
            .entryCount = 1,
            .entries = &.{
                .binding = 0,
                .buffer = self.uniform,
                .offset = 0,
                .size = @sizeOf(Uniform),
            },
        }) orelse @panic("ERROR: Failed to create camera uniform bind group");

    return bg_layout;
}

pub fn deinitGpu(self: Camera) void {
    if (self.uniform_bg) |ubg| c.wgpuBindGroupRelease(ubg);
    if (self.uniform) |u| {
        c.wgpuBufferDestroy(u);
        c.wgpuBufferRelease(u);
    }
}

pub fn upload(self: Camera, queue: *c.WGPUQueueImpl, aspect: f32) void {
    const view = self.viewMat();
    const proj = self.projMat(aspect);
    const uniform: Uniform = .{
        .view = view,
        .proj = proj,
    };
    c.wgpuQueueWriteBuffer(
        queue,
        self.uniform,
        0,
        &uniform,
        @sizeOf(Uniform),
    );
}

pub fn rayFromCursor(self: Camera, cursor_ndc: math.Vec2, aspect: f32) math.Ray3 {
    const inv_view_proj = self.projMat(aspect).mul(self.viewMat()).invert();

    const near_h =
        inv_view_proj.apply(.{
            .x = cursor_ndc.x,
            .y = cursor_ndc.y,
            .z = 1.0,
            .w = 1.0,
        });
    const far_h =
        inv_view_proj.apply(.{
            .x = cursor_ndc.x,
            .y = cursor_ndc.y,
            .z = 0.0,
            .w = 1.0,
        });

    const near = near_h.xyz().scale(1.0 / near_h.w);
    const far = far_h.xyz().scale(1.0 / far_h.w);

    const dir = far.sub(near).normalize();

    return .{
        .origin = near,
        .dir = dir,
    };
}

pub fn viewMat(self: Camera) math.Mat4 {
    const dx = -self.pos.x;
    const dy = -self.pos.y;
    const dz = -self.pos.z;
    const translate: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
                .{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 0.0 },
                .{ .x = 0.0, .y = 1.0, .z = 0.0, .w = 0.0 },
                .{ .x = 0.0, .y = 0.0, .z = 1.0, .w = 0.0 },
                .{ .x = dx,  .y = dy,  .z = dz,  .w = 1.0 },
            },
        // zig fmt: on
    };

    const cos_yaw = @cos(self.yaw);
    const sin_yaw = @sin(self.yaw);
    const rotate_yaw: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .{ .x = cos_yaw, .y = 0.0, .z = -sin_yaw, .w = 0.0 },
            .{ .x = 0.0,     .y = 1.0, .z = 0.0,      .w = 0.0 },
            .{ .x = sin_yaw, .y = 0.0, .z = cos_yaw,  .w = 0.0 },
            .{ .x = 0.0,     .y = 0.0, .z = 0.0,      .w = 1.0 },
        },
        // zig fmt: on
    };

    const cos_pitch = @cos(self.pitch);
    const sin_pitch = @sin(self.pitch);
    const rotate_pitch: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .{ .x = 1.0, .y = 0.0,        .z = 0.0,       .w = 0.0 },
            .{ .x = 0.0, .y = cos_pitch,  .z = sin_pitch, .w = 0.0 },
            .{ .x = 0.0, .y = -sin_pitch, .z = cos_pitch, .w = 0.0 },
            .{ .x = 0.0, .y = 0.0,        .z = 0.0,       .w = 1.0 },
        },
        // zig fmt: on
    };

    return rotate_pitch.mul(rotate_yaw.mul(translate));
}

pub fn projMat(self: Camera, aspect: f32) math.Mat4 {
    const proj_00 = self.focal_length / aspect;
    const proj_11 = self.focal_length;
    const proj_22 = self.z_near / (self.z_near - self.z_far);
    const proj_32 = -proj_22 * self.z_far;
    return .{
        // zig fmt: off
        .cols = .{
                .{ .x = proj_00, .y = 0.0,     .z = 0.0,     .w = 0.0 },
                .{ .x = 0.0,     .y = proj_11, .z = 0.0,     .w = 0.0 },
                .{ .x = 0.0,     .y = 0.0,     .z = proj_22, .w = 1.0 },
                .{ .x = 0.0,     .y = 0.0,     .z = proj_32, .w = 0.0 },
            },
        // zig fmt: on
    };
}

fn rotateVec(self: Camera, v: math.Vec3) math.Vec3 {
    const rotate_yaw: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .{ .x = @cos(self.yaw),  .y = 0.0, .z = @sin(self.yaw), .w = 0.0 },
            .{ .x = 0.0,             .y = 1.0, .z = 0.0,            .w = 0.0 },
            .{ .x = -@sin(self.yaw), .y = 0.0, .z = @cos(self.yaw), .w = 0.0 },
            .{ .x = 0.0,             .y = 0.0, .z = 0.0,            .w = 1.0 },
        },
        // zig fmt: on
    };

    const rotate_pitch: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .{ .x = 1.0, .y = 0.0,              .z = 0.0,               .w = 0.0 },
            .{ .x = 0.0, .y = @cos(self.pitch), .z = -@sin(self.pitch), .w = 0.0 },
            .{ .x = 0.0, .y = @sin(self.pitch), .z = @cos(self.pitch),  .w = 0.0 },
            .{ .x = 0.0, .y = 0.0,              .z = 0.0,               .w = 1.0 },
        },
        // zig fmt: on
    };

    const rotate = rotate_yaw.mul(rotate_pitch);
    const rotated_v = rotate.apply(.{ .x = v.x, .y = v.y, .z = v.z, .w = 0.0 });
    return .{ .x = rotated_v.x, .y = rotated_v.y, .z = rotated_v.z };
}

fn forwardVec(self: Camera) math.Vec3 {
    return self.rotateVec(.{ .x = 0.0, .y = 0.0, .z = 1.0 });
}

fn rightVec(self: Camera) math.Vec3 {
    return self.rotateVec(.{ .x = 1.0, .y = 0.0, .z = 0.0 });
}
