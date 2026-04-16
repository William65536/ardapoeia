const c = @import("../c.zig").c;

pub fn stringView(str: []const u8) c.WGPUStringView {
    return .{ .data = str.ptr, .length = str.len };
}

pub const Texture = @import("wgpu/Texture.zig");
