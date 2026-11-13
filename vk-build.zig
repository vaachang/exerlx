const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const maybe_registry = b.option(std.Build.LazyPath, "registry", "Set the path to the Vulkan registry (vk.xml)");
    const maybe_video = b.option(std.Build.LazyPath, "video", "Set the path to the Vulkan Video registry (video.xml)");
    const test_step = b.step("test", "Run all the tests");

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const generator_exe = b.addExecutable(.{
        .name = "vulkan-zig-generator",
        .root_module = root_module,
    });
    b.installArtifact(generator_exe);

    if (maybe_registry) |registry| {
        const vk_generate_cmd = b.addRunArtifact(generator_exe);

        if (maybe_registry) |video| {
            vk_generate_cmd.addArg("--video");
            vk_generate_cmd.addFileArg(video);
        }

        vk_generate_cmd.addFileArg(registry);

        const vk_zig = vk_generate_cmd.addOutputFileArg("vk.zig");
        const vk_zig_module = b.addModule("vulkan-zig", .{
            .root_source_file = vk_zig,
        });
    }
}
