const std = @import("std");
const c = @cImport({
    @cInclude("gdal.h");
    @cInclude("gdal_alg.h");
    @cInclude("gdal_utils.h");
    @cInclude("gdalwarper.h");
    @cInclude("ogr_srs_api.h");
});

const f32_no_data: f32 = -32767.0;
const u16_no_data: u16 = std.math.maxInt(u16);

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa_instance.deinit() == .ok);
    const gpa = gpa_instance.allocator();

    c.GDALAllRegister();

    const lat_n = 46;
    const lon_e = 7;
    const extent_left = 0.774;
    const extent_bottom = 0.476;
    const extent_right = 1.000;
    const extent_top = 0.644;

    const src_path =
        std.fmt.comptimePrint(
            "references/dems/copernicus_30m/Copernicus_DSM_COG_10_N{d:0>2}_00_E{d:0>3}_00_DEM.tif",
            .{ lat_n, lon_e },
        );
    const out_png_path = "references/dems/lauterbrunnen_dem.png";
    const out_meta_path = "references/dems/lauterbrunnen_dem.meta";

    const src_dem = c.GDALOpen(src_path, c.GA_ReadOnly) orelse
        return error.OpenFailed;
    defer std.debug.assert(c.GDALClose(src_dem) == c.CE_None);

    const clipped_dem = (try clipToExtent(
        src_dem,
        extent_left,
        extent_bottom,
        extent_right,
        extent_top,
    )).?;
    defer std.debug.assert(c.GDALClose(clipped_dem) == c.CE_None);

    const scratch_dem = try reprojectToAeqd(
        clipped_dem,
        lat_n,
        lon_e,
        extent_left,
        extent_bottom,
        extent_right,
        extent_top,
        gpa,
    );
    defer gpa.free(scratch_dem.buf);

    const elev = computeElevationRange(std.mem.bytesAsSlice(f32, scratch_dem.buf));

    const inscribed = computeInscribed(std.mem.bytesAsSlice(f32, scratch_dem.buf), @intCast(scratch_dem.width), @intCast(scratch_dem.height));

    const inscribed_buf = clipToInscribed(std.mem.bytesAsSlice(f32, scratch_dem.buf), @intCast(scratch_dem.width), inscribed);

    const noramalized_buf = normalize(std.mem.sliceAsBytes(inscribed_buf), elev.min, elev.max);

    try exportToPng(out_png_path, noramalized_buf, @intCast(inscribed.right - inscribed.left), @intCast(inscribed.bottom - inscribed.top));

    try exportMeta(out_meta_path, elev.min, elev.max);
}

