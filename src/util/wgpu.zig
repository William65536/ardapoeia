const c = @import("root").c;

pub fn createStringView(str: []const u8) c.WGPUStringView {
    return .{ .data = str.ptr, .length = str.len };
}
