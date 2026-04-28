const std = @import("std");
const c = @import("c.zig").c;
const util = @import("util.zig");
const math = util.math;
const Input = @import("Input.zig");
const Texture = @import("util.zig").wgpu.Texture;
const SampleDepth = @import("SampleDepth.zig");
const Map = @import("Map.zig");
const TerrainGen = @import("TerrainGen.zig");
const Camera = @import("Camera.zig");
const Terrain = @import("Terrain.zig");

const Application = @This();

gpu_ready: bool = false,
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

last_time: f64 = 0.0, // `glfwGetTime` counts from app start
first_frame: bool = true,

sample_depth: SampleDepth = .{},

map: Map = .{},

terrain_gen: TerrainGen = .{},

camera: Camera = .{},

terrain: Terrain = .{},

pub fn init(self: *Application, window_width: u32, window_height: u32) void {
    std.debug.assert(window_width >= 1);
    std.debug.assert(window_height >= 1);
    self.window_width = window_width;
    self.window_height = window_height;
    self.initWgpu();
}

fn initWgpu(self: *Application) void {
    // TODO: Prevent hanging/crashing if WebGPU fails to initialize

    self.instance =
        c.wgpuCreateInstance(&.{}) orelse
        @panic("ERROR: Failed to create instance");

    _ = c.wgpuInstanceRequestAdapter(self.instance, &.{}, .{
        .callback = requestAdapterCallback,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .userdata1 = self,
        .userdata2 = undefined,
    });
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

    const self: *Application = @ptrCast(@alignCast(userdata1.?));
    self.adapter = adapter.?;

    _ = c.wgpuAdapterRequestDevice(self.adapter, &.{}, .{
        .callback = requestDeviceCallback,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .userdata1 = @ptrCast(self),
        .userdata2 = undefined,
    });
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

    const self: *Application = @ptrCast(@alignCast(userdata1.?));
    self.device = device.?;

    self.queue =
        c.wgpuDeviceGetQueue(self.device) orelse
        @panic("ERROR: Failed to get queue");

    var depth_texture_bg_layout: *c.WGPUBindGroupLayoutImpl = undefined;
    self.initWindow(&depth_texture_bg_layout);
    self.initResources(depth_texture_bg_layout);
    self.gpu_ready = true;
}