fn clipToExtent(
    src_dem: c.GDALDatasetH,
    left: f32,
    bottom: f32,
    right: f32,
    top: f32,
) !c.GDALDatasetH {
    std.debug.assert(src_dem != null);
    std.debug.assert(0.0 <= left and left <= right and right <= 1.0);
    std.debug.assert(0.0 <= bottom and bottom <= top and top <= 1.0);

    const src_width = c.GDALGetRasterXSize(src_dem);
    const src_height = c.GDALGetRasterYSize(src_dem);

    // Ensure `src_dem` geo transform is equirectangular and spans 1deg x 1deg
    {
        var src_geo_transform: [6]f64 = undefined;
        if (c.GDALGetGeoTransform(src_dem, &src_geo_transform) != c.CE_None) {
            return error.GetGeoTransformFailed;
        }
        std.debug.assert(src_geo_transform[2] == 0.0); // no row rotation or shear
        std.debug.assert(src_geo_transform[4] == 0.0); // no col rotation or shear

        const lon_extent = @abs(src_geo_transform[1] * @as(f64, @floatFromInt(src_width)));
        const lat_extent = @abs(src_geo_transform[5] * @as(f64, @floatFromInt(src_height)));

        std.debug.assert(@abs(lon_extent - 1.0) < 1.0e-6);
        std.debug.assert(@abs(lat_extent - 1.0) < 1.0e-6);

        const proj_ref = c.GDALGetProjectionRef(src_dem).?;
        if (proj_ref[0] == '\x00') {
            return error.GetProjectionRefFailed;
        }
        const srs = c.OSRNewSpatialReference(proj_ref) orelse
            return error.NewSpatialReferenceFailed;
        defer c.OSRDestroySpatialReference(srs);
        std.debug.assert(c.OSRIsGeographic(srs) == 1);
    }

    const col_min: c_int = @intFromFloat(@floor(@as(f32, @floatFromInt(src_width)) * left));
    const row_min: c_int = @intFromFloat(@floor(@as(f32, @floatFromInt(src_height)) * (1.0 - top)));
    const col_max: c_int = @intFromFloat(@ceil(@as(f32, @floatFromInt(src_width)) * right));
    const row_max: c_int = @intFromFloat(@ceil(@as(f32, @floatFromInt(src_height)) * (1.0 - bottom)));
    const width = col_max - col_min;
    const height = row_max - row_min;

    var str_buf: [256]u8 = undefined;
    var str_i: usize = 0;
    const col_min_str = try std.fmt.bufPrintZ(str_buf[str_i..], "{d}", .{col_min});
    str_i += col_min_str.len + 1;
    const row_min_str = try std.fmt.bufPrintZ(str_buf[str_i..], "{d}", .{row_min});
    str_i += row_min_str.len + 1;
    const width_str = try std.fmt.bufPrintZ(str_buf[str_i..], "{d}", .{width});
    str_i += width_str.len + 1;
    const height_str = try std.fmt.bufPrintZ(str_buf[str_i..], "{d}", .{height});

    const translate_args = [_:null]?[*:0]const u8{
        "-of",
        "MEM",
        "-srcwin",
        col_min_str,
        row_min_str,
        width_str,
        height_str,
    };

    const translate_opts = c.GDALTranslateOptionsNew(
        @ptrCast(@constCast(&translate_args)),
        null,
    ) orelse return error.TranslateOptionsNewFailed;
    defer c.GDALTranslateOptionsFree(translate_opts);

    return c.GDALTranslate("", src_dem, translate_opts, null) orelse
        return error.TranslateFailed;
}

fn reprojectToAeqd(
    clipped_dem: c.GDALDatasetH,
    lat_n: u32,
    lon_e: u32,
    extent_left: f32,
    extent_bottom: f32,
    extent_right: f32,
    extent_top: f32,
    gpa: std.mem.Allocator,
) !struct { buf: []align(4) u8, width: c_int, height: c_int } {
    std.debug.assert(clipped_dem != null);
    std.debug.assert(0.0 <= extent_left and extent_left <= extent_right and extent_right <= 1.0);
    std.debug.assert(0.0 <= extent_bottom and extent_bottom <= extent_top and extent_top <= 1.0);

    var str_buf: [256]u8 = undefined;
    var str_i: usize = 0;

    const center_lat = @as(f32, @floatFromInt(lat_n)) + (extent_bottom + extent_top) * 0.5;
    const center_long = @as(f32, @floatFromInt(lon_e)) + (extent_left + extent_right) * 0.5;

    const srs = try std.fmt.bufPrintZ(
        str_buf[str_i..],
        "+proj=aeqd +lat_0={d} +lon_0={d} +datum=WGS84 +units=m",
        .{ center_lat, center_long },
    );
    str_i += srs.len + 1;

    // Compute width, height, and geo transform of reprojected output
    const width, const height, const geo_transform = blk: {
        const aeqd_transform =
            c.GDALCreateGenImgProjTransformer(
                clipped_dem,
                null,
                null,
                srs,
                0,
                0,
                1,
            ) orelse return error.TransformerFailed;
        defer c.GDALDestroyGenImgProjTransformer(aeqd_transform);

        var geo_transform: [6]f64 = undefined; // px to georeferenced coordinates
        var width: c_int = undefined;
        var height: c_int = undefined;
        if (c.GDALSuggestedWarpOutput(
            clipped_dem,
            c.GDALGenImgProjTransform,
            aeqd_transform,
            &geo_transform,
            &width,
            &height,
        ) != c.CE_None) {
            return error.SuggestedWarpOutputFailed;
        }

        break :blk .{ width, height, geo_transform };
    };

    // Allocate buffer large enough to contain reprojected output; will also be used for all subsequent operations
    const buf = try gpa.alloc(f32, @intCast(width * height));
    errdefer gpa.free(buf);
    @memset(buf, f32_no_data);

    // Create MEM dataset backed by `buf`, configure its spatial reference, and reproject source DEM into it
    {
        const mem_driver = c.GDALGetDriverByName("MEM") orelse return error.GetDriverByNameFailed;
        const out_dem = c.GDALCreate(mem_driver, "", width, height, 0, c.GDT_Float32, null) orelse return error.CreateFailed;
        defer std.debug.assert(c.GDALClose(out_dem) == c.CE_None);

        // Point `out_dem` band 1 to `buf`
        {
            const data_pointer_str = try std.fmt.bufPrintZ(str_buf[str_i..], "DATAPOINTER={d}", .{@intFromPtr(buf.ptr)});
            str_i += data_pointer_str.len + 1;
            const line_offset_str = try std.fmt.bufPrintZ(str_buf[str_i..], "LINEOFFSET={d}", .{@as(usize, @intCast(width)) * 4});

            const band_opts = [_:null]?[*:0]const u8{
                data_pointer_str,
                "PIXELOFFSET=4",
                line_offset_str,
                null,
            };

            if (c.GDALAddBand(out_dem, c.GDT_Float32, @ptrCast(@constCast(&band_opts))) != c.CE_None) {
                return error.AddBandFailed;
            }
        }

        // Set geo transform, spatial reference, and no data for `out_dem`
        {
            if (c.GDALSetGeoTransform(out_dem, @constCast(&geo_transform)) != c.CE_None) {
                return error.SetGeoTransformFailed;
            }
            if (c.GDALSetProjection(out_dem, srs) != c.CE_None) {
                return error.SetProjectionFailed;
            }

            const out_dem_band_1 = c.GDALGetRasterBand(out_dem, 1).?;
            if (c.GDALSetRasterNoDataValue(out_dem_band_1, f32_no_data) != c.CE_None) {
                return error.SetNoDataFailed;
            }
        }

        // Reproject source DEM into `out_dem`
        if (c.GDALReprojectImage(
            clipped_dem,
            null,
            out_dem,
            srs,
            c.GRA_Cubic,
            0.0,
            0.0,
            null,
            null,
            null,
        ) != c.CE_None) {
            return error.ReprojectImageFailed;
        }
    }

    return .{ .buf = std.mem.sliceAsBytes(buf), .width = width, .height = height };
}

