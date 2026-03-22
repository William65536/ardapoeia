const std = @import("std");
const c = @import("root").c;
const util = @import("util.zig");
const math = util.math;

const Triangle = @This();

vertex_buffer: c.WGPUBuffer,

pipeline: c.WGPURenderPipeline,

const shader_code = @embedFile("assets/shaders/triangle.wgsl");

pub fn init(
    device: c.WGPUDevice,
    format: c.WGPUTextureFormat,
) Triangle {
    std.debug.assert(device != null);

    const vertex_buffer = c.wgpuDeviceCreateBuffer(device, &.{
        .usage = c.WGPUBufferUsage_Vertex,
        .size = vertices.len * @sizeOf(Vertex),
        .mappedAtCreation = c.WGPU_TRUE,
    }) orelse @panic("ERROR: Failed to create triangle vertex buffer");

    const vertex_buffer_address = c.wgpuBufferGetMappedRange(vertex_buffer, 0, vertices.len * @sizeOf(Vertex));
    const vertex_buffer_dst: [*]Vertex = @ptrCast(@alignCast(vertex_buffer_address));
    @memcpy(vertex_buffer_dst[0..vertices.len], &vertices);
    c.wgpuBufferUnmap(vertex_buffer);

    const shader_module = c.wgpuDeviceCreateShaderModule(device, &.{
        // `nextInChain` is non-const in the C API but it's never mutated
        .nextInChain = @ptrCast(@constCast(&c.WGPUShaderSourceWGSL{
            .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = util.wgpu.createStringView(shader_code),
        })),
    }) orelse @panic("ERROR: Failed to create triangle shader module");
    defer c.wgpuShaderModuleRelease(shader_module);

    const vertex_attributes = [_]c.WGPUVertexAttribute{
        .{
            .format = c.WGPUVertexFormat_Float32x2,
            .offset = @offsetOf(Vertex, "pos"),
            .shaderLocation = 0,
        },
        .{
            .format = c.WGPUVertexFormat_Float32x3,
            .offset = @offsetOf(Vertex, "color"),
            .shaderLocation = 1,
        },
    };

    const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &.{
        .bindGroupLayoutCount = 0,
        .bindGroupLayouts = null,
    }) orelse @panic("ERROR: Failed to create triangle pipeline layout");
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &.{
        .layout = pipeline_layout,
        .vertex = .{
            .module = shader_module,
            .entryPoint = util.wgpu.createStringView("vsMain"),
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
                .format = format,
                .writeMask = c.WGPUColorWriteMask_All,
            },
            .entryPoint = util.wgpu.createStringView("fsMain"),
        },
        .multisample = .{
            .count = 1,
            .mask = 0xFFFFFFFF, // enable all samples
        },
    }) orelse @panic("ERROR: Failed to create triangle pipeline");

    return .{
        .vertex_buffer = vertex_buffer,
        .pipeline = pipeline,
    };
}

// No deinit; browser takes care of cleanup

pub fn render(
    self: *Triangle,
    pass: c.WGPURenderPassEncoder,
) void {
    std.debug.assert(pass != null);
    c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buffer, 0, c.wgpuBufferGetSize(self.vertex_buffer));
    c.wgpuRenderPassEncoderDraw(pass, vertices.len, 1, 0, 0);
}

const Vertex = extern struct {
    pos: math.Vec2,
    color: math.Vec3,
};

const vertices = [_]Vertex{
    .{ .pos = .{ .x = -0.5, .y = -0.5 }, .color = .{ .x = 1.0, .y = 0.0, .z = 0.0 } },
    .{ .pos = .{ .x = 0.5, .y = -0.5 }, .color = .{ .x = 0.0, .y = 1.0, .z = 0.0 } },
    .{ .pos = .{ .x = 0.5, .y = 0.5 }, .color = .{ .x = 0.0, .y = 0.0, .z = 1.0 } },
};
