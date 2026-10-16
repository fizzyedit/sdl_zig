const std = @import("std");
const linux = @import("src/linux.zig");
const windows = @import("src/windows.zig");
const macos = @import("src/macos.zig");
const ios = @import("src/ios.zig");
const android = @import("src/android.zig");
const build_zon = @import("build.zig.zon");

const assert = std.debug.assert;

pub const sources = @import("src/sdl.zon");

pub const flags = &.{
    "-fno-strict-aliasing",
    "-fvisibility=hidden",
    "-DUSING_GENERATED_CONFIG_H",
};

pub const SystemPaths = struct {
    include: ?std.Build.LazyPath,
    framework: ?std.Build.LazyPath,
    library: ?std.Build.LazyPath,

    pub fn print_missing_system_path_option(path: ?std.Build.LazyPath, comptime flag: []const u8, comptime platform: []const u8) std.Build.LazyPath {
        return path orelse {
            std.log.err("'-D" ++ flag ++ "' is required when building SDL for " ++ platform, .{});
            std.process.exit(1);
        };
    }
};

pub fn build(b: *std.Build) !void {
    // Get the upstream source and build options. A package that patches SDL hands in its patched
    // tree; it must be the release `sdl`'s `.version` names, which is the library's SO version.
    const upstream = b.option(
        std.Build.LazyPath,
        "sdl_source",
        "SDL source tree to build instead of the `sdl` dependency, e.g. a patched copy of it",
    ) orelse b.dependency("sdl", .{}).path("");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const default_target_config = b.option(
        bool,
        "default_target_config",
        \\provides a default `SDL_build_config.h` and dependencies for the current target, defaults
        \\to true
        ,
    ) orelse true;

    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        \\whether to build a static or dynamic library, defaults to static
        ,
    ) orelse .static;

    // Cross-compiling to a target whose SDK isn't bundled with Zig (iOS, Android) needs the
    // SDK's headers/frameworks/libs passed in explicitly. Scoped to the SDL library only, unlike
    // `--sysroot` this does not re-roots paths across the whole build graph.
    const system_paths: SystemPaths = .{
        .include = b.option(std.Build.LazyPath, "include_path", "SDK include dir, e.g. $(xcrun --sdk iphoneos --show-sdk-path)/usr/include or <ndk sysroot>/usr/include"),
        .framework = b.option(std.Build.LazyPath, "framework_path", "SDK framework dir, e.g. $(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks"),
        .library = b.option(std.Build.LazyPath, "library_path", "SDK library dir, e.g. $(xcrun --sdk iphoneos --show-sdk-path)/usr/lib"),
    };

    // Get the SO version. This is the same as the SDL version, but the major version is elided
    // since it's baked into the name. This mirrors the official build process.
    var sdl_so_version = comptime std.SemanticVersion.parse(build_zon.dependencies.sdl.version) catch unreachable;
    assert(sdl_so_version.major == 3);
    sdl_so_version.major = 0;

    // Create the library
    const lib = b.addLibrary(.{
        .name = "SDL3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = linkage,
        .version = sdl_so_version,
    });
    switch (linkage) {
        .dynamic => {
            lib.root_module.addCMacro("DLL_EXPORT", "1");
            lib.setVersionScript(upstream.path(b, "src/dynapi/SDL_dynapi.sym"));
        },
        .static => lib.root_module.addCMacro("SDL_STATIC_LIB", "1"),
    }
    lib.root_module.addCMacro("SDL_VENDOR_INFO", std.fmt.comptimePrint("\"{s} {s}\"", .{
        "https://github.com/allyourcodebase/SDL",
        build_zon.version,
    }));
    lib.installHeadersDirectory(upstream.path(b, "include/SDL3"), "SDL3", .{});
    b.installArtifact(lib);

    // Set the include path
    lib.root_module.addIncludePath(upstream.path(b, "include"));
    lib.root_module.addIncludePath(upstream.path(b, "src"));
    lib.root_module.addIncludePath(upstream.path(b, "src/video/khronos"));

    // Compile the generic sources. Not the Linux core for Windows: SDL's own build compiles it only
    // on Linux, and `core/linux/SDL_dbus.c` includes <unistd.h> before its guard, which MSVC does
    // not have (MinGW does, which is why a windows-gnu build never noticed).
    const all_generic: []const []const u8 = &sources.generic;
    const generic = if (target.result.os.tag == .windows) blk: {
        var keep: std.ArrayList([]const u8) = .empty;
        for (all_generic) |file| {
            if (!std.mem.startsWith(u8, file, "core/linux/")) keep.append(b.allocator, file) catch @panic("OOM");
        }
        break :blk keep.items;
    } else all_generic;
    lib.root_module.addCSourceFiles(.{
        .files = generic,
        .root = upstream.path(b, "src"),
        .flags = flags,
    });

    if (default_target_config) {
        const build_config_h = b.addConfigHeader(.{
            .style = .{ .cmake = upstream.path(b, "include/build_config/SDL_build_config.h.cmake") },
            .include_path = "SDL_build_config.h",
        }, .{
            // Generic audio drivers
            .SDL_AUDIO_DRIVER_DUMMY = true,
            .SDL_AUDIO_DRIVER_DISK = true,

            // Generic video drivers
            .SDL_VIDEO_DRIVER_DUMMY = true,
            .SDL_VIDEO_DRIVER_OFFSCREEN = true,

            // Set the assert level, this logic mirrors the default SDL options with release
            // safe added.
            // https://wiki.libsdl.org/SDL3/SDL_ASSERT_LEVEL
            .SDL_DEFAULT_ASSERT_LEVEL_CONFIGURED = true,
            .SDL_DEFAULT_ASSERT_LEVEL = switch (optimize) {
                .Debug, .ReleaseSafe => @as(i64, 2),
                .ReleaseSmall, .ReleaseFast => @as(i64, 1),
            },
        });
        lib.root_module.addConfigHeader(build_config_h);

        // Configure the build for the target platform
        switch (target.result.os.tag) {
            .linux => if (target.result.abi.isAndroid())
                android.build(b, target.result, lib, build_config_h, system_paths)
            else
                linux.build(b, upstream, target.result, lib, build_config_h),
            .windows => windows.build(b, upstream, target.result, lib, build_config_h),
            .macos => macos.build(b, upstream, target.result, lib, build_config_h, system_paths),
            .ios => ios.build(b, upstream, target.result, lib, build_config_h, system_paths),
            else => @panic("target has no default config"),
        }
    }

    // Add the Wayland scanner step
    linux.addWaylandScannerStep(b);

    // Translate the SDL headers and export them as a Zig module
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.defineCMacro("USING_GENERATED_CONFIG_H", "1");
    translate_c.addIncludePath(upstream.path(b, "include"));
    translate_c.addIncludePath(upstream.path(b, "src/video/khronos"));
    const module = translate_c.addModule("sdl3");
    module.linkLibrary(lib);

    // Add the example
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("sdl3", module);

    const build_example_step = b.step("example", "Build the example app");
    build_example_step.dependOn(&example.step);

    const run_example = b.addRunArtifact(example);
    const run_step = b.step("run-example", "Run the example app");
    run_step.dependOn(&run_example.step);
}