// Handle the case where there are no minimums or maximums
fn computeElevationRange(aeqd_dem_buf: []const f32) struct { min: f32, max: f32 } {
    var elev_min: f32 = std.math.floatMax(f32);
    var elev_max: f32 = -std.math.floatMax(f32);

    for (aeqd_dem_buf) |v| {
        if (v == f32_no_data) {
            continue;
        }
        elev_min = @min(elev_min, v);
        elev_max = @max(elev_max, v);
    }

    return .{
        .min = elev_min,
        .max = elev_max,
    };
}

// TODO: This is not robust at all
fn computeInscribed(
    aeqd_dem_buf: []const f32,
    aeqd_dem_width: usize,
    aeqd_dem_height: usize,
) Box {
    if (aeqd_dem_width == 0 or aeqd_dem_height == 0) {
        @panic("TODO!");
    }

    var left: usize = 0;
    var right = aeqd_dem_width - 1;

    for (0..aeqd_dem_height) |y| {
        var left_row: usize = 0;
        while (left_row < aeqd_dem_width) : (left_row += 1) {
            if (aeqd_dem_buf[y * aeqd_dem_width + left_row] != f32_no_data) {
                break;
            }
        }
        left = @max(left, left_row);

        var right_row = aeqd_dem_width;
        while (right_row > 0) : (right_row -= 1) {
            if (aeqd_dem_buf[y * aeqd_dem_width + (right_row - 1)] != f32_no_data) {
                break;
            }
        }
        right = @min(right, right_row);
    }

    if (right <= left) {
        @panic("TODO!");
    }

    var top: usize = 0;
    var bottom = aeqd_dem_height - 1;

    for (left..right) |x| {
        var top_col: usize = 0;
        while (top_col < aeqd_dem_height) : (top_col += 1) {
            if (aeqd_dem_buf[top_col * aeqd_dem_width + x] != f32_no_data) {
                break;
            }
        }
        top = @max(top, top_col);

        var bottom_col = aeqd_dem_height;
        while (bottom_col > 0) : (bottom_col -= 1) {
            if (aeqd_dem_buf[(bottom_col - 1) * aeqd_dem_width + x] != f32_no_data) {
                break;
            }
        }
        bottom = @min(bottom, bottom_col);
    }

    if (bottom <= top) {
        @panic("TODO!");
    }

    if (@import("builtin").mode == .Debug) {
        for (top..bottom) |y| {
            for (left..right) |x| {
                const v = aeqd_dem_buf[y * aeqd_dem_width + x];
                if (v == f32_no_data) {
                    @panic("`computeInscribed` does not shave off all no data");
                }
            }
        }
    }

    return .{
        .top = top,
        .right = right,
        .bottom = bottom,
        .left = left,
    };
}

