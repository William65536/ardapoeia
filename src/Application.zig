const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;
const Input = @import("Input.zig");
const Texture = @import("util.zig").wgpu.Texture;
const SampleDepth = @import("SampleDepth.zig");
const TerrainGen = @import("TerrainGen.zig");
const Camera = @import("Camera.zig");
const Terrain = @import("Terrain.zig");

const Application = @This();

instance: ?*c.WGPUInstanceImpl = null,
adapter: ?*c.WGPUAdapterImpl = null,
device: ?*c.WGPUDeviceImpl = null,
queue: ?*c.WGPUQueueImpl = null,
surface: ?*c.WGPUSurfaceImpl = null,
surface_format: c.WGPUTextureFormat = undefined,
depth_texture: ?Texture = null,

glfw_initialized: bool = false,
window: ?*c.GLFWwindow = null,
window_width: u32 = undefined, // `>= 1`
window_height: u32 = undefined, // `>= 1`
frame_width: u32 = undefined, // `>= 1`
frame_height: u32 = undefined, // `>= 1`

input: Input = .{},

last_time: f64 = 0.0,

sample_depth: SampleDepth = .{},

terrain_gen: TerrainGen = .{},

camera: Camera = .{},

terrain: Terrain = .{},

pub fn init(self: *Application, window_width: u32, window_height: u32) void {
    std.debug.assert(window_width >= 1);
    std.debug.assert(window_height >= 1);
    self.initWgpu();
    var depth_texture_bg_layout: *c.WGPUBindGroupLayoutImpl = undefined;
    self.initWindow(window_width, window_height, &depth_texture_bg_layout);
    self.initResources(depth_texture_bg_layout);
}

fn initWgpu(self: *Application) void {
    // TODO: Prevent hanging/crashing if WebGPU fails to initialize

    self.instance =
        c.wgpuCreateInstance(&.{
            .requiredFeatureCount = 1,
            .requiredFeatures = &[_]c.WGPUInstanceFeatureName{
                c.WGPUInstanceFeatureName_TimedWaitAny,
            },
        }) orelse @panic("ERROR: Failed to create instance");

    const adapter_fut =
        c.wgpuInstanceRequestAdapter(self.instance, &.{}, .{
            .callback = requestAdapterCallback,
            .mode = c.WGPUCallbackMode_WaitAnyOnly,
            .userdata1 = @ptrCast(&self.adapter),
            .userdata2 = undefined,
        });
    var adapter_fut_info: c.WGPUFutureWaitInfo = .{ .future = adapter_fut };
    if (c.wgpuInstanceWaitAny(
        self.instance,
        1,
        &adapter_fut_info,
        // Infinite timeout; adapter required to proceed
        std.math.maxInt(u64),
    ) != c.WGPUStatus_Success) {
        @panic("ERROR: Failed to await adapter request");
    }

    const device_fut =
        c.wgpuAdapterRequestDevice(self.adapter, &.{}, .{
            .callback = requestDeviceCallback,
            .mode = c.WGPUCallbackMode_WaitAnyOnly,
            .userdata1 = @ptrCast(&self.device),
            .userdata2 = undefined,
        });
    var device_fut_info: c.WGPUFutureWaitInfo = .{ .future = device_fut };
    if (c.wgpuInstanceWaitAny(
        self.instance,
        1,
        &device_fut_info,
        // Infinite timeout; device required to proceed
        std.math.maxInt(u64),
    ) != c.WGPUStatus_Success) {
        @panic("ERROR: Failed to await device request");
    }

    self.queue =
        c.wgpuDeviceGetQueue(self.device) orelse
        @panic("ERROR: Failed to get queue");
}

