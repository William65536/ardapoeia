const std = @import("std");
const c = @import("root").c;
const Triangle = @import("Triangle.zig");

const Application = @This();

window: *c.GLFWwindow = undefined,
window_width: u32,
window_height: u32, // must be >= 1

instance: c.WGPUInstance = undefined,
adapter: c.WGPUAdapter = undefined,
device: c.WGPUDevice = undefined,
queue: c.WGPUQueue = undefined,
surface: c.WGPUSurface = undefined,
surface_format: c.WGPUTextureFormat = undefined,

triangle: Triangle = undefined,

pub fn init(self: *Application) void {
    std.debug.assert(self.window_height >= 1);

    self.instance = c.wgpuCreateInstance(&.{
        .requiredFeatureCount = 1,
        .requiredFeatures = &[_]c.WGPUInstanceFeatureName{c.WGPUInstanceFeatureName_TimedWaitAny},
    }) orelse @panic("ERROR: Failed to create instance");

    const adapter_future = c.wgpuInstanceRequestAdapter(self.instance, null, .{
        .callback = requestAdapterCallback,
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .userdata1 = @ptrCast(&self.adapter),
        .userdata2 = null,
    });
    var adapter_future_info = c.WGPUFutureWaitInfo{ .future = adapter_future };
    if (c.wgpuInstanceWaitAny(
        self.instance,
        1,
        &adapter_future_info,
        std.math.maxInt(u64), // infinite timeout; adapter is required to proceed
    ) != c.WGPUStatus_Success) {
        @panic("ERROR: Failed to await adapter request");
    }
    defer c.wgpuAdapterRelease(self.adapter);

    const device_future = c.wgpuAdapterRequestDevice(self.adapter, &.{}, .{
        .callback = requestDeviceCallback,
        .mode = c.WGPUCallbackMode_WaitAnyOnly,
        .userdata1 = @ptrCast(&self.device),
        .userdata2 = null,
    });
    var device_future_info = c.WGPUFutureWaitInfo{ .future = device_future };
    if (c.wgpuInstanceWaitAny(
        self.instance,
        1,
        &device_future_info,
        std.math.maxInt(u64), // infinite timeout; device is required to proceed
    ) != c.WGPUStatus_Success) {
        @panic("ERROR: Failed to await device request");
    }

    self.queue = c.wgpuDeviceGetQueue(self.device) orelse
        @panic("ERROR: Failed to get queue");

    _ = c.glfwSetErrorCallback(glfwErrorCallback);
    if (c.glfwInit() == c.GLFW_FALSE) {
        @panic("ERROR: GLFW initialization failed");
    }
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    self.window = c.glfwCreateWindow(
        @intCast(self.window_width),
        @intCast(self.window_height),
        "Map of Arda",
        null,
        null,
    ) orelse @panic("ERROR: Failed to create window");

    self.surface = c.wgpuGlfwCreateSurfaceForWindow(self.instance, self.window);
    var capabilities: c.WGPUSurfaceCapabilities = undefined;
    capabilities.nextInChain = null;
    if (c.wgpuSurfaceGetCapabilities(self.surface, self.adapter, &capabilities) != c.WGPUStatus_Success) {
        @panic("ERROR: Failed to get surface capabilities");
    }
    self.surface_format = capabilities.formats[0];
    c.wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    self.reconfigureSurface();

    self.triangle = .init(self.device, self.surface_format);
}

// No deinit; browser takes care of cleanup

pub fn frame(self: *Application) void {
    // Process input
    {
        c.glfwPollEvents();
    }

    // Render
    {
        var surface_texture: c.WGPUSurfaceTexture = undefined;
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        if (surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal) {
            @panic("ERROR: Failed to get current surface texture");
        }
        defer c.wgpuTextureRelease(surface_texture.texture);

        const view = c.wgpuTextureCreateView(surface_texture.texture, null) orelse
            @panic("ERROR: Failed to create surface texture view");
        defer c.wgpuTextureViewRelease(view);

        const color_attachment: c.WGPURenderPassColorAttachment = .{
            .view = view,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
        };

        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, null) orelse
            @panic("ERROR: Failed to create command encoder");
        defer c.wgpuCommandEncoderRelease(encoder);

        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
            .colorAttachmentCount = 1,
            .colorAttachments = &color_attachment,
            .depthStencilAttachment = null,
        }) orelse
            @panic("ERROR: Failed to begin render pass");
        defer c.wgpuRenderPassEncoderRelease(pass);

        self.triangle.render(pass);

        c.wgpuRenderPassEncoderEnd(pass);
        const commands = c.wgpuCommandEncoderFinish(encoder, null) orelse
            @panic("ERROR: Failed to finish command encoding");
        defer c.wgpuCommandBufferRelease(commands);
        c.wgpuQueueSubmit(self.queue, 1, &commands);
    }
}

fn reconfigureSurface(self: *Application) void {
    c.wgpuSurfaceConfigure(self.surface, &.{
        .device = self.device,
        .format = self.surface_format,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .width = self.window_width,
        .height = self.window_height,
    });
}

fn requestAdapterCallback(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    _ = message;
    if (status != c.WGPURequestAdapterStatus_Success) {
        @panic("ERROR: Failed to request adapter");
    }
    const out: *c.WGPUAdapter = @ptrCast(@alignCast(userdata1.?));
    out.* = adapter.?;
}

fn requestDeviceCallback(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    _ = message;
    if (status != c.WGPURequestDeviceStatus_Success) {
        @panic("ERROR: Failed to request device");
    }
    const out: *c.WGPUDevice = @ptrCast(@alignCast(userdata1.?));
    out.* = device.?;
}

fn glfwErrorCallback(code: c_int, description: [*c]const u8) callconv(.c) void {
    std.debug.print("GLFW ERROR ({d}): {s}\n", .{ code, description });
}
