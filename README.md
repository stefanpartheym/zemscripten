# zemscripten

> [!NOTE]
> This is a modified version of [zig-gamedev/zemscripten](https://github.com/zig-gamedev/zemscripten).
> It adds some minor conveniences like activating a user defined emsdk version via `activateEmsdkStep`.

Zig build package and shims for [Emscripten](https://emscripten.org) emsdk

## How to use it

> [!NOTE]
> For an in-depth example on how to use this library, see [stefanpartheym/zig-invaders](https://github.com/stefanpartheym/zig-invaders/blob/main/build.zig).

Add `zemscripten` and (optionally) `emsdk` to your build.zig.zon dependencies:

```sh
zig fetch --save git+https://github.com/stefanpartheym/zemscripten.git
zig fetch --save=emsdk git+https://github.com/emscripten-core/emsdk#3.1.70
```

Emsdk must be activated before it can be used. You can use `activateEmsdkStep` to create a build step for that:

```zig
const activate_emsdk_step = @import("zemscripten", "3.1.70").activateEmsdkStep(b);
```

Add zemscripten's "root" module to your wasm compile target, then create an `emcc` build step. We use zemscripten's default flags and settings which can be overridden for your project specific requirements. Refer to the [emcc documentation](https://emscripten.org/docs/tools_reference/emcc.html). Example build.zig code:

```zig
    const wasm = b.addStaticLibrary(.{
        .name = "MyGame",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zemscripten = b.dependency("zemscripten", .{});
    wasm.root_module.addImport("zemscripten", zemscripten.module("root"));

    const emcc_flags = @import("zemscripten").emccDefaultFlags(b.allocator, optimize);

    var emcc_settings = @import("zemscripten").emccDefaultSettings(b.allocator, .{
        .optimize = optimize,
    });

    try emcc_settings.put("ALLOW_MEMORY_GROWTH", "1");

    const emcc_step = @import("zemscripten").emccStep(
        b,
        wasm,
        .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .use_preload_plugins = true,
            .embed_paths = &.{},
            .preload_paths = &.{},
            .install_dir = .{ .custom = "web" },
        },
    );
    emcc_step.dependOn(activate_emsdk_step);

    b.getInstallStep().dependOn(emcc_step);
```

Now you can use the provided Zig panic and log overrides in your wasm's root module and define the entry point that invoked by the js output of `emcc` (by default it looks for a symbol named `main`). For example:

```zig
const std = @import("std");

const zemscripten = @import("zemscripten");
pub const panic = zemscripten.panic;

pub const std_options = std.Options{
    .logFn = zemscripten.log,
};

export fn main() c_int {
    std.log.info("hello, world.", .{});
    return 0;
}
```

You can also define a run step that invokes `emrun`. This will serve the html locally over HTTP and try to open it using your default browser. Example build.zig code:

```zig
    const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name});

    const emrun_args = .{};
    const emrun_step = @import("zemscripten").emrunStep(
        b,
        b.getInstallPath(.{ .custom = "web" }, html_filename),
        &emrun_args,
    );

    emrun_step.dependOn(emcc_step);

    b.step("emrun", "Build and open the web app locally using emrun").dependOn(emrun_step);
```

See the [emrun documentation](https://emscripten.org/docs/compiling/Running-html-files-with-emrun.html) for the difference args that can be used.
