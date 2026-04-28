const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    try buildWeb(b, optimize);
    try buildDemTool(b, optimize);
}

pub fn buildWeb(b: *std.Build, optimize: std.builtin.OptimizeMode) !void {
    const web_step = b.step("web", "Build the web app");
    b.default_step.dependOn(web_step);

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
    });

    const emsdk_path = b.option([]const u8, "emsdk", "Path to Emscripten SDK") orelse
        std.process.getEnvVarOwned(b.allocator, "EMSDK") catch |e| switch (e) {
        std.process.GetEnvVarOwnedError.EnvironmentVariableNotFound => {
            web_step.dependOn(try addFailStep(b, "{s}", .{"Pass -Demsdk=/path/to/emsdk or set $EMSDK"}));
            return;
        },
        std.process.GetEnvVarOwnedError.OutOfMemory => return e,
        std.process.GetEnvVarOwnedError.InvalidWtf8 => unreachable,
    };
    const emcc_path = b.pathJoin(&.{ emsdk_path, "upstream/emscripten/emcc" });
    const emsdk_include_path = b.pathJoin(&.{ emsdk_path, "upstream/emscripten/cache/sysroot/include" });

    const dawn_path = b.option([]const u8, "dawn", "Path to Dawn") orelse
        std.process.getEnvVarOwned(b.allocator, "DAWN") catch |e| switch (e) {
        std.process.GetEnvVarOwnedError.EnvironmentVariableNotFound => {
            web_step.dependOn(try addFailStep(b, "{s}", .{"Pass -Ddawn=/path/to/dawn or set $DAWN"}));
            return;
        },
        std.process.GetEnvVarOwnedError.OutOfMemory => return e,
        std.process.GetEnvVarOwnedError.InvalidWtf8 => unreachable,
    };
    const dawn_include_path = b.pathJoin(&.{ dawn_path, "out/cmake-release/gen/src/emdawnwebgpu/include" });
    const dawn_glfw_utils_path = b.pathJoin(&.{ dawn_path, "src/dawn/glfw/utils_emscripten.cpp" });
    const dawn_build_path = b.pathJoin(&.{ dawn_path, "out/cmake-release" });
    // zig fmt: off
    const dawn_build = b.addSystemCommand(&.{
        "cmake",
        "--build", dawn_build_path,
        "--target", "emdawnwebgpu_headers_gen", "webgpu_headers_gen",
    });
    // zig fmt: on
    std.fs.cwd().access(b.pathJoin(&.{ dawn_build_path, "CMakeCache.txt" }), .{}) catch |e| switch (e) {
        std.fs.Dir.AccessError.FileNotFound => {
            // zig fmt: off
        const dawn_configure = b.addSystemCommand(&.{
            "cmake",
            "-S", dawn_path,
            "-B", dawn_build_path,
            "-DCMAKE_BUILD_TYPE=Release", "-DDAWN_FETCH_DEPENDENCIES=ON",
        });
        // zig fmt: on
            dawn_build.step.dependOn(&dawn_configure.step);
        },
        else => return e,
    };

    const app_obj = b.addObject(.{
        .name = "ardapoeia",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    app_obj.addIncludePath(.{ .cwd_relative = dawn_include_path }); // take priority over EMSDK's webgpu headers
    app_obj.addIncludePath(.{ .cwd_relative = emsdk_include_path });
    app_obj.addIncludePath(b.path("lib/stb"));
    app_obj.step.dependOn(&dawn_build.step);

    const stbi_compile = b.addSystemCommand(&.{
        emcc_path,
        "-c",
        "-xc",
        "-Ilib/stb",
        "-DSTB_IMAGE_IMPLEMENTATION",
    });
    stbi_compile.addFileArg(b.path("lib/stb/stb_image.h"));
    stbi_compile.addArg("-o");
    const stbi_o = stbi_compile.addOutputFileArg("stbi.o");

    const web_out_path = b.pathJoin(&.{ b.install_path, "dist" });
    // zig fmt: off
    const emcc_link = b.addSystemCommand(&.{
        emcc_path,
        "-o", b.pathJoin(&.{ web_out_path, "index.html" }),
        "--use-port=emdawnwebgpu",
        "-sALLOW_MEMORY_GROWTH", "-sUSE_GLFW=3",
        "--shell-file", "web/shell.html",
    });
    // zig fmt: on
    emcc_link.addArtifactArg(app_obj);
    emcc_link.addFileArg(.{ .cwd_relative = dawn_glfw_utils_path });
    emcc_link.addFileArg(stbi_o);

    emcc_link.step.dependOn(try addMakePathStep(b, web_out_path));
    web_step.dependOn(&emcc_link.step);
}

fn buildDemTool(b: *std.Build, optimize: std.builtin.OptimizeMode) !void {
    const tools_step = b.step("dem", "Build the native DEM tool and fetch dependencies");

    const target = b.resolveTargetQuery(.{});

    const dem_tool = b.addExecutable(.{
        .name = "dem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dem/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dem_tool.linkSystemLibrary("gdal");
    dem_tool.linkLibC();

    const copernicus_30m_path = "references/dems/copernicus_30m";
    const make_copernicus_30m_path_step = try addMakePathStep(b, copernicus_30m_path);

    inline for (46..47) |latitude| {
        inline for (7..8) |longitude| {
            const tile = std.fmt.comptimePrint("Copernicus_DSM_COG_10_N{:02}_00_E{:03}_00_DEM", .{ latitude, longitude });
            const tile_url = "https://copernicus-dem-30m.s3.amazonaws.com/" ++ tile ++ "/" ++ tile ++ ".tif";
            const tile_out_path = b.pathJoin(&.{ copernicus_30m_path, tile ++ ".tif" });

            std.fs.cwd().access(tile_out_path, .{}) catch |e| switch (e) {
                std.fs.Dir.AccessError.FileNotFound => {
                    // zig fmt: off
                    const tile_fetch = b.addSystemCommand(&.{
                        "curl", "-L",
                        "-o", tile_out_path,
                        tile_url,
                    });
                    // zig fmt: on

                    tile_fetch.step.dependOn(make_copernicus_30m_path_step);
                    tools_step.dependOn(&tile_fetch.step);
                },
                else => return e,
            };
        }
    }

    tools_step.dependOn(&b.addInstallArtifact(dem_tool, .{
        .dest_dir = .{ .override = .{ .custom = "tools" } },
    }).step);
}

fn addFailStep(
    b: *std.Build,
    comptime format: []const u8,
    args: anytype,
) std.mem.Allocator.Error!*std.Build.Step {
    const step = try b.allocator.create(std.Build.Step);

    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "fail",
        .owner = b,
        .makeFn = struct {
            fn make(s: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
                s.owner.invalid_user_input = true;
                std.log.err(format, args);
                return error.InvalidUserInput;
            }
        }.make,
    });

    return step;
}

const MakePathStep = struct {
    step: std.Build.Step,
    path: []const u8,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *const MakePathStep = @fieldParentPtr("step", step);
        try std.fs.cwd().makePath(self.path);
    }
};

fn addMakePathStep(b: *std.Build, path: []const u8) std.mem.Allocator.Error!*std.Build.Step {
    const self = try b.allocator.create(MakePathStep);
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "mkdir",
            .owner = b,
            .makeFn = MakePathStep.make,
        }),
        .path = path,
    };
    return &self.step;
}
