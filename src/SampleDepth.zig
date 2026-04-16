const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");

const SampleDepth = @This();

const shader_code = @embedFile("assets/shaders/sample_depth.wgsl");

depth_sample_mapped: ?*c.WGPUBufferImpl = null,
depth_sample: ?*c.WGPUBufferImpl = null,

depth_sample_bg: ?*c.WGPUBindGroupImpl = null,

pipeline: ?*c.WGPUComputePipelineImpl = null,

pub fn init(
    device: *c.WGPUDeviceImpl,
    input_bg_layout: *c.WGPUBindGroupLayoutImpl,
    depth_texture_bg_layout: *c.WGPUBindGroupLayoutImpl,
) SampleDepth {
    const depth_sample_mapped =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("depth sample mapped"),
            .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(DepthSample),
        }) orelse @panic("ERROR: Failed to create depth sample mapped buffer");

    const depth_sample =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("depth sample"),
            .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopySrc,
            .size = @sizeOf(DepthSample),
        }) orelse @panic("ERROR: Failed to create depth sample buffer");

    const depth_sample_bg_layout =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("depth sample"),
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Compute,
                .buffer = .{ .type = c.WGPUBufferBindingType_Storage },
            }},
        }) orelse
        @panic("ERROR: Failed to create depth sample bind group layout");
    defer c.wgpuBindGroupLayoutRelease(depth_sample_bg_layout);

    const depth_sample_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("depth sample"),
            .layout = depth_sample_bg_layout,
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupEntry{.{
                .binding = 0,
                .buffer = depth_sample,
                .offset = 0,
                .size = @sizeOf(DepthSample),
            }},
        }) orelse
        @panic("ERROR: Failed to create depth sample bind group");

    const shader_module =
        c.wgpuDeviceCreateShaderModule(device, &.{
            .label = util.wgpu.stringView("sample depth"),
            // `nextInChain` is non-const in the C API but it's never mutated
            .nextInChain = @ptrCast(@constCast(&c.WGPUShaderSourceWGSL{
                .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
                .code = util.wgpu.stringView(shader_code),
            })),
        }) orelse @panic("ERROR: Failed to create sample depth shader module");
    defer c.wgpuShaderModuleRelease(shader_module);

    const bind_group_layouts =
        [_]c.WGPUBindGroupLayout{
            input_bg_layout,
            depth_texture_bg_layout,
            depth_sample_bg_layout,
        };

    const pipeline_layout =
        c.wgpuDeviceCreatePipelineLayout(device, &.{
            .label = util.wgpu.stringView("sample depth"),
            .bindGroupLayoutCount = bind_group_layouts.len,
            .bindGroupLayouts = &bind_group_layouts,
        }) orelse @panic("ERROR: Failed to create sample depth pipeline layout");
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    const pipeline =
        c.wgpuDeviceCreateComputePipeline(device, &.{
            .label = util.wgpu.stringView("sample depth"),
            .layout = pipeline_layout,
            .compute = .{
                .module = shader_module,
                .entryPoint = util.wgpu.stringView("sampleDepth"),
            },
        }) orelse
        @panic("ERROR: Failed to create sample depth pipeline");

    return .{
        .depth_sample_mapped = depth_sample_mapped,
        .depth_sample = depth_sample,
        .depth_sample_bg = depth_sample_bg,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: SampleDepth) void {
    if (self.pipeline) |p| c.wgpuComputePipelineRelease(p);
    if (self.depth_sample_bg) |dsbg| c.wgpuBindGroupRelease(dsbg);
    if (self.depth_sample) |ds| {
        c.wgpuBufferDestroy(ds);
        c.wgpuBufferRelease(ds);
    }
    if (self.depth_sample_mapped) |dsm| {
        c.wgpuBufferDestroy(dsm);
        c.wgpuBufferRelease(dsm);
    }
}

pub fn dispatch(
    self: SampleDepth,
    pass: *c.WGPUComputePassEncoderImpl,
    input_bg: *c.WGPUBindGroupImpl,
    depth_texture_bg: *c.WGPUBindGroupImpl,
) void {
    c.wgpuComputePassEncoderSetPipeline(pass, self.pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, input_bg, 0, null);
    c.wgpuComputePassEncoderSetBindGroup(pass, 1, depth_texture_bg, 0, null);
    c.wgpuComputePassEncoderSetBindGroup(pass, 2, self.depth_sample_bg, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(pass, 1, 1, 1);
}

pub fn sampleDepth(
    self: SampleDepth,
    instance: *c.WGPUInstanceImpl,
    device: *c.WGPUDeviceImpl,
    queue: *c.WGPUQueueImpl,
) f32 {
    const encoder =
        c.wgpuDeviceCreateCommandEncoder(device, &.{
            .label = util.wgpu.stringView("depth sample"),
        }) orelse
        @panic("ERROR: Failed to create depth sample command encoder");
    defer c.wgpuCommandEncoderRelease(encoder);

    c.wgpuCommandEncoderCopyBufferToBuffer(
        encoder,
        self.depth_sample,
        0,
        self.depth_sample_mapped,
        0,
        @sizeOf(DepthSample),
    );

    const commands =
        c.wgpuCommandEncoderFinish(encoder, null) orelse
        @panic("ERROR: Failed to finish depth sample encoder");
    defer c.wgpuCommandBufferRelease(commands);
    c.wgpuQueueSubmit(queue, 1, &commands);

    const map_fut =
        c.wgpuBufferMapAsync(
            self.depth_sample_mapped,
            c.WGPUMapMode_Read,
            0,
            @sizeOf(DepthSample),
            .{
                .mode = c.WGPUCallbackMode_WaitAnyOnly,
                .callback = null,
                .userdata1 = undefined,
                .userdata2 = undefined,
            },
        );
    var map_fut_info: c.WGPUFutureWaitInfo = .{ .future = map_fut };
    if (c.wgpuInstanceWaitAny(
        instance,
        1,
        &map_fut_info,
        // Infinite timeout; adapter required to proceed
        std.math.maxInt(u64),
    ) != c.WGPUStatus_Success) {
        @panic("ERROR: Failed to await depth sample buffer map");
    }
    defer c.wgpuBufferUnmap(self.depth_sample_mapped);

    const depth_sample: *const f32 =
        @ptrCast(@alignCast(c.wgpuBufferGetConstMappedRange(
            self.depth_sample_mapped,
            0,
            @sizeOf(DepthSample),
        ) orelse @panic("ERROR: Failed to get depth sample buffer mapped range")));

    return depth_sample.*;
}

const DepthSample = f32;