fn initWindow(
    self: *Application,
    window_width: u32,
    window_height: u32,
    depth_texture_bg_layout: **c.WGPUBindGroupLayoutImpl,
) void {
    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    if (c.glfwInit() == c.GLFW_FALSE) {
        @panic("ERROR: GLFW initialization failed");
    }
    self.glfw_initialized = true;

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    self.window =
        c.glfwCreateWindow(
            @intCast(window_width),
            @intCast(window_height),
            "Ardapoeia",
            null,
            null,
        ) orelse @panic("ERROR: Failed to create window");

    self.window_width = window_width;
    self.window_height = window_height;

    var frame_width: c_int = undefined;
    var frame_height: c_int = undefined;
    c.glfwGetFramebufferSize(self.window, &frame_width, &frame_height);
    self.frame_width = @intCast(frame_width);
    self.frame_height = @intCast(frame_height);

    self.input.init(self.window.?);
    self.input.attachToApp(self);

    self.surface =
        c.wgpuGlfwCreateSurfaceForWindow(self.instance, self.window) orelse
        @panic("ERROR: Failed to create surface for window");
    var capabilities: c.WGPUSurfaceCapabilities = undefined;
    capabilities.nextInChain = null;
    if (c.wgpuSurfaceGetCapabilities(
        self.surface,
        self.adapter,
        &capabilities,
    ) != c.WGPUStatus_Success) {
        @panic("ERROR: Failed to get surface capabilities");
    }
    self.surface_format = capabilities.formats[0];
    c.wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    self.reconfigureSurface(depth_texture_bg_layout);
}

fn initResources(
    self: *Application,
    depth_texture_bg_layout: *c.WGPUBindGroupLayoutImpl,
) void {
    // TODO: Load resources asynchronously

    const device = self.device.?;
    const queue = self.queue.?;

    const input_bg_layout = self.input.initGpu(device);
    defer c.wgpuBindGroupLayoutRelease(input_bg_layout);

    self.sample_depth = SampleDepth.init(device, input_bg_layout, depth_texture_bg_layout);

    // Set image origins to bottom left corner
    c.stbi_set_flip_vertically_on_load(1);

    const heightmap_meta_src: [8]u8 align(@alignOf(f32)) =
        @embedFile("assets/textures/lauterbrunnen_dem.meta").*;
    const heightmap_meta: extern struct { elev_min: f32, elev_max: f32 } =
        @bitCast(heightmap_meta_src);

    const heightmap_src = @embedFile("assets/textures/lauterbrunnen_dem.png");
    var heightmap_width: c_int = undefined;
    var heightmap_height: c_int = undefined;
    var heightmap_channel_count: c_int = undefined;
    const heightmap_data =
        c.stbi_load_16_from_memory(
            heightmap_src,
            heightmap_src.len,
            &heightmap_width,
            &heightmap_height,
            &heightmap_channel_count,
            1,
        ) orelse @panic("ERROR: Failed to load heightmap image");
    defer c.stbi_image_free(heightmap_data);
    if (heightmap_channel_count != 1) {
        @panic("ERROR: Heightmap must be 16-bit single-channel grayscale");
    }

    const heightmap, const heightmap_texture_bg_layout =
        Texture.init(
            device,
            @intCast(heightmap_width),
            @intCast(heightmap_height),
            .{
                .label = "heightmap",
                .format = c.WGPUTextureFormat_R16Uint,
                .usage = c.WGPUTextureUsage_TextureBinding |
                    c.WGPUTextureUsage_CopyDst,
                .with_sampler = false,
                .visibility = c.WGPUShaderStage_Compute,
            },
        );
    defer c.wgpuBindGroupLayoutRelease(heightmap_texture_bg_layout);
    defer heightmap.deinit();
    const heightmap_bytes =
        std.mem.sliceAsBytes(
            heightmap_data[0..@intCast(heightmap_height * heightmap_width)],
        );
    heightmap.upload(
        queue,
        heightmap_bytes,
        @intCast(heightmap_width),
        @intCast(heightmap_height),
    );

    self.terrain_gen =
        .init(
            device,
            heightmap_texture_bg_layout.?,
            @intCast(heightmap_width),
            @intCast(heightmap_height),
            heightmap_meta.elev_min,
            heightmap_meta.elev_max,
        );

    // Build terrain mesh from heightmap
    {
        const encoder =
            c.wgpuDeviceCreateCommandEncoder(self.device, &.{
                .label = util.wgpu.stringView("terrain gen"),
            }) orelse
            @panic("ERROR: Failed to create terrain gen command encoder");
        defer c.wgpuCommandEncoderRelease(encoder);

        const pass =
            c.wgpuCommandEncoderBeginComputePass(encoder, &.{
                .label = util.wgpu.stringView("terrain gen"),
            }) orelse
            @panic("ERROR: Failed to begin terrain gen compute pass");
        defer c.wgpuComputePassEncoderRelease(pass);

        self.terrain_gen.dispatch(pass, heightmap.bind_group.?);

        c.wgpuComputePassEncoderEnd(pass);

        const commands =
            c.wgpuCommandEncoderFinish(encoder, &.{
                .label = util.wgpu.stringView("terrain gen"),
            }) orelse
            @panic("ERROR: Failed to finish terrain gen command encoding");
        defer c.wgpuCommandBufferRelease(commands);
        c.wgpuQueueSubmit(self.queue, 1, &commands);
    }

    const camera_bg_layout = self.camera.initGpu(device);
    defer c.wgpuBindGroupLayoutRelease(camera_bg_layout);

    self.terrain =
        .init(
            device,
            self.surface_format,
            self.terrain_gen.out_vertex_buffer.?,
            self.terrain_gen.out_index_buffer.?,
            camera_bg_layout,
        );
}

