const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("root", .{ .root_source_file = b.path("src/zemscripten.zig") });
}

/// Returns the path to the minimal shell file.
/// Argument `b` is expected to be the `Build` instance of this zemscripten
/// dependency in the calling project.
pub fn minimalShellFilePath(zemscripten_dep: *std.Build.Dependency) []const u8 {
    const b = zemscripten_dep.builder;
    return b.path("src/minimal-shell.html").getPath(b);
}

pub fn emsdkPath(emsdk_dep: *std.Build.Dependency, sub_path: []const u8) []const u8 {
    return std.fs.path.join(emsdk_dep.builder.allocator, &.{
        emsdk_dep.path("upstream/emscripten").getPath(emsdk_dep.builder),
        sub_path,
    }) catch unreachable;
}

pub fn emsdkScriptPath(emsdk_dep: *std.Build.Dependency) []const u8 {
    return emsdk_dep.path(
        switch (builtin.target.os.tag) {
            .windows => "emsdk.bat",
            else => "emsdk",
        },
    ).getPath(emsdk_dep.builder);
}

pub fn emccPath(emsdk_dep: *std.Build.Dependency) []const u8 {
    return emsdkPath(emsdk_dep, switch (builtin.target.os.tag) {
        .windows => "emcc.bat",
        else => "emcc",
    });
}

pub fn emrunPath(emsdk_dep: *std.Build.Dependency) []const u8 {
    return emsdkPath(emsdk_dep, switch (builtin.target.os.tag) {
        .windows => "emrun.bat",
        else => "emrun",
    });
}

pub fn activateEmsdkStep(
    b: *std.Build,
    emsdk_dep: *std.Build.Dependency,
    emsdk_version: []const u8,
) *std.Build.Step {
    const emsdk_script_path = emsdkScriptPath(emsdk_dep);
    var emsdk_install = b.addSystemCommand(&.{ emsdk_script_path, "install", emsdk_version });
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            emsdk_install.step.dependOn(&b.addSystemCommand(&.{ "chmod", "+x", emsdk_script_path }).step);
        },
        else => {},
    }

    var emsdk_activate = b.addSystemCommand(&.{ emsdk_script_path, "activate", emsdk_version });
    emsdk_activate.step.dependOn(&emsdk_install.step);

    const chmod_emcc = b.addSystemCommand(&.{ "chmod", "+x", emccPath(emsdk_dep) });
    chmod_emcc.step.dependOn(&emsdk_activate.step);

    const chmod_emrun = b.addSystemCommand(&.{ "chmod", "+x", emrunPath(emsdk_dep) });
    chmod_emrun.step.dependOn(&emsdk_activate.step);

    const step = b.allocator.create(std.Build.Step) catch unreachable;
    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "Activate EMSDK",
        .owner = b,
        .makeFn = &struct {
            fn make(_: *std.Build.Step, _: std.Progress.Node) anyerror!void {}
        }.make,
    });
    step.dependOn(&chmod_emcc.step);
    step.dependOn(&chmod_emrun.step);
    return step;
}

pub const EmccFlags = std.StringHashMap(void);

pub fn emccDefaultFlags(allocator: std.mem.Allocator, optimize: std.builtin.OptimizeMode) EmccFlags {
    var args = EmccFlags.init(allocator);
    // Add optimization flag based on the optimization option.
    const optimiztion_flag = switch (optimize) {
        .Debug => "-Og",
        .ReleaseFast => "-Ofast",
        .ReleaseSmall => "-Os",
        else => "-O3",
    };
    args.put(optimiztion_flag, {}) catch unreachable;
    if (optimize == .Debug) {
        args.put("-gsource-map", {}) catch unreachable;
    }
    return args;
}

pub const EmccSettings = std.StringHashMap([]const u8);

