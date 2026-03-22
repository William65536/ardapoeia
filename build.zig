const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
    });
    const optimize = b.standardOptimizeOption(.{});

    const emsdk_path = b.option([]const u8, "emsdk", "Path to Emscripten SDK") orelse
        std.process.getEnvVarOwned(b.allocator, "EMSDK") catch {
        std.log.err("{s}\n", .{"Pass -Demsdk=/path/to/emsdk or set $EMSDK"});
        std.process.exit(1);
    };
    const emcc_path = b.pathJoin(&.{ emsdk_path, "upstream/emscripten/emcc" });
    const emsdk_include_path = b.pathJoin(&.{ emsdk_path, "upstream/emscripten/cache/sysroot/include" });

    const dawn_path = b.option([]const u8, "dawn", "Path to Dawn") orelse
        std.process.getEnvVarOwned(b.allocator, "DAWN") catch {
        std.log.err("{s}\n", .{"Pass -Ddawn=/path/to/dawn or set $DAWN"});
        std.process.exit(1);
    };
    const dawn_include_path = b.pathJoin(&.{ dawn_path, "out/cmake-release/gen/src/emdawnwebgpu/include" });
    const dawn_glfw_utils_path = b.pathJoin(&.{ dawn_path, "src/dawn/glfw/utils_emscripten.cpp" });
    const dawn_build_path = b.pathJoin(&.{ dawn_path, "out/cmake-release" });
    const dawn_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        dawn_build_path,
        "--target",
        "emdawnwebgpu_headers_gen",
        "webgpu_headers_gen",
    });
    const dawn_cache_exists = !std.meta.isError(std.fs.cwd().access(b.pathJoin(&.{ dawn_build_path, "CMakeCache.txt" }), .{}));
    if (!dawn_cache_exists) {
        const dawn_configure = b.addSystemCommand(&.{
            "cmake",
            "-S",
            dawn_path,
            "-B",
            dawn_build_path,
            "-DCMAKE_BUILD_TYPE=Release",
            "-DDAWN_FETCH_DEPENDENCIES=ON",
        });
        dawn_build.step.dependOn(&dawn_configure.step);
    }

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
    app_obj.step.dependOn(&dawn_build.step);

    std.fs.cwd().makeDir(b.install_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const web_out_path = b.pathJoin(&.{ b.install_path, "dist" });
    std.fs.cwd().makeDir(web_out_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const emcc_link = b.addSystemCommand(&.{
        emcc_path,
        "-o",
        b.pathJoin(&.{ web_out_path, "index.html" }),
        "--use-port=emdawnwebgpu",
        "-sASYNCIFY",
        "-sALLOW_MEMORY_GROWTH",
        "-sUSE_GLFW=3",
        "--shell-file",
        "web/shell.html",
    });
    emcc_link.addArtifactArg(app_obj);
    emcc_link.addFileArg(.{ .cwd_relative = dawn_glfw_utils_path });

    b.default_step.dependOn(&emcc_link.step);
}