fn initWindow(
    self: *Application,
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
            @intCast(self.window_width),
            @intCast(self.window_height),
            "Ardapoeia",
            null,
            null,
        ) orelse @panic("ERROR: Failed to create window");

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

    const input_bg_layout = self.input.initGpu(device);
    defer c.wgpuBindGroupLayoutRelease(input_bg_layout);

    self.sample_depth = .init(device, input_bg_layout, depth_texture_bg_layout);

    var lod_leaves_bg_layout: *c.WGPUBindGroupLayoutImpl = undefined;
    defer c.wgpuBindGroupLayoutRelease(lod_leaves_bg_layout);
    self.terrain_gen = .init(
        device,
        &lod_leaves_bg_layout,
    );

    const camera_bg_layout = self.camera.initGpu(device);
    defer c.wgpuBindGroupLayoutRelease(camera_bg_layout);

    self.terrain =
        .init(
            device,
            self.surface_format,
            camera_bg_layout,
            lod_leaves_bg_layout,
            self.terrain_gen.height_samples,
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
    if (!self.gpu_ready) {
        c.wgpuInstanceProcessEvents(self.instance);
        return;
    }

    std.debug.assert(self.window_width >= 1);
    std.debug.assert(self.window_height >= 1);

    const instance = self.instance.?;
    const device = self.device.?;
    const queue = self.queue.?;
    const depth_texture = self.depth_texture.?;

    const now = c.glfwGetTime();
    const dt: f32 = @floatCast(now - self.last_time);
    self.last_time = now;

    const prev_frame_width = self.frame_width;
    const prev_frame_height = self.frame_height;

    // Process input
    c.glfwPollEvents();

    const framebuffer_updated =
        self.frame_width != prev_frame_width or
        self.frame_height != prev_frame_height;

    const camera_updated =
        self.camera.update(
            self.input,
            self.window_width,
            self.window_height,
            dt,
        ) or
        self.first_frame;

    if (camera_updated) {
        self.camera.upload(queue);
    }

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

    const encoder =
        c.wgpuDeviceCreateCommandEncoder(self.device, &.{
            .label = util.wgpu.stringView("scene"),
        }) orelse @panic("ERROR: Failed to create scene command encoder");
    defer c.wgpuCommandEncoderRelease(encoder);

    // Generate terrain
    if (camera_updated or framebuffer_updated) {
        // TODO: Perhaps generate every other frame or so

        const pass =
            c.wgpuCommandEncoderBeginComputePass(encoder, &.{
                .label = util.wgpu.stringView("terrain gen"),
            }) orelse
            @panic("ERROR: Failed to begin terrain gen compute pass");
        defer c.wgpuComputePassEncoderRelease(pass);

        self.terrain_gen.dispatch(
            pass,
            queue,
            self.map,
            self.camera,
        );

        c.wgpuComputePassEncoderEnd(pass);
    }

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

        self.terrain.render(
            pass,
            self.camera.uniform_bg,
            self.terrain_gen.leaves_bg,
            self.terrain_gen.leaf_count,
        );

        c.wgpuRenderPassEncoderEnd(pass);
    }

    // Sample from depth buffer
    {
        const pass =
            c.wgpuCommandEncoderBeginComputePass(encoder, &.{
                .label = util.wgpu.stringView("sample depth"),
            }) orelse
            @panic("ERROR: Failed to begin sample depth compute pass");
        defer c.wgpuComputePassEncoderRelease(pass);

        self.sample_depth.dispatch(
            pass,
            self.input.uniform_bg,
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

    if (self.input.middleMouseButtonJustPressed()) {
        self.sample_depth.requestSample(device, queue);
        self.camera.terrain_grab_state = .pending;
    }

    if (self.input.scroll_dy != 0.0) {
        self.sample_depth.requestSample(device, queue);
        self.camera.zoom_sensitivity_state =
            .{ .pending = .{ .scroll_dy = self.input.scroll_dy } };
    }

    if (self.sample_depth.pollSample(instance)) |depth_sample| blk: {
        const inv_view_proj = self.camera.viewProjMat().invert();

        const cursor_ndc =
            self.input.cursorNdc(self.window_width, self.window_height);

        const point_ndc: math.Vec4 = .{
            .x = cursor_ndc.x,
            .y = cursor_ndc.y,
            .z = depth_sample,
            .w = 1.0,
        };

        const intersection =
            if (depth_sample > 0.0) blk2: {
                const intersection_h = inv_view_proj.apply(point_ndc);
                break :blk2 intersection_h.xyz().scale(1.0 / intersection_h.w);
            } else blk2: {
                const camera_ray =
                    self.camera.rayFromCursor(cursor_ndc);
                const t = camera_ray.intersectXZPlane(0.0) orelse break :blk;
                if (t < 1.0e-6) {
                    break :blk;
                }
                break :blk2 camera_ray.at(t);
            };

        if (self.camera.terrain_grab_state == .pending) {
            self.camera.terrain_grab_state = .ready;
            self.camera.terrain_grab = intersection;
        }

        if (self.camera.zoom_sensitivity_state == .pending) {
            const dist = intersection.sub(self.camera.pos).mag();
            self.camera.zoom_sensitivity_state = .ready;
            self.camera.zoom_sensitivity = dist * 0.3;
        }
    }

    self.input.reset();
    self.first_frame = false;
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
    depth_texture_bg_layout_out: ?**c.WGPUBindGroupLayoutImpl,
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
    self.depth_texture = .init(
        device,
        self.frame_width,
        self.frame_height,
        .{
            .label = "depth",
            .format = c.WGPUTextureFormat_Depth32Float,
            .usage = c.WGPUTextureUsage_RenderAttachment |
                c.WGPUTextureUsage_TextureBinding,
            .with_sampler = false,
            .visibility = c.WGPUShaderStage_Compute,
        },
        depth_texture_bg_layout_out,
    );
}

fn glfwErrorCallback(code: c_int, description: [*c]const u8) callconv(.c) void {
    std.debug.print("GLFW ERROR ({d}): {s}\n", .{ code, description });
}
