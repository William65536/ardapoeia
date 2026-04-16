const std = @import("std");
const c = @import("../../c.zig").c;
const util = @import("../../util.zig");

const Texture = @This();

texture: *c.WGPUTextureImpl,
view: *c.WGPUTextureViewImpl,
sampler: ?*c.WGPUSamplerImpl, // `null` when `config.with_sampler == false`

// `null` when `config.usage & c.WGPUTextureUsage_TextureBinding == 0`
bind_group: ?*c.WGPUBindGroupImpl,

pub const Config = struct {
    label: []const u8 = "",
    format: c.WGPUTextureFormat,
    usage: c.WGPUTextureUsage,
    with_sampler: bool,
    // Not read from when `config.usage & c.WGPUTextureUsage_TextureBinding == 0`
    visibility: c.WGPUShaderStage,
};

pub const readable_depth_texture_config: Config = .{
    .label = "depth",
    .format = c.WGPUTextureFormat_Depth32Float,
    .usage = c.WGPUTextureUsage_RenderAttachment |
        c.WGPUTextureUsage_TextureBinding,
    .with_sampler = false,
    .visibility = c.WGPUShaderStage_Compute,
};

pub fn init(
    device: *c.WGPUDeviceImpl,
    width: u32,
    height: u32,
    comptime config: Config,
) struct { Texture, ?*c.WGPUBindGroupLayoutImpl } {
    // A sampler without a binding is pointless
    std.debug.assert(!config.with_sampler or
        config.usage & c.WGPUTextureUsage_TextureBinding != 0);

    const texture =
        c.wgpuDeviceCreateTexture(device, &.{
            .label = util.wgpu.stringView(config.label),
            .usage = config.usage,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
            .format = config.format,
            .mipLevelCount = 1,
            .sampleCount = 1,
        }) orelse @panic("ERROR: Failed to create texture");

    const view =
        c.wgpuTextureCreateView(texture, &.{
            .label = util.wgpu.stringView(config.label),
            .format = config.format,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .arrayLayerCount = 1,
        }) orelse @panic("ERROR: Failed to create texture view");

    const sampler: ?*c.WGPUSamplerImpl =
        if (config.with_sampler) blk: {
            break :blk c.wgpuDeviceCreateSampler(device, &.{
                .label = util.wgpu.stringView(config.label),
                .addressModeU = c.WGPUAddressMode_ClampToEdge,
                .addressModeV = c.WGPUAddressMode_ClampToEdge,
                .magFilter = c.WGPUFilterMode_Linear,
                .minFilter = c.WGPUFilterMode_Linear,
                .mipmapFilter = c.WGPUMipmapFilterMode_Linear,
                .lodMaxClamp = 100.0,
                .maxAnisotropy = 1,
            }) orelse @panic("ERROR: Failed to create sampler");
        } else null;

    if (config.usage & c.WGPUTextureUsage_TextureBinding == 0) {
        return .{
            .{
                .texture = texture,
                .view = view,
                .sampler = sampler,
                .bind_group = null,
            },
            null,
        };
    }

    const bind_group_layout = blk: {
        const texture_entry: c.WGPUBindGroupLayoutEntry = .{
            .binding = 0,
            .visibility = config.visibility,
            .texture = .{
                .sampleType = sampleType(config.format),
                .viewDimension = c.WGPUTextureViewDimension_2D,
            },
        };

        const sampler_entry: c.WGPUBindGroupLayoutEntry = .{
            .binding = 1,
            .visibility = config.visibility,
            .sampler = .{
                .type = c.WGPUSamplerBindingType_Filtering,
            },
        };

        const entries =
            [1]c.WGPUBindGroupLayoutEntry{texture_entry} ++
            if (config.with_sampler)
                [1]c.WGPUBindGroupLayoutEntry{sampler_entry}
            else
                [0]c.WGPUBindGroupLayoutEntry{};

        break :blk c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = util.wgpu.stringView(config.label),
            .entryCount = entries.len,
            .entries = &entries,
        }) orelse @panic("ERROR: Failed to create texture bind group layout");
    };

    const bind_group = blk: {
        const entries = if (config.with_sampler)
            [2]c.WGPUBindGroupEntry{
                .{ .binding = 0, .textureView = view },
                .{ .binding = 1, .sampler = sampler },
            }
        else
            [1]c.WGPUBindGroupEntry{
                .{ .binding = 0, .textureView = view },
            };

        break :blk c.wgpuDeviceCreateBindGroup(device, &.{
            .label = util.wgpu.stringView(config.label),
            .layout = bind_group_layout,
            .entryCount = entries.len,
            .entries = &entries,
        }) orelse @panic("ERROR: Failed to create texture bind group");
    };

    return .{
        .{
            .texture = texture,
            .view = view,
            .sampler = sampler,
            .bind_group = bind_group,
        },
        bind_group_layout,
    };
}

pub fn deinit(self: Texture) void {
    if (self.bind_group != null) {
        c.wgpuBindGroupRelease(self.bind_group);
    }
    if (self.sampler != null) {
        c.wgpuSamplerRelease(self.sampler);
    }
    c.wgpuTextureViewRelease(self.view);
    c.wgpuTextureDestroy(self.texture);
    c.wgpuTextureRelease(self.texture);
}

pub fn upload(
    self: Texture,
    queue: *c.WGPUQueueImpl,
    bytes: []const u8,
    width: u32,
    height: u32,
) void {
    c.wgpuQueueWriteTexture(
        queue,
        &.{
            .texture = self.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        },
        bytes.ptr,
        bytes.len,
        &.{
            .offset = 0,
            .bytesPerRow = width *
                bytesPerTexel(c.wgpuTextureGetFormat(self.texture)),
            .rowsPerImage = height,
        },
        &.{ .width = width, .height = height, .depthOrArrayLayers = 1 },
    );
}

fn bytesPerTexel(format: c.WGPUTextureFormat) u32 {
    return switch (format) {
        c.WGPUTextureFormat_RGBA8Unorm,
        c.WGPUTextureFormat_Depth32Float,
        => 4,
        c.WGPUTextureFormat_R16Uint => 2,
        else => @panic("ERROR: Unsupported texture format"),
    };
}

fn sampleType(format: c.WGPUTextureFormat) c.WGPUTextureSampleType {
    return switch (format) {
        c.WGPUTextureFormat_RGBA8Unorm,
        => c.WGPUTextureSampleType_Float,
        c.WGPUTextureFormat_R16Uint => c.WGPUTextureSampleType_Uint,
        c.WGPUTextureFormat_Depth32Float => c.WGPUTextureSampleType_Depth,
        else => @panic("ERROR: Unsupported texture format"),
    };
}
