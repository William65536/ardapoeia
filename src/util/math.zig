const std = @import("std");

const eps = 1.0e-6;

pub const Vec2 = extern struct {
    x: f32,
    y: f32,
};

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .{ .x = 0.0, .y = 0.0, .z = 0.0 };

    pub const unit_y: Vec3 = .{ .x = 0.0, .y = 1.0, .z = 0.0 };

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
            .z = self.z - other.z,
        };
    }

    pub fn scale(self: Vec3, coeff: f32) Vec3 {
        return .{
            .x = self.x * coeff,
            .y = self.y * coeff,
            .z = self.z * coeff,
        };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn mag2(self: Vec3) f32 {
        return self.dot(self);
    }

    pub fn mag(self: Vec3) f32 {
        return @sqrt(self.mag2());
    }

    // Assumes `self` is nonzero
    pub fn normalize(self: Vec3) Vec3 {
        return self.scale(1.0 / self.mag());
    }
};

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn xyz(self: Vec4) Vec3 {
        return .{ .x = self.x, .y = self.y, .z = self.z };
    }
};

pub const Mat4 = extern struct {
    cols: [4]Vec4,

    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        var product: Mat4 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0.0;
                for (0..4) |i| {
                    sum +=
                        @as([4]f32, @bitCast(self.cols[i]))[row] *
                        @as([4]f32, @bitCast(other.cols[col]))[i];
                }
                @as(*[4]f32, @ptrCast(&product.cols[col]))[row] = sum;
            }
        }
        return product;
    }

    pub fn apply(self: Mat4, v: Vec4) Vec4 {
        return .{
            .x = self.cols[0].x * v.x + self.cols[1].x * v.y +
                self.cols[2].x * v.z + self.cols[3].x * v.w,
            .y = self.cols[0].y * v.x + self.cols[1].y * v.y +
                self.cols[2].y * v.z + self.cols[3].y * v.w,
            .z = self.cols[0].z * v.x + self.cols[1].z * v.y +
                self.cols[2].z * v.z + self.cols[3].z * v.w,
            .w = self.cols[0].w * v.x + self.cols[1].w * v.y +
                self.cols[2].w * v.z + self.cols[3].w * v.w,
        };
    }

    // `self` is assumed to be invertible
    pub fn invert(self: Mat4) Mat4 {
        // Port of `do_inverse4` from nalgebra.rs which is in turn based on MESA:
        // https://github.com/dimforge/nalgebra/blob/c52ca1feda5bdbbc1d839b45ecd62e28bb7b58a5/src/linalg/inverse.rs

        const m = self.cols;

        // zig fmt: off
        const cofactor_00 =   m[1].y * m[2].z * m[3].w - m[1].y * m[2].w * m[3].z
                            - m[2].y * m[1].z * m[3].w + m[2].y * m[1].w * m[3].z
                            + m[3].y * m[1].z * m[2].w - m[3].y * m[1].w * m[2].z;
        const cofactor_01 = - m[1].x * m[2].z * m[3].w + m[1].x * m[2].w * m[3].z
                            + m[2].x * m[1].z * m[3].w - m[2].x * m[1].w * m[3].z
                            - m[3].x * m[1].z * m[2].w + m[3].x * m[1].w * m[2].z;
        const cofactor_02 =   m[1].x * m[2].y * m[3].w - m[1].x * m[2].w * m[3].y
                            - m[2].x * m[1].y * m[3].w + m[2].x * m[1].w * m[3].y
                            + m[3].x * m[1].y * m[2].w - m[3].x * m[1].w * m[2].y;
        const cofactor_03 = - m[1].x * m[2].y * m[3].z + m[1].x * m[2].z * m[3].y
                            + m[2].x * m[1].y * m[3].z - m[2].x * m[1].z * m[3].y
                            - m[3].x * m[1].y * m[2].z + m[3].x * m[1].z * m[2].y;
        // zig fmt: on

        var inv: [4]Vec4 = undefined;

        // zig fmt: off
        inv[0].x = cofactor_00;
        inv[0].y = - m[0].y * m[2].z * m[3].w + m[0].y * m[2].w * m[3].z
                   + m[2].y * m[0].z * m[3].w - m[2].y * m[0].w * m[3].z
                   - m[3].y * m[0].z * m[2].w + m[3].y * m[0].w * m[2].z;
        inv[0].z =   m[0].y * m[1].z * m[3].w - m[0].y * m[1].w * m[3].z
                   - m[1].y * m[0].z * m[3].w + m[1].y * m[0].w * m[3].z
                   + m[3].y * m[0].z * m[1].w - m[3].y * m[0].w * m[1].z;
        inv[0].w = - m[0].y * m[1].z * m[2].w + m[0].y * m[1].w * m[2].z
                   + m[1].y * m[0].z * m[2].w - m[1].y * m[0].w * m[2].z
                   - m[2].y * m[0].z * m[1].w + m[2].y * m[0].w * m[1].z;

        inv[1].x = cofactor_01;
        inv[1].y =   m[0].x * m[2].z * m[3].w - m[0].x * m[2].w * m[3].z
                   - m[2].x * m[0].z * m[3].w + m[2].x * m[0].w * m[3].z
                   + m[3].x * m[0].z * m[2].w - m[3].x * m[0].w * m[2].z;
        inv[1].z = - m[0].x * m[1].z * m[3].w + m[0].x * m[1].w * m[3].z
                   + m[1].x * m[0].z * m[3].w - m[1].x * m[0].w * m[3].z
                   - m[3].x * m[0].z * m[1].w + m[3].x * m[0].w * m[1].z;
        inv[1].w =   m[0].x * m[1].z * m[2].w - m[0].x * m[1].w * m[2].z
                   - m[1].x * m[0].z * m[2].w + m[1].x * m[0].w * m[2].z
                   + m[2].x * m[0].z * m[1].w - m[2].x * m[0].w * m[1].z;

        inv[2].x = cofactor_02;
        inv[2].y = - m[0].x * m[2].y * m[3].w + m[0].x * m[2].w * m[3].y
                   + m[2].x * m[0].y * m[3].w - m[2].x * m[0].w * m[3].y
                   - m[3].x * m[0].y * m[2].w + m[3].x * m[0].w * m[2].y;
        inv[2].z =   m[0].x * m[1].y * m[3].w - m[0].x * m[1].w * m[3].y
                   - m[1].x * m[0].y * m[3].w + m[1].x * m[0].w * m[3].y
                   + m[3].x * m[0].y * m[1].w - m[3].x * m[0].w * m[1].y;
        inv[2].w = - m[0].x * m[1].y * m[2].w + m[0].x * m[1].w * m[2].y
                   + m[1].x * m[0].y * m[2].w - m[1].x * m[0].w * m[2].y
                   - m[2].x * m[0].y * m[1].w + m[2].x * m[0].w * m[1].y;

        inv[3].x = cofactor_03;
        inv[3].y =   m[0].x * m[2].y * m[3].z - m[0].x * m[2].z * m[3].y
                   - m[2].x * m[0].y * m[3].z + m[2].x * m[0].z * m[3].y
                   + m[3].x * m[0].y * m[2].z - m[3].x * m[0].z * m[2].y;
        inv[3].z = - m[0].x * m[1].y * m[3].z + m[0].x * m[1].z * m[3].y
                   + m[1].x * m[0].y * m[3].z - m[1].x * m[0].z * m[3].y
                   - m[3].x * m[0].y * m[1].z + m[3].x * m[0].z * m[1].y;
        inv[3].w =   m[0].x * m[1].y * m[2].z - m[0].x * m[1].z * m[2].y
                   - m[1].x * m[0].y * m[2].z + m[1].x * m[0].z * m[2].y
                   + m[2].x * m[0].y * m[1].z - m[2].x * m[0].z * m[1].y;
        // zig fmt: on

        const det =
            m[0].x * cofactor_00 + m[0].y * cofactor_01 +
            m[0].z * cofactor_02 + m[0].w * cofactor_03;
        std.debug.assert(@abs(det) >= 1.0e-6);

        for (0..4) |col| {
            for (0..4) |row| {
                @as(*[4]f32, @ptrCast(&inv[col]))[row] /= det;
            }
        }

        return .{ .cols = inv };
    }
};

pub const Ray3 = extern struct {
    origin: Vec3,
    dir: Vec3,

    pub fn intersectXZPlane(self: Ray3, plane_y: f32) ?f32 {
        // Parallel to plane
        if (@abs(self.dir.y) < eps) {
            return null;
        }

        return (plane_y - self.origin.y) / self.dir.y;
    }

    pub fn at(self: Ray3, t: f32) Vec3 {
        return self.origin.add(self.dir.scale(t));
    }
};
