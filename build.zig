const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "scop",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const vkzig_dep = b.dependency("vulkan_zig", .{
        .registry = @as([]const u8, b.pathFromRoot("vk.xml")),
    });
    const vkzig_bindings = vkzig_dep.module("vulkan-zig");
    exe.addModule("vulkan", vkzig_bindings);

    try addShader(b, exe, "shader.vert", "vert.spv");
    try addShader(b, exe, "shader.frag", "frag.spv");

    // exe.addIncludePath(.{ .path = "lib/glfw/include" });
    // exe.addLibraryPath(.{ .path = "lib/glfw/lib-vc2022" });
    // exe.linkLibC();
    // exe.linkSystemLibrary("user32");
    // exe.linkSystemLibrary("gdi32");
    // exe.linkSystemLibrary("shell32");
    // exe.linkSystemLibrary("glfw3dll");
    // exe.addIncludePath(.{ .path = "lib/linux/glfw-3.3.8/include" });
    // exe.addLibraryPath(.{.path = "lib/linux/glfw-3.3.8/build/src"});
    exe.linkSystemLibrary("glfw3");
    // exe.linkSystemLibrary("wayland-client");
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn addShader(b: *std.Build, exe: *std.Build.Step.Compile, in_file: []const u8, out_file: []const u8) !void {
    const dirname = "shaders";
    const full_in = try std.fs.path.join(b.allocator, &[_][]const u8{ dirname, in_file });
    const full_out = try std.fs.path.join(b.allocator, &[_][]const u8{ dirname, out_file });

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
        full_out,
        full_in,
    });
    exe.step.dependOn(&run_cmd.step);
}