pub fn emccDefaultSettings(
    allocator: std.mem.Allocator,
    options: struct {
        optimize: std.builtin.OptimizeMode,
        emsdk_allocator: enum {
            none,
            dlmalloc,
            emmalloc,
            @"emmalloc-debug",
            @"emmalloc-memvalidate",
            @"emmalloc-verbose",
            mimalloc,
        } = .emmalloc,
        shell_file: ?[]const u8 = null,
    },
) EmccSettings {
    var settings = EmccSettings.init(allocator);
    switch (options.optimize) {
        .Debug, .ReleaseSafe => {
            settings.put("SAFE_HEAP", "1") catch unreachable;
            settings.put("STACK_OVERFLOW_CHECK", "1") catch unreachable;
            settings.put("ASSERTIONS", "1") catch unreachable;
        },
        else => {},
    }
    settings.put("USE_OFFSET_CONVERTER", "1") catch unreachable;
    settings.put("MALLOC", @tagName(options.emsdk_allocator)) catch unreachable;
    return settings;
}

pub const EmccFilePath = struct {
    src_path: []const u8,
    virtual_path: ?[]const u8 = null,
};

pub fn emccStep(
    b: *std.Build,
    emsdk_dep: *std.Build.Dependency,
    wasm: *std.Build.Step.Compile,
    options: struct {
        optimize: std.builtin.OptimizeMode,
        flags: EmccFlags,
        settings: EmccSettings,
        use_preload_plugins: bool = false,
        embed_paths: ?[]const EmccFilePath = null,
        preload_paths: ?[]const EmccFilePath = null,
        shell_file_path: ?[]const u8 = null,
        install_dir: std.Build.InstallDir,
    },
) *std.Build.Step {
    var emcc = b.addSystemCommand(&.{emccPath(emsdk_dep)});

    var iterFlags = options.flags.iterator();
    while (iterFlags.next()) |kvp| {
        emcc.addArg(kvp.key_ptr.*);
    }

    var iterSettings = options.settings.iterator();
    while (iterSettings.next()) |kvp| {
        emcc.addArg(std.fmt.allocPrint(
            b.allocator,
            "-s{s}={s}",
            .{ kvp.key_ptr.*, kvp.value_ptr.* },
        ) catch unreachable);
    }

    emcc.addArtifactArg(wasm);
    {
        var it = wasm.root_module.iterateDependencies(wasm, false);
        while (it.next()) |item| {
            for (item.module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |compile_step| {
                        switch (compile_step.kind) {
                            .lib => {
                                emcc.addArtifactArg(compile_step);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{wasm.name}));

    if (options.use_preload_plugins) {
        emcc.addArg("--use-preload-plugins");
    }

    if (options.embed_paths) |embed_paths| {
        for (embed_paths) |path| {
            const path_arg = if (path.virtual_path) |virtual_path|
                std.fmt.allocPrint(
                    b.allocator,
                    "{s}@{s}",
                    .{ path.src_path, virtual_path },
                ) catch unreachable
            else
                path.src_path;
            emcc.addArgs(&.{ "--embed-file", path_arg });
        }
    }

    if (options.preload_paths) |preload_paths| {
        for (preload_paths) |path| {
            const path_arg = if (path.virtual_path) |virtual_path|
                std.fmt.allocPrint(
                    b.allocator,
                    "{s}@{s}",
                    .{ path.src_path, virtual_path },
                ) catch unreachable
            else
                path.src_path;
            emcc.addArgs(&.{ "--preload-file", path_arg });
        }
    }

    if (options.shell_file_path) |shell_file_path| {
        emcc.addArgs(&.{ "--shell-file", shell_file_path });
    }

    const install_step = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = options.install_dir,
        .install_subdir = "",
    });
    install_step.step.dependOn(&emcc.step);

    return &install_step.step;
}

pub fn emrunStep(
    b: *std.Build,
    emsdk_dep: *std.Build.Dependency,
    html_path: []const u8,
    extra_args: []const []const u8,
) *std.Build.Step {
    var emrun = b.addSystemCommand(&.{emrunPath(emsdk_dep)});
    emrun.addArgs(extra_args);
    emrun.addArg(html_path);
    // emrun.addArg("--");

    return &emrun.step;
}