fn clipToInscribed(
    aeqd_dem_buf: []f32,
    aeqd_dem_width: usize,
    inscribed: Box,
) []f32 {
    var dest_i: usize = 0;

    // Since `inscribed` rows are shorter than `aeqd_dem_buf` rows, data is
    // clobbered only if it has already been read from
    for (inscribed.top..inscribed.bottom) |y| {
        const left = y * aeqd_dem_width + inscribed.left;
        const right = y * aeqd_dem_width + inscribed.right;
        @memmove(aeqd_dem_buf[dest_i..][0 .. right - left], aeqd_dem_buf[left..right]);
        dest_i += right - left;
    }

    return aeqd_dem_buf[0..dest_i];
}

fn normalize(scratch_buf: []align(4) u8, elev_min: f32, elev_max: f32) []const u16 {
    const scratch_buf_f32 = std.mem.bytesAsSlice(f32, scratch_buf);
    const scratch_buf_u16 = std.mem.bytesAsSlice(u16, scratch_buf)[0..scratch_buf_f32.len];

    // Since @sizeOf(u16) <= @sizeOf(f32), data is clobbered only if it has already been read from
    for (scratch_buf_u16, scratch_buf_f32) |*w, v| {
        if (v == f32_no_data) {
            w.* = u16_no_data;
            continue;
        }
        w.* = @intFromFloat((@as(f64, v) - @as(f64, elev_min)) / (@as(f64, elev_max) - @as(f64, elev_min)) * (std.math.maxInt(u16) - 1));
    }

    return scratch_buf_u16;
}

fn exportToPng(
    out_path: [*:0]const u8,
    normalized_buf: []const u16,
    width: c_int,
    height: c_int,
) !void {
    std.debug.assert(normalized_buf.len == @as(usize, @intCast(width * height)));

    // Create MEM dataset to be backed by `normalized_buf`
    const mem_driver = c.GDALGetDriverByName("MEM") orelse return error.GetDriverByNameFailed;
    const src_dem = c.GDALCreate(mem_driver, "", width, height, 0, c.GDT_UInt16, null) orelse return error.CreateFailed;
    defer std.debug.assert(c.GDALClose(src_dem) == c.CE_None);

    // Point `src_dem` band 1 to `normalized_buf`
    {
        var str_buf: [256]u8 = undefined;
        const data_pointer_str = try std.fmt.bufPrintZ(&str_buf, "DATAPOINTER={d}", .{@intFromPtr(normalized_buf.ptr)});
        const line_offset_str = try std.fmt.bufPrintZ(str_buf[data_pointer_str.len + 1 ..], "LINEOFFSET={d}", .{@as(usize, @intCast(width)) * 2});

        const band_opts = [_:null]?[*:0]const u8{
            data_pointer_str,
            "PIXELOFFSET=2",
            line_offset_str,
            null,
        };

        if (c.GDALAddBand(src_dem, c.GDT_UInt16, @ptrCast(@constCast(&band_opts))) != c.CE_None) {
            return error.AddBandFailed;
        }
    }

    // Copy raw MEM `src_dem` to encoded PNG `out_dem`
    const png_driver = c.GDALGetDriverByName("PNG") orelse return error.GetDriverByNameFailed;
    const out_dem = c.GDALCreateCopy(png_driver, out_path, src_dem, 0, null, null, null) orelse return error.CreateCopyFailed;
    defer std.debug.assert(c.GDALClose(out_dem) == c.CE_None);
}

fn exportMeta(out_path: [:0]const u8, elev_min: f32, elev_max: f32) !void {
    if (std.fs.path.dirname(out_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    const out = try std.fs.cwd().createFile(out_path, .{
        .truncate = true,
    });
    defer out.close();

    try out.writeAll(std.mem.sliceAsBytes(&[_]f32{ elev_min, elev_max }));
}

const Box = struct {
    top: usize,
    right: usize, // exclusive
    bottom: usize, // exclusive
    left: usize,
};
