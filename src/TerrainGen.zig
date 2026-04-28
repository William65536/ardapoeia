const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;
const Camera = @import("Camera.zig");
const Map = @import("Map.zig");
const Terrain = @import("Terrain.zig");

const TerrainGen = @This();

const shader_code = @embedFile("assets/shaders/terrain_gen.wgsl");

initialized_count: u32 = 0,

queue: [queue_frame_max_count]QueueFrame = undefined,
leaf_staging: [max_leaf_count]Leaf = undefined,
leaf_prev: [max_leaf_count]Leaf = undefined,
slot_freelist: [max_leaf_count]u32 = undefined,
slot_freelist_top: u32 = 0,
slot_top: u32 = 0,
leaves: *c.WGPUBufferImpl = undefined,
leaf_count: u32 = 0,
height_samples: *c.WGPUBufferImpl = undefined,

leaves_bg: *c.WGPUBindGroupImpl = undefined,
height_samples_bg: *c.WGPUBindGroupImpl = undefined,

pipeline: *c.WGPUComputePipelineImpl = undefined,

pub fn init(
    device: *c.WGPUDeviceImpl,
    lod_leaves_bg_layout_out: **c.WGPUBindGroupLayoutImpl,
) TerrainGen {
    var initialized_count: u32 = 0;

    const leaves = c.wgpuDeviceCreateBuffer(device, &.{
        .label = util.wgpu.stringView("lod leaves"),
        .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
        .size = max_leaf_count * @sizeOf(Leaf),
    }) orelse @panic("ERROR: Failed to create LOD leaves buffer");
    initialized_count += 1;

    const height_samples = c.wgpuDeviceCreateBuffer(device, &.{
        .label = util.wgpu.stringView("height samples"),
        .usage = c.WGPUBufferUsage_Storage,
        .size = height_sample_count * @sizeOf(HeightSample),
    }) orelse @panic("ERROR: Failed to create height samples buffer");
    initialized_count += 1;

    lod_leaves_bg_layout_out.* =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("lod leaves"),
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Compute | c.WGPUShaderStage_Vertex,
                .buffer = .{ .type = c.WGPUBufferBindingType_ReadOnlyStorage },
            }},
        }) orelse
        @panic("ERROR: Failed to create LOD leaves bind group layout");

    const leaves_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("lod leaves"),
            .layout = lod_leaves_bg_layout_out.*,
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupEntry{.{
                .binding = 0,
                .buffer = leaves,
                .offset = 0,
                .size = max_leaf_count * @sizeOf(Leaf),
            }},
        }) orelse
        @panic("ERROR: Failed to create LOD leaves bind group");
    initialized_count += 1;

    const height_samples_bg_layout =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("height samples"),
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Compute,
                .buffer = .{ .type = c.WGPUBufferBindingType_Storage },
            }},
        }) orelse
        @panic("ERROR: Failed to create height samples bind group layout");
    defer c.wgpuBindGroupLayoutRelease(height_samples_bg_layout);

    const height_samples_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("height samples"),
            .layout = height_samples_bg_layout,
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupEntry{.{
                .binding = 0,
                .buffer = height_samples,
                .offset = 0,
                .size = height_sample_count * @sizeOf(HeightSample),
            }},
        }) orelse
        @panic("ERROR: Failed to create height samples bind group");
    initialized_count += 1;

    const shader_module =
        c.wgpuDeviceCreateShaderModule(device, &.{
            .label = util.wgpu.stringView("terrain gen"),
            // `nextInChain` is non-const in the C API but it's never mutated
            .nextInChain = @ptrCast(@constCast(&c.WGPUShaderSourceWGSL{
                .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
                .code = util.wgpu.stringView(shader_code),
            })),
        }) orelse @panic("ERROR: Failed to create terrain gen shader module");
    defer c.wgpuShaderModuleRelease(shader_module);

    const bind_group_layouts = [_]c.WGPUBindGroupLayout{
        lod_leaves_bg_layout_out.*,
        height_samples_bg_layout,
    };

    const pipeline_layout =
        c.wgpuDeviceCreatePipelineLayout(device, &.{
            .label = util.wgpu.stringView("terrain gen"),
            .bindGroupLayoutCount = bind_group_layouts.len,
            .bindGroupLayouts = &bind_group_layouts,
        }) orelse @panic("ERROR: Failed to create terrain gen pipeline layout");
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    const pipeline =
        c.wgpuDeviceCreateComputePipeline(device, &.{
            .label = util.wgpu.stringView("terrain gen"),
            .layout = pipeline_layout,
            .compute = .{
                .module = shader_module,
                .entryPoint = util.wgpu.stringView("main"),
            },
        }) orelse
        @panic("ERROR: Failed to create terrain gen pipeline");
    initialized_count += 1;

    return .{
        .initialized_count = initialized_count,
        .leaves = leaves,
        .height_samples = height_samples,
        .leaves_bg = leaves_bg,
        .height_samples_bg = height_samples_bg,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: TerrainGen) void {
    var initialized_threshold: u32 = 0;
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBufferRelease(self.leaves);
    defer c.wgpuBufferDestroy(self.leaves);
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBufferRelease(self.height_samples);
    defer c.wgpuBufferDestroy(self.height_samples);
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBindGroupRelease(self.leaves_bg);
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBindGroupRelease(self.height_samples_bg);
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuComputePipelineRelease(self.pipeline);
}

