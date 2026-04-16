const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;

const Terrain = @This();

vertex_buffer: ?*c.WGPUBufferImpl = null,
index_buffer: ?*c.WGPUBufferImpl = null,

pipeline: ?*c.WGPURenderPipelineImpl = null,

const shader_code = @embedFile("assets/shaders/terrain.wgsl");

pub fn init(
    device: *c.WGPUDeviceImpl,
    surface_format: c.WGPUTextureFormat,
    vertex_buffer: *c.WGPUBufferImpl,
    index_buffer: *c.WGPUBufferImpl,
    camera_bg_layout: *c.WGPUBindGroupLayoutImpl,
) Terrain {
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

    const vertex_attributes =
        [_]c.WGPUVertexAttribute{
            .{
                .format = c.WGPUVertexFormat_Float32x3,
                .offset = @offsetOf(Vertex, "pos"),
                .shaderLocation = 0,
            },
            .{
                .format = c.WGPUVertexFormat_Float32x3,
                .offset = @offsetOf(Vertex, "normal"),
                .shaderLocation = 1,
            },
        };

    const bind_group_layouts = [_]c.WGPUBindGroupLayout{camera_bg_layout};

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
                .buffers = &.{
                    .stepMode = c.WGPUVertexStepMode_Vertex,
                    .arrayStride = @sizeOf(Vertex),
                    .attributeCount = vertex_attributes.len,
                    .attributes = &vertex_attributes,
                },
                .bufferCount = 1,
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

    return .{
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: Terrain) void {
    if (self.pipeline) |p| c.wgpuRenderPipelineRelease(p);
    if (self.index_buffer) |ib| {
        c.wgpuBufferDestroy(ib);
        c.wgpuBufferRelease(ib);
    }
    if (self.vertex_buffer) |vb| {
        c.wgpuBufferDestroy(vb);
        c.wgpuBufferRelease(vb);
    }
}

pub fn render(
    self: Terrain,
    pass: *c.WGPURenderPassEncoderImpl,
    camera_bg: *c.WGPUBindGroupImpl,
) void {
    c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, camera_bg, 0, null);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buffer, 0, c.wgpuBufferGetSize(self.vertex_buffer));
    c.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buffer, c.WGPUIndexFormat_Uint32, 0, c.wgpuBufferGetSize(self.index_buffer));
    c.wgpuRenderPassEncoderDrawIndexed(pass, @intCast(c.wgpuBufferGetSize(self.index_buffer) / @sizeOf(Index)), 1, 0, 0, 0);
}

pub const Vertex = extern struct {
    pos: math.Vec3,
    normal: math.Vec3,
};

const Index = u32;
