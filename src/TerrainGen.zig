const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const Terrain = @import("Terrain.zig");

const TerrainGen = @This();

const shader_code = @embedFile("assets/shaders/terrain_gen.wgsl");

heightmap_width: u32,
heightmap_height: u32,

heightmap_params: *c.WGPUBufferImpl,
out_vertex_buffer: *c.WGPUBufferImpl,
out_index_buffer: *c.WGPUBufferImpl,

heightmap_params_bg: *c.WGPUBindGroupImpl,
out_buffers_bg: *c.WGPUBindGroupImpl,

gen_vertices_pipeline: *c.WGPUComputePipelineImpl,
gen_indices_pipeline: *c.WGPUComputePipelineImpl,

pub fn init(
    device: *c.WGPUDeviceImpl,
    heightmap_bg_layout: *c.WGPUBindGroupLayoutImpl,
    heightmap_width: u32,
    heightmap_height: u32,
    heightmap_elev_min: f32,
    heightmap_elev_max: f32,
) TerrainGen {
    std.debug.assert(heightmap_width >= 1);
    std.debug.assert(heightmap_height >= 1);

    const vertex_buffer_size = heightmap_height * heightmap_width * @sizeOf(Terrain.Vertex);
    const index_buffer_size = (heightmap_height - 1) * (heightmap_width - 1) * 6 * @sizeOf(u32);

    const heightmap_params = c.wgpuDeviceCreateBuffer(device, &.{
        .label = util.wgpu.stringView("heightmap params"),
        .size = @sizeOf(HeightmapParams),
        .usage = c.WGPUBufferUsage_Uniform,
        .mappedAtCreation = c.WGPU_TRUE,
    }) orelse @panic("ERROR: Failed to create heightmap params buffer");

    const heightmap_params_buffer_address =
        c.wgpuBufferGetMappedRange(
            heightmap_params,
            0,
            @sizeOf(HeightmapParams),
        ).?;
    const heightmap_params_buffer_dst: *HeightmapParams =
        @ptrCast(@alignCast(heightmap_params_buffer_address));
    heightmap_params_buffer_dst.* = .{
        .width = heightmap_width,
        .height = heightmap_height,
        .elev_min = heightmap_elev_min,
        .elev_max = heightmap_elev_max,
    };
    c.wgpuBufferUnmap(heightmap_params);

    const out_vertex_buffer =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("terrain gen out vertices"),
            .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_Vertex,
            .size = vertex_buffer_size,
        }) orelse @panic("ERROR: Failed to create terrain gen out vertex buffer");

    const out_index_buffer =
        c.wgpuDeviceCreateBuffer(device, &.{
            .label = util.wgpu.stringView("terrain gen out indices"),
            .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_Index,
            .size = index_buffer_size,
        }) orelse @panic("ERROR: Failed to create terrain gen out index buffer");

    const heightmap_params_bg_layout =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("heightmap params"),
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Compute,
                .buffer = .{ .type = c.WGPUBufferBindingType_Uniform },
            }},
        }) orelse
        @panic("ERROR: Failed to create heightmap params bind group layout");
    defer c.wgpuBindGroupLayoutRelease(heightmap_params_bg_layout);

    const out_buffers_bg_layout =
        c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView("terrain gen out buffers"),
            .entryCount = 2,
            .entries = &[2]c.WGPUBindGroupLayoutEntry{ .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Compute,
                .buffer = .{ .type = c.WGPUBufferBindingType_Storage },
            }, .{
                .binding = 1,
                .visibility = c.WGPUShaderStage_Compute,
                .buffer = .{ .type = c.WGPUBufferBindingType_Storage },
            } },
        }) orelse
        @panic("ERROR: Failed to create terrain gen out buffers bind group layout");
    defer c.wgpuBindGroupLayoutRelease(out_buffers_bg_layout);

    const heightmap_params_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("heightmap params"),
            .layout = heightmap_params_bg_layout,
            .entryCount = 1,
            .entries = &[1]c.WGPUBindGroupEntry{.{
                .binding = 0,
                .buffer = heightmap_params,
                .offset = 0,
                .size = @sizeOf(HeightmapParams),
            }},
        }) orelse
        @panic("ERROR: Failed to create heightmap params bind group");

    const out_buffers_bg =
        c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView("terrain gen out buffers"),
            .layout = out_buffers_bg_layout,
            .entryCount = 2,
            .entries = &[2]c.WGPUBindGroupEntry{ .{
                .binding = 0,
                .buffer = out_vertex_buffer,
                .offset = 0,
                .size = vertex_buffer_size,
            }, .{
                .binding = 1,
                .buffer = out_index_buffer,
                .offset = 0,
                .size = index_buffer_size,
            } },
        }) orelse
        @panic("ERROR: Failed to create terrain gen out buffers bind group");

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

    const bind_group_layouts =
        [_]c.WGPUBindGroupLayout{
            heightmap_bg_layout,
            heightmap_params_bg_layout,
            out_buffers_bg_layout,
        };

    const pipeline_layout =
        c.wgpuDeviceCreatePipelineLayout(device, &.{
            .label = util.wgpu.stringView("terrain gen"),
            .bindGroupLayoutCount = bind_group_layouts.len,
            .bindGroupLayouts = &bind_group_layouts,
        }) orelse
        @panic("ERROR: Failed to create terrain gen pipeline layout");
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    const gen_vertices_pipeline =
        c.wgpuDeviceCreateComputePipeline(device, &.{
            .label = util.wgpu.stringView("terrain gen vertices"),
            .layout = pipeline_layout,
            .compute = .{
                .module = shader_module,
                .entryPoint = util.wgpu.stringView("genVertices"),
            },
        }) orelse
        @panic("ERROR: Failed to create terrain gen vertices pipeline");

    const gen_indices_pipeline =
        c.wgpuDeviceCreateComputePipeline(device, &.{
            .label = util.wgpu.stringView("terrain gen indices"),
            .layout = pipeline_layout,
            .compute = .{
                .module = shader_module,
                .entryPoint = util.wgpu.stringView("genIndices"),
            },
        }) orelse
        @panic("ERROR: Failed to create terrain gen indices pipeline");

    return .{
        .heightmap_width = heightmap_width,
        .heightmap_height = heightmap_height,
        .heightmap_params = heightmap_params,
        .out_vertex_buffer = out_vertex_buffer,
        .out_index_buffer = out_index_buffer,
        .heightmap_params_bg = heightmap_params_bg,
        .out_buffers_bg = out_buffers_bg,
        .gen_vertices_pipeline = gen_vertices_pipeline,
        .gen_indices_pipeline = gen_indices_pipeline,
    };
}

// No deinit; browser takes care of cleanup

pub fn dispatch(
    self: TerrainGen,
    pass: *c.WGPUComputePassEncoderImpl,
    heightmap_bg: *c.WGPUBindGroupImpl,
) void {
    // Generate vertices
    c.wgpuComputePassEncoderSetPipeline(pass, self.gen_vertices_pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, heightmap_bg, 0, null);
    c.wgpuComputePassEncoderSetBindGroup(pass, 1, self.heightmap_params_bg, 0, null);
    c.wgpuComputePassEncoderSetBindGroup(pass, 2, self.out_buffers_bg, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(
        pass,
        (self.heightmap_width + 15) / 16,
        (self.heightmap_height + 15) / 16,
        1,
    );

    // Generate indices
    c.wgpuComputePassEncoderSetPipeline(pass, self.gen_indices_pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 1, self.heightmap_params_bg, 0, null);
    c.wgpuComputePassEncoderSetBindGroup(pass, 2, self.out_buffers_bg, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(
        pass,
        (self.heightmap_width - 1 + 15) / 16,
        (self.heightmap_height - 1 + 15) / 16,
        1,
    );
}

const HeightmapParams = extern struct {
    width: u32,
    height: u32,
    elev_min: f32,
    elev_max: f32,
};
