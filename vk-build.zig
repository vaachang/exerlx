const std = @import("std");

pub fn build(b: *std.Build) void {
    // 默认目标
    const target = b.standardTargetOptions(.{});
    // 默认优化参数
    const optimize = b.standardOptimizeOption(.{});
    // 声明自定义构建选项，名为registry。 -Dregistry=... 返回?std.Build.LazyPath
    // LazyPath 是“惰性”的——在构建图被最终执行之前，它只是一段描述，真正解析成绝对路径发生在构建时。这使得它可以引用尚未生成的文件。
    const maybe_registry = b.option(std.Build.LazyPath, "registry", "Set the path to the Vulkan registry (vk.xml)");
    const maybe_video = b.option(std.Build.LazyPath, "video", "Set the path to the Vulkan Video registry (video.xml)");
    // 在 Zig 构建系统中创建一个名为 test 的自定义顶层构建步骤（Step）
    const test_step = b.step("test", "Run all the tests");

    // 创建模块
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 使用包管理器，用户可以通过
    // `b.dependency(<build.zig.zon 中的名字>, .{}).artifact("vulkan-zig-generator")`
    // 获取这个构建产物。
    // 这样，用户只需要 `.addArg("path/to/vk.xml")`，然后通过
    // `.addOutputArg("vk.zig")` 获得一个指向所生成代码的文件源（file source）。
    // 在构建图中创建一个“编译可执行文件”的步骤，告诉 Zig 构建系统：
    // “请把 root_module 编译成一个名叫 vulkan-zig-generator 的可执行程序”。
    // b.addModule 和 b.createModule 的核心区别在于模块的可见性：
    // b.addModule 创建的是公共模块，会暴露给依赖本项目的其他包使用；
    // 而 b.createModule 创建的是私有模块，仅在当前项目的构建脚本内部使用。
    // 当别的项目通过 build.zig.zon 依赖你的项目后，就可以通过这个 name 来获取你的模块
    const generator_exe = b.addExecutable(.{
        .name = "vulkan-zig-generator",
        .root_module = root_module,
    });
    // 把 generator_exe 这个构建产物（artifact）加入“安装步骤”，
    // 使得执行 zig build / zig build install 时，
    // Zig 会把编译好的可执行文件复制到安装输出目录（默认是 zig-out/bin/）。
    // zig build等价于zig build install
    // std.Build 里有一个内置的顶层步骤，叫 install
    b.installArtifact(generator_exe);

    // 或者他们可以跳过所有这些步骤，只需确保向 `b.dependency` 传入 `.registry = "path/to/vk.xml"`，
    // 然后通过 `.module("vulkan-zig")` 直接获取该模块。
    if (maybe_registry) |registry| {
        // 在构建图里创建一个"运行 generator_exe 这个可执行文件"的步骤，
        // 并返回一个句柄 vk_generate_cmd，用于给这次运行配置参数、输入文件和输出文件。
        const vk_generate_cmd = b.addRunArtifact(generator_exe);

        if (maybe_video) |video| {
            // 加一个固定字符串参数
            vk_generate_cmd.addArg("--video");
            // 加一个"文件路径"参数
            // 同时，它会让这次运行（Run EXE）依赖这个文件（generator_exe）的生成步骤
            // 既正确解析路径，又建立依赖
            vk_generate_cmd.addFileArg(video);
        }

        // 解析registry参数
        vk_generate_cmd.addFileArg(registry);

        // 声明一个输出文件
        const vk_zig = vk_generate_cmd.addOutputFileArg("vk.zig");
        // 把生成出来的 vk.zig 注册成一个名为 vulkan-zig 的公共模块
        const vk_zig_module = b.addModule("vulkan-zig", .{
            .root_source_file = vk_zig,
        });

        const vk_zig_install_step = b.addInstallFile(vk_zig, "src/vk.zig");
        b.getInstallStep().dependOn(&vk_zig_install_step.step);

        const ref_all_decls_test = b.addObject(.{
            .name = "ref-all-decls-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/ref_all_decls.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        ref_all_decls_test.root_module.addImport("vulkan", vk_zig_module);
        test_step.dependOn(&ref_all_decls_test.step);
    }

    const test_target = b.addTest(.{ .root_module = root_module });
    test_step.dependOn(&b.addRunArtifact(test_target).step);
}