pub fn deinit(self: Application) void {
    self.terrain.deinit();
    self.camera.deinitGpu();
    self.terrain_gen.deinit();
    self.sample_depth.deinit();

    self.input.deinitGpu();
    if (self.window) |w| c.glfwDestroyWindow(w);
    if (self.glfw_initialized) c.glfwTerminate();

    if (self.depth_texture) |d| d.deinit();
    if (self.surface) |s| c.wgpuSurfaceRelease(s);
    if (self.queue) |q| c.wgpuQueueRelease(q);
    if (self.device) |d| c.wgpuDeviceRelease(d);
    if (self.adapter) |a| c.wgpuAdapterRelease(a);
    if (self.instance) |i| c.wgpuInstanceRelease(i);
}

pub fn frame(self: *Application) void {
    std.debug.assert(self.window_width >= 1);
    std.debug.assert(self.window_height >= 1);

    const instance = self.instance.?;
    const device = self.device.?;
    const queue = self.queue.?;
    const depth_texture = self.depth_texture.?;

    const now = c.glfwGetTime();
    const dt: f32 = @floatCast(now - self.last_time);
    self.last_time = now;

    // Process input
    c.glfwPollEvents();

    self.camera.update(self.input, self.window_width, self.window_height, dt);

    self.camera.upload(queue, self.windowAspect());

    self.input.upload(
        queue,
        @divExact(self.frame_width, self.window_width),
        @divExact(self.frame_height, self.window_height),
    );

    // Render and GPU compute
    const surface_texture = self.acquireSurfaceTexture() orelse return;
    defer c.wgpuTextureRelease(surface_texture);

    const surface_view =
        c.wgpuTextureCreateView(surface_texture, &.{
            .label = util.wgpu.stringView("surface"),
            .format = self.surface_format,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .arrayLayerCount = 1,
        }) orelse @panic("ERROR: Failed to create surface texture view");
    defer c.wgpuTextureViewRelease(surface_view);

    {
        const encoder =
            c.wgpuDeviceCreateCommandEncoder(self.device, &.{
                .label = util.wgpu.stringView("scene"),
            }) orelse @panic("ERROR: Failed to create scene command encoder");
        defer c.wgpuCommandEncoderRelease(encoder);

        // Render scene
        {
            const pass =
                c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
                    .label = util.wgpu.stringView("scene"),
                    .colorAttachmentCount = 1,
                    .colorAttachments = &.{
                        .view = surface_view,
                        .loadOp = c.WGPULoadOp_Clear,
                        .storeOp = c.WGPUStoreOp_Store,
                        .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
                        .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
                    },
                    .depthStencilAttachment = &.{
                        .view = depth_texture.view,
                        .depthLoadOp = c.WGPULoadOp_Clear,
                        .depthStoreOp = c.WGPUStoreOp_Store,
                        .depthClearValue = 0.0,
                    },
                }) orelse @panic("ERROR: Failed to begin scene render pass");
            defer c.wgpuRenderPassEncoderRelease(pass);

            self.terrain.render(pass, self.camera.uniform_bg.?);

            c.wgpuRenderPassEncoderEnd(pass);
        }

        if (self.input.middleMouseButtonJustPressed()) {
            const pass =
                c.wgpuCommandEncoderBeginComputePass(encoder, &.{
                    .label = util.wgpu.stringView("sample depth"),
                }) orelse
                @panic("ERROR: Failed to begin sample depth compute pass");
            defer c.wgpuComputePassEncoderRelease(pass);

            self.sample_depth.dispatch(
                pass,
                self.input.uniform_bg.?,
                depth_texture.bind_group.?,
            );

            c.wgpuComputePassEncoderEnd(pass);
        }

        const commands =
            c.wgpuCommandEncoderFinish(encoder, &.{
                .label = util.wgpu.stringView("scene"),
            }) orelse @panic("ERROR: Failed to finish scene command encoding");
        defer c.wgpuCommandBufferRelease(commands);
        c.wgpuQueueSubmit(self.queue, 1, &commands);
    }

    if (self.input.middleMouseButtonJustPressed()) blk: {
        const depth_sample =
            self.sample_depth.sampleDepth(instance, device, queue);

        const inv_view_proj =
            self.camera.projMat(self.windowAspect()).mul(self.camera.viewMat())
                .invert();

        const cursor_ndc =
            self.input.cursorNdc(self.window_width, self.window_height);

        if (depth_sample <= 0.0) {
            const camera_ray =
                self.camera.rayFromCursor(cursor_ndc, self.windowAspect());
            const t = camera_ray.intersectXZPlane(0.0) orelse break :blk;
            if (t < 1.0e-6) {
                break :blk;
            }
            const intersection = camera_ray.at(t);
            self.camera.terrain_grab = intersection;
            break :blk;
        }

        const point_ndc: math.Vec4 = .{
            .x = cursor_ndc.x,
            .y = cursor_ndc.y,
            .z = depth_sample,
            .w = 1.0,
        };
        const intersection_h = inv_view_proj.apply(point_ndc);
        const intersection = intersection_h.xyz().scale(1.0 / intersection_h.w);

        self.camera.terrain_grab = intersection;
    }

    self.input.reset();
}

