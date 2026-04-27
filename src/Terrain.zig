const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;
const TerrainGen = @import("TerrainGen.zig");

const Terrain = @This();

initialized_count: u32 = 0,

index_buffer: *c.WGPUBufferImpl = undefined,

height_samples_bg: *c.WGPUBindGroupImpl = undefined,

pipeline: *c.WGPURenderPipelineImpl = undefined,

const shader_code = @embedFile("assets/shaders/terrain.wgsl");

pub fn init(
    device: *c.WGPUDeviceImpl,
    surface_format: c.WGPUTextureFormat,
    camera_bg_layout: *c.WGPUBindGroupLayoutImpl,
    lod_leaves_bg_layout: *c.WGPUBindGroupLayoutImpl,
    height_samples: *c.WGPUBufferImpl,
) Terrain {
    var initialized_count: u32 = 0;

    const index_buffer =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("terrain indices"),
            .usage = c.WGPUBufferUsage_Index,
            .size = index_buffer_size,
            .mappedAtCreation = c.WGPU_TRUE,
        }) orelse @panic("ERROR: Failed to create terrain index buffer");
    initialized_count += 1;

    const index_buffer_address =
        c.wgpuBufferGetMappedRange(index_buffer, 0, index_buffer_size) orelse
        @panic("ERROR: Failed to get terrain index buffer mapped address");
    const index_buffer_dst: [*]Index =
        @ptrCast(@alignCast(index_buffer_address));
    for (0..lod_leaf_extent_span) |x| {
        for (0..lod_leaf_extent_span) |z| {
            const v_00 = z * (lod_leaf_extent_span + 1) + x;
            const v_10 = v_00 + 1;
            const v_01 = v_00 + lod_leaf_extent_span + 1;
            const v_11 = v_01 + 1;

            const i = (z * lod_leaf_extent_span + x) * 6;
            index_buffer_dst[i + 0] = v_00;
            index_buffer_dst[i + 1] = v_10;
            index_buffer_dst[i + 2] = v_11;
            index_buffer_dst[i + 3] = v_11;
            index_buffer_dst[i + 4] = v_01;
            index_buffer_dst[i + 5] = v_00;
        }
    }
    c.wgpuBufferUnmap(index_buffer);

    const height_samples_bg_layout =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("height samples readonly"),
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Vertex,
                .buffer = .{ .type = c.WGPUBufferBindingType_ReadOnlyStorage },
            }},
        }) orelse
        @panic("ERROR: Failed to create height samples bind group layout");
    defer c.wgpuBindGroupLayoutRelease(height_samples_bg_layout);

    const height_samples_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("height samples readonly"),
            .layout = height_samples_bg_layout,
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupEntry{.{
                .binding = 0,
                .buffer = height_samples,
                .offset = 0,
                .size = TerrainGen.height_sample_count * @sizeOf(TerrainGen.HeightSample),
            }},
        }) orelse
        @panic("ERROR: Failed to create height samples bind group");
    initialized_count += 1;

    const shader_module =
        c.wgpuDeviceCreateShaderModule(device, &.{
            .label = util.wgpu.stringView("terrain"),
            // `nextInChain` is non-const in the C API but it's never mutated
            .nextInChain = @ptrCast(@constCast(&c.WGPUShaderSourceWGSL{
                .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
                .code = util.wgpu.stringView(shader_code),
            })),
        }) orelse @panic("ERROR: Failed to create terrain shader module");
    defer c.wgpuShaderModuleRelease(shader_module);

    const bind_group_layouts = [_]c.WGPUBindGroupLayout{
        camera_bg_layout,
        lod_leaves_bg_layout,
        height_samples_bg_layout,
    };

    const pipeline_layout =
        c.wgpuDeviceCreatePipelineLayout(device, &.{
            .label = util.wgpu.stringView("terrain"),
            .bindGroupLayoutCount = bind_group_layouts.len,
            .bindGroupLayouts = &bind_group_layouts,
        }) orelse @panic("ERROR: Failed to create terrain pipeline layout");
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    const pipeline =
        c.wgpuDeviceCreateRenderPipeline(device, &.{
            .label = util.wgpu.stringView("terrain"),
            .layout = pipeline_layout,
            .vertex = .{
                .module = shader_module,
                .entryPoint = util.wgpu.stringView("vsMain"),
                .buffers = &.{},
                .bufferCount = 0,
            },
            .primitive = .{
                .cullMode = c.WGPUCullMode_Back,
                .frontFace = c.WGPUFrontFace_CCW,
            },
            .fragment = &.{
                .module = shader_module,
                .targetCount = 1,
                .targets = &.{
                    .format = surface_format,
                    .writeMask = c.WGPUColorWriteMask_All,
                },
                .entryPoint = util.wgpu.stringView("fsMain"),
            },
            .depthStencil = &.{
                .format = c.WGPUTextureFormat_Depth32Float,
                .depthWriteEnabled = c.WGPU_TRUE,
                .depthCompare = c.WGPUCompareFunction_Greater,
            },
            .multisample = .{
                .count = 1,
                .mask = 0xFFFFFFFF, // enable all samples
            },
        }) orelse @panic("ERROR: Failed to create terrain pipeline");
    initialized_count += 1;

    return .{
        .index_buffer = index_buffer,
        .height_samples_bg = height_samples_bg,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: Terrain) void {
    var initialized_threshold: u32 = 0;
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBufferRelease(self.index_buffer);
    defer c.wgpuBufferDestroy(self.index_buffer);
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuBindGroupRelease(self.height_samples_bg);
    initialized_threshold += 1;
    if (self.initialized_count < initialized_threshold) return;
    defer c.wgpuRenderPipelineRelease(self.pipeline);
}

pub fn render(
    self: Terrain,
    pass: *c.WGPURenderPassEncoderImpl,
    camera_bg: *c.WGPUBindGroupImpl,
    lod_leaves_bg: *c.WGPUBindGroupImpl,
    lod_leaf_count: u32,
) void {
    c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, camera_bg, 0, null);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 1, lod_leaves_bg, 0, null);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 2, self.height_samples_bg, 0, null);
    c.wgpuRenderPassEncoderSetIndexBuffer(
        pass,
        self.index_buffer,
        c.WGPUIndexFormat_Uint32,
        0,
        c.wgpuBufferGetSize(self.index_buffer),
    );
    c.wgpuRenderPassEncoderDrawIndexed(
        pass,
        @intCast(c.wgpuBufferGetSize(self.index_buffer) / @sizeOf(Index)),
        lod_leaf_count,
        0,
        0,
        0,
    );
}

const Vertex = extern struct {
    pos: math.Vec3,
};

const Index = u32;

const lod_leaf_extent_span = 1 << TerrainGen.leaf_scale_span;

const index_buffer_size =
    lod_leaf_extent_span * lod_leaf_extent_span * 6 * @sizeOf(Index);
