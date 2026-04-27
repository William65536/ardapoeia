const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;
const Input = @import("Input.zig");

const Camera = @This();

aspect: f32 = undefined,
focal_length: f32 = 1.0, // `> 0.0`
// TODO: Center world around camera instead
z_near: f32 = 0.01,
z_far: f32 = 100_000.0, // `> z_near`

pos: math.Vec3 = .init(0.0, 1_000.0, 0.0),

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

initialized_count: u32 = 0,
uniform: *c.WGPUBufferImpl = undefined,
uniform_bg: *c.WGPUBindGroupImpl = undefined,

pub fn update(
    self: *Camera,
    input: Input,
    window_width: u32,
    window_height: u32,
    dt: f32,
) bool {
    std.debug.assert(window_width >= 1);
    std.debug.assert(window_height >= 1);

    // TODO: Add easing animations

    const prev_aspect = self.aspect;
    const prev_pos = self.pos;
    const prev_yaw = self.yaw;
    const prev_pitch = self.pitch;

    self.aspect =
        @as(f32, @floatFromInt(window_width)) /
        @as(f32, @floatFromInt(window_height));
    const cursor_ndc = input.cursorNdc(window_width, window_height);

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
    if (input.scroll_dy != 0.0) {
        const along =
            self.rotateVec((math.Vec3{
                .x = cursor_ndc.x * self.aspect,
                .y = cursor_ndc.y,
                .z = self.focal_length,
            }).normalize());
        self.pos =
            self.pos.add(along.scale(input.scroll_dy * self.zoom_sensitivity));
    }

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
        const camera_ray = self.rayFromCursor(cursor_ndc);
        const t = camera_ray.intersectXZPlane(tg.y) orelse break :blk;
        if (t < 1.0e-6) {
            break :blk;
        }
        const intersection = camera_ray.at(t);
        self.pos = self.pos.sub(intersection.sub(tg));
    }

    return self.aspect != prev_aspect or self.yaw != prev_yaw or
        self.pitch != prev_pitch or !std.meta.eql(self.pos, prev_pos);
}

pub const Uniform = extern struct {
    view_proj: math.Mat4,
};

// Uniform buffer is not yet written to; call `upload` to write to it
pub fn initGpu(
    self: *Camera,
    device: *c.WGPUDeviceImpl,
) *c.WGPUBindGroupLayoutImpl {
    std.debug.assert(self.initialized_count == 0);

    self.uniform =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("camera"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(Uniform),
        }) orelse @panic("ERROR: Failed to create camera uniform buffer");
    self.initialized_count += 1;

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
    self.initialized_count += 1;

    return bg_layout;
}

pub fn deinitGpu(self: Camera) void {
    var initialized_threshold: u32 = 0;
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBufferRelease(self.uniform);
    defer c.wgpuBufferDestroy(self.uniform);
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBindGroupRelease(self.uniform_bg);
}

pub fn upload(self: Camera, queue: *c.WGPUQueueImpl) void {
    const view_proj = self.viewProjMat();
    const uniform: Uniform = .{
        .view_proj = view_proj,
    };
    c.wgpuQueueWriteBuffer(
        queue,
        self.uniform,
        0,
        &uniform,
        @sizeOf(Uniform),
    );
}

pub fn rayFromCursor(self: Camera, cursor_ndc: math.Vec2) math.Ray3 {
    const inv_view_proj = self.projMat().mul(self.viewMat()).invert();

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
                .init(1.0, 0.0, 0.0, 0.0),
                .init(0.0, 1.0, 0.0, 0.0),
                .init(0.0, 0.0, 1.0, 0.0),
                .init(dx,  dy,  dz,  1.0),
            },
        // zig fmt: on
    };

    const cos_yaw = @cos(self.yaw);
    const sin_yaw = @sin(self.yaw);
    const rotate_yaw: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .init(cos_yaw, 0.0, -sin_yaw, 0.0),
            .init(0.0,     1.0, 0.0,      0.0),
            .init(sin_yaw, 0.0, cos_yaw,  0.0),
            .init(0.0,     0.0, 0.0,      1.0),
        },
        // zig fmt: on
    };

    const cos_pitch = @cos(self.pitch);
    const sin_pitch = @sin(self.pitch);
    const rotate_pitch: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .init(1.0, 0.0,        0.0,       0.0),
            .init(0.0, cos_pitch,  sin_pitch, 0.0),
            .init(0.0, -sin_pitch, cos_pitch, 0.0),
            .init(0.0, 0.0,        0.0,       1.0),
        },
        // zig fmt: on
    };

    return rotate_pitch.mul(rotate_yaw.mul(translate));
}

pub fn projMat(self: Camera) math.Mat4 {
    const proj_00 = self.focal_length / self.aspect;
    const proj_11 = self.focal_length;
    const proj_22 = self.z_near / (self.z_near - self.z_far);
    const proj_32 = -proj_22 * self.z_far;
    return .{
        // zig fmt: off
        .cols = .{
                .init(proj_00, 0.0,     0.0,     0.0),
                .init(0.0,     proj_11, 0.0,     0.0),
                .init(0.0,     0.0,     proj_22, 1.0),
                .init(0.0,     0.0,     proj_32, 0.0),
            },
        // zig fmt: on
    };
}

pub fn viewProjMat(self: Camera) math.Mat4 {
    return self.projMat().mul(self.viewMat());
}

fn rotateVec(self: Camera, v: math.Vec3) math.Vec3 {
    const rotate_yaw: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .init(@cos(self.yaw),  0.0, @sin(self.yaw), 0.0),
            .init(0.0,             1.0, 0.0,            0.0),
            .init(-@sin(self.yaw), 0.0, @cos(self.yaw), 0.0),
            .init(0.0,             0.0, 0.0,            1.0),
        },
        // zig fmt: on
    };

    const rotate_pitch: math.Mat4 = .{
        // zig fmt: off
        .cols = .{
            .init(1.0, 0.0,              0.0,               0.0),
            .init(0.0, @cos(self.pitch), -@sin(self.pitch), 0.0),
            .init(0.0, @sin(self.pitch), @cos(self.pitch),  0.0),
            .init(0.0, 0.0,              0.0,               1.0),
        },
        // zig fmt: on
    };

    const rotate = rotate_yaw.mul(rotate_pitch);
    const rotated_v = rotate.apply(.init(v.x, v.y, v.z, 0.0));
    return rotated_v.xyz();
}

fn forwardVec(self: Camera) math.Vec3 {
    return self.rotateVec(.unit_z);
}

fn rightVec(self: Camera) math.Vec3 {
    return self.rotateVec(.unit_x);
}
