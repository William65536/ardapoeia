const c = @import("c.zig").c;
const util = @import("util.zig");

const Map = @This();

width: u32 = 1 << 22, // `>= 1`
depth: u32 = 1 << 22, // `>= 1`
min_height: f32 = -1_000.0,
max_height: f32 = 1_000.0,
