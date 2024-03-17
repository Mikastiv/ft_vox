const std = @import("std");
const vkgen = @import("vulkan_zig");

const shader_base_path = "shaders/";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml_path: []const u8 = b.pathFromRoot("vk.xml");

    const vkzig = b.dependency("vulkan_zig", .{
        .registry = xml_path,
    });

    const vk_kickstart = b.dependency("vk_kickstart", .{
        .registry = xml_path,
        .enable_validation = if (optimize == .Debug) true else false,
    });

    const glfw = b.dependency("glfw", .{
        .target = target,
        .optimize = .ReleaseFast,
    }).artifact("glfw");

    const vulkan_lib = if (target.result.os.tag == .windows) "vulkan-1" else "vulkan";
    const vulkan_sdk = getVulkanSdkPath(b);

    const shaders = vkgen.ShaderCompileStep.create(b, &.{ "glslc", "--target-env=vulkan1.1" }, "-o");
    addShader(shaders, "triangle_vert", "triangle.vert");
    addShader(shaders, "triangle_frag", "triangle.frag");
    addShader(shaders, "skybox_vert", "skybox.vert");
    addShader(shaders, "skybox_frag", "skybox.frag");

    const wf = b.addWriteFiles();
    const stb_image = wf.add("stb_image.c",
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#include "stb_image.h"
    );

    const cimgui = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = .ReleaseFast,
    });
    cimgui.linkLibCpp();
    cimgui.linkLibrary(glfw);
    cimgui.addIncludePath(.{ .path = "lib/imgui" });
    cimgui.addCSourceFiles(.{
        .files = &.{
            "lib/cimgui/cimgui.cpp",
            "lib/cimgui/cimgui_impl_glfw.cpp",
            "lib/cimgui/cimgui_impl_vulkan.cpp",
            "lib/imgui/imgui.cpp",
            "lib/imgui/imgui_demo.cpp",
            "lib/imgui/imgui_draw.cpp",
            "lib/imgui/imgui_impl_glfw.cpp",
            "lib/imgui/imgui_impl_vulkan.cpp",
            "lib/imgui/imgui_tables.cpp",
            "lib/imgui/imgui_widgets.cpp",
        },
    });

    const exe = b.addExecutable(.{
        .name = "ft_vox",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibCpp();
    exe.linkLibrary(glfw);
    exe.linkLibrary(cimgui);
    exe.addIncludePath(.{ .path = b.pathJoin(&.{ vulkan_sdk, "include" }) });
    exe.addLibraryPath(.{ .path = b.pathJoin(&.{ vulkan_sdk, "lib" }) });
    exe.linkSystemLibrary(vulkan_lib);
    exe.addIncludePath(.{ .path = "lib/cimgui" });
    exe.addIncludePath(.{ .path = "lib/imgui" });
    exe.addIncludePath(.{ .path = "lib/stb_image" });
    exe.addCSourceFile(.{ .file = stb_image });
    exe.root_module.addImport("vk-kickstart", vk_kickstart.module("vk-kickstart"));
    exe.root_module.addImport("vulkan-zig", vkzig.module("vulkan-zig"));
    exe.root_module.addImport("shaders", shaders.getModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn addShader(shaders: *vkgen.ShaderCompileStep, comptime name: []const u8, comptime path: []const u8) void {
    shaders.add(name, shader_base_path ++ path, .{});
}

fn getVulkanSdkPath(b: *const std.Build) []const u8 {
    const vk_sdk_path = b.graph.env_map.get("VK_SDK_PATH");
    const vulkan_sdk_path = b.graph.env_map.get("VULKAN_SDK");

    return if (vk_sdk_path) |path|
        path
    else if (vulkan_sdk_path) |path|
        path
    else
        @panic("VK_SDK_PATH or VULKAN_SDK is not set");
}