fn acquireSurfaceTexture(self: *Application) ?*c.WGPUTextureImpl {
    var surface_texture: c.WGPUSurfaceTexture = undefined;
    surface_texture.nextInChain = null;
    c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);

    const acquire_status = surface_texture.status;

    switch (acquire_status) {
        c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
        c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
        => {
            if (acquire_status ==
                c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
            {
                // Reconfigure for more optimal surface next frame;
                // use suboptimal surface current frame
                self.reconfigureSurface(null);
            }
            return surface_texture.texture.?;
        },
        c.WGPUSurfaceGetCurrentTextureStatus_Timeout,
        => {
            return null;
        },
        c.WGPUSurfaceGetCurrentTextureStatus_Lost,
        c.WGPUSurfaceGetCurrentTextureStatus_Outdated,
        => {
            if (surface_texture.texture != null) {
                c.wgpuTextureRelease(surface_texture.texture);
            }
            self.reconfigureSurface(null);
            return null;
        },
        c.WGPUSurfaceGetCurrentTextureStatus_Error,
        => @panic("ERROR: Failed to get current surface texture"),
        else => unreachable,
    }
}

fn reconfigureSurface(
    self: *Application,
    depth_texture_bg_layout_dst: ?**c.WGPUBindGroupLayoutImpl,
) void {
    const device = self.device.?;

    c.wgpuSurfaceConfigure(self.surface, &.{
        .device = device,
        .format = self.surface_format,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .width = self.frame_width,
        .height = self.frame_height,
    });
    if (self.depth_texture) |t| {
        t.deinit();
    }
    self.depth_texture, const depth_texture_bg_layout = Texture.init(
        device,
        self.frame_width,
        self.frame_height,
        Texture.readable_depth_texture_config,
    );
    if (depth_texture_bg_layout_dst) |dst| {
        dst.* = depth_texture_bg_layout.?;
    }
}

fn requestAdapterCallback(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    if (status != c.WGPURequestAdapterStatus_Success) {
        @panic("ERROR: Failed to request adapter");
    }
    const adapter_dst: *c.WGPUAdapter = @ptrCast(@alignCast(userdata1.?));
    adapter_dst.* = adapter.?;
}

fn requestDeviceCallback(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    if (status != c.WGPURequestDeviceStatus_Success) {
        @panic("ERROR: Failed to request device");
    }
    const device_dst: *c.WGPUDevice = @ptrCast(@alignCast(userdata1.?));
    device_dst.* = device.?;
}

fn glfwErrorCallback(code: c_int, description: [*c]const u8) callconv(.c) void {
    std.debug.print("GLFW ERROR ({d}): {s}\n", .{ code, description });
}

pub fn windowAspect(self: Application) f32 {
    return @as(f32, @floatFromInt(self.window_width)) /
        @as(f32, @floatFromInt(self.window_height));
}
