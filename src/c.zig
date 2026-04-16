pub const c = @cImport({
    @cInclude("webgpu/webgpu.h");
    @cInclude("webgpu/webgpu_glfw.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("emscripten/emscripten.h");
    @cInclude("stb_image.h");
});