pub fn dispatch(
    self: *TerrainGen,
    pass: c.WGPUComputePassEncoder,
    queue: *c.WGPUQueueImpl,
    map: Map,
    camera: Camera,
) void {
    const diff_count = self.buildLodQuadtree(queue, map, camera);
    if (diff_count == 0) return;

    c.wgpuComputePassEncoderSetPipeline(pass, self.pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, self.leaves_bg, 0, null);
    c.wgpuComputePassEncoderSetBindGroup(pass, 1, self.height_samples_bg, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(
        pass,
        (height_samples_per_leaf + 255) / 256,
        diff_count,
        1,
    );
}

// TODO: Contend with fixed allocations rather than crash
// TODO: Take into account vertical distance or use projected size
fn buildLodQuadtree(
    self: *TerrainGen,
    queue: *c.WGPUQueueImpl,
    map: Map,
    camera: Camera,
) u32 {
    if (map.width != map.depth or !std.math.isPowerOfTwo(map.width)) {
        @panic("TODO!");
    }

    const view_proj = camera.viewProjMat();

    var prev_count: u32 = self.leaf_count;
    @memcpy(self.leaf_prev[0..prev_count], self.leaf_staging[0..prev_count]);

    self.leaf_count = 0;
    var queue_base: u32 = 0;
    var queue_size: u32 = 0;

    // Root node centered at origin, spans entire map extent
    self.queue[0] = .{
        // Only node whose origin isn't (a * extent / 2, b * extent / 2)
        // where a and b are integers
        .origin = .zero,
    };
    queue_size += 1;

    var level = std.math.log2_int(u32, map.width) - level_0_scale;

    while (queue_size > 0) {
        const current_queue =
            self.queue[queue_base..][0..queue_size];
        queue_base = queue_size;
        queue_size = 0;

        const leaf_count_before = self.leaf_count;

        const node_extent: f32 =
            @floatFromInt(@as(i32, 1) << level + level_0_scale);
        const half_extent = node_extent * 0.5;
        const range = node_extent * range_multiplier;

        for (current_queue) |node| {
            const aabb_min: math.Vec3 = .{
                .x = node.origin.x - half_extent,
                .y = map.min_height,
                .z = node.origin.y - half_extent,
            };
            const aabb_max: math.Vec3 = .{
                .x = node.origin.x + half_extent,
                .y = map.max_height,
                .z = node.origin.y + half_extent,
            };

            if (!aabbInFrustum(aabb_min, aabb_max, view_proj)) {
                continue;
            }

            const dx = camera.pos.x - node.origin.x;
            const dz = camera.pos.z - node.origin.y;
            const dist = @sqrt(dx * dx + dz * dz);

            const subdivide = dist < range and level > 0;

            if (!subdivide) {
                if (self.leaf_count + 1 > max_leaf_count) {
                    @panic("ERROR: LOD leaves overflow");
                }
                self.leaf_staging[self.leaf_count] = .{
                    .origin = node.origin,
                    .data = .{
                        .level = level,
                        // Tentative; actually initialized below
                        .edge_flags = .{
                            .n = 0,
                            .w = 0,
                            .s = 0,
                            .e = 0,
                        },
                    },
                    .sample_slot = undefined,
                };
                self.leaf_count += 1;
                continue;
            }

            if (queue_base + queue_size + 4 > queue_frame_max_count) {
                @panic("ERROR: LOD queue overflow");
            }

            const q = half_extent * 0.5;

            const child_base = queue_base + queue_size;
            const children = self.queue[child_base..][0..4];
            children[0] = .{ .origin = node.origin.add(.init(q, q)) };
            children[1] = .{ .origin = node.origin.add(.init(-q, q)) };
            children[2] = .{ .origin = node.origin.add(.init(-q, -q)) };
            children[3] = .{ .origin = node.origin.add(.init(q, -q)) };
            queue_size += 4;
        }

        // TODO: O(n^2) is pretty poor
        const new_leaves = self.leaf_staging[leaf_count_before..self.leaf_count];
        const old_leaves = self.leaf_staging[0..leaf_count_before];
        for (new_leaves) |*new_leaf| {
            for (old_leaves) |old_leaf| {
                if (adjacent(new_leaf.*, old_leaf)) |edge| {
                    const level_delta =
                        old_leaf.data.level - new_leaf.data.level;

                    // `std.meta.fieldNames` might (?) be out of order
                    const field_names = [4][]const u8{ "n", "w", "s", "e" };
                    switch (edge) {
                        inline else => |e| {
                            const field_name = field_names[@intFromEnum(e)];
                            const flag =
                                &@field(new_leaf.data.edge_flags, field_name);
                            flag.* = @max(flag.*, level_delta);
                        },
                    }
                }
            }
        }

        const dst = self.queue[0..queue_size];
        const src = self.queue[queue_base..][0..queue_size];
        @memmove(dst, src);
        queue_base = 0;

        if (level == 0) {
            break;
        }
        level -= 1;
    }

    var diff_count: u32 = self.leaf_count;
    var leaf_idx: u32 = 0;
    while (leaf_idx < diff_count) {
        const leaf = &self.leaf_staging[leaf_idx];

        var prev_idx: u32 = 0;
        while (prev_idx < prev_count) : (prev_idx += 1) {
            const prev = &self.leaf_prev[prev_idx];
            if (@abs(leaf.origin.x - prev.origin.x) < 1.0e-6 and
                @abs(leaf.origin.y - prev.origin.y) < 1.0e-6 and
                leaf.data.level == prev.data.level)
            {
                leaf.sample_slot = prev.sample_slot;
                diff_count -= 1;
                std.mem.swap(Leaf, leaf, &self.leaf_staging[diff_count]);
                prev_count -= 1;
                std.mem.swap(Leaf, prev, &self.leaf_prev[prev_count]);
                break;
            }
        } else {
            leaf_idx += 1;
        }
    }

    const min_count = @min(diff_count, prev_count);

    for (
        self.leaf_staging[0..min_count],
        self.leaf_prev[0..min_count],
    ) |*leaf, prev| {
        leaf.sample_slot = prev.sample_slot;
    }

    for (self.leaf_prev[min_count..prev_count]) |removed| {
        self.slot_freelist[self.slot_freelist_top] = removed.sample_slot;
        self.slot_freelist_top += 1;
    }

    for (self.leaf_staging[min_count..diff_count]) |*leaf| {
        if (self.slot_freelist_top > 0) {
            self.slot_freelist_top -= 1;
            leaf.sample_slot = self.slot_freelist[self.slot_freelist_top];
        } else {
            leaf.sample_slot = self.slot_top;
            self.slot_top += 1;
        }
    }

    // TODO: Map instead of write to avoid internal staging buffer
    // if `max_leaf_count` ever gets big
    c.wgpuQueueWriteBuffer(
        queue,
        self.leaves,
        0,
        &self.leaf_staging,
        self.leaf_count * @sizeOf(Leaf),
    );

    return diff_count;
}

fn adjacent(fine: Leaf, coarse: Leaf) ?Direction {
    std.debug.assert(fine.data.level < coarse.data.level);
    const fine_extent: f32 =
        @floatFromInt(@as(u32, 1) << (fine.data.level + level_0_scale));
    const coarse_extent: f32 =
        @floatFromInt(@as(u32, 1) << (coarse.data.level + level_0_scale));
    const dx = @abs(fine.origin.x - coarse.origin.x);
    const dy = @abs(fine.origin.y - coarse.origin.y);
    const radius = (fine_extent + coarse_extent) * 0.5;
    const perp_threshold = coarse_extent * 0.5;

    if (std.math.approxEqAbs(f32, dx, radius, 1.0e-6) and dy < perp_threshold) {
        if (fine.origin.x < coarse.origin.x) {
            return .e;
        }
        if (fine.origin.x > coarse.origin.x) {
            return .w;
        }
    }

    if (std.math.approxEqAbs(f32, dy, radius, 1.0e-6) and dx < perp_threshold) {
        if (fine.origin.y < coarse.origin.y) {
            return .n;
        }
        if (fine.origin.y > coarse.origin.y) {
            return .s;
        }
    }

    return null;
}

// Conservatively flag false positives
fn aabbInFrustum(
    aabb_min: math.Vec3,
    aabb_max: math.Vec3,
    camera_view_proj: math.Mat4,
) bool {
    const vpt = camera_view_proj.transpose();
    const w_row = vpt.cols[3];
    const x_row = vpt.cols[0];
    const y_row = vpt.cols[1];
    const z_row = vpt.cols[2];

    const planes = [6]math.Vec4{
        w_row.add(x_row), // left
        w_row.sub(x_row), // right
        w_row.add(y_row), // bottom
        w_row.sub(y_row), // top
        w_row.sub(z_row), // near
        w_row.add(z_row), // far
    };

    for (planes) |plane| {
        const px = if (plane.x >= 0.0) aabb_max.x else aabb_min.x;
        const py = if (plane.y >= 0.0) aabb_max.y else aabb_min.y;
        const pz = if (plane.z >= 0.0) aabb_max.z else aabb_min.z;

        if (plane.x * px + plane.y * py + plane.z * pz + plane.w < 0.0) {
            return false;
        }
    }

    return true;
}

const Direction = enum(u32) { n = 0, w = 1, s = 2, e = 3 };

const EdgeFlags = packed struct(u20) {
    n: u5,
    w: u5,
    s: u5,
    e: u5,
};

const Leaf = extern struct {
    origin: math.Vec2,
    data: packed struct(u32) {
        level: u5,
        edge_flags: EdgeFlags,
        _padding: u7 = 0,
    },
    sample_slot: u32,
};

const max_leaf_count = 1_024;

const QueueFrame = struct {
    origin: math.Vec2,
};

const queue_frame_max_count = max_leaf_count + (max_leaf_count + 3) / 4;

// "scale" refers to log2 world meters
const base_scale = -4;
pub const leaf_scale_span = 5;
const level_0_scale = leaf_scale_span + base_scale;

const range_multiplier = 2.0;

pub const HeightSample = extern struct {
    normal: math.Vec3,
    height: f32,
};

const height_samples_per_leaf =
    ((1 << leaf_scale_span) + 1) * ((1 << leaf_scale_span) + 1);
pub const height_sample_count = max_leaf_count * height_samples_per_leaf;
