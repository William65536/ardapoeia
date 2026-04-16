const std = @import("std");
const c = @import("c.zig").c;
const Application = @import("Application.zig");

pub fn main() !void {
    globals.app.init(750, 500);
    c.emscripten_set_main_loop_arg(
        frameCallback,
        &globals.app,
        0, // sync to requestAnimationFrame
        false,
    );
}

fn frameCallback(arg: ?*anyopaque) callconv(.c) void {
    const app: *Application = @ptrCast(@alignCast(arg.?));
    app.frame();
}

// `app` must outlive `main()` since `emscripten_set_main_loop_arg` returns
// immediately and `frameCallback` is called asynchronously by the browser.
// Static allocation ensures it lives for the entire program lifetime.
const globals = struct {
    var app: Application = .{};
};
