const std = @import("std");

// 尽管这个函数看起来像命令式代码，但它并不直接执行构建，
// 而是修改构建图b，随后由外部运行器执行。
// std.Build中的函数实现了一种DSL，用于定义构建步骤并表达它们之间的依赖关系，
// 使构建运行器能够自动并行化构建（并让缓存系统知道某个步骤何时不需要重新运行）。
pub fn build(b: *std.Build) void {
    // 标准目标选项允许运行 `zig build` 的人选择要构建的目标。
    // 这里我们不覆盖默认值，这意味着允许任何目标，默认是原生目标。
    // 还可以使用其他选项来限制支持的目标集合。
    const target = b.standardTargetOptions(.{});
    // 标准优化选项允许运行 `zig build` 的人在 debug、safe、fast 和 small 之间选择。
    // 这里我们不设置首选的发布模式，让用户决定如何优化。
    const optimize = b.standardOptimizeOption(.{});
    // 还可以使用 `b.option()` 定义更多自定义标志，以切换此构建脚本的可选功能。
    // 所有已定义的标志（包括 target 和 optimize 选项）都会在此目录中运行
    // `zig build --help` 时列出。

    // 这会创建一个模块，它表示一组源文件以及一些编译选项，
    // 例如优化模式和链接的系统库。
    // Zig 模块是向使用者提供 Zig 代码的首选方式。
    // addModule 定义了一个我们打算提供给使用者导入的模块。
    // 我们必须给它命名，因为一个 Zig 包可以暴露多个模块，
    // 使用者需要能够指定他们想访问哪个模块。
    const mod = b.addModule("exerlx", .{
        // 根源文件是这个模块的“入口点”。此模块的使用者只能访问此文件中包含的
        // 公开声明，这意味着如果你有打算暴露给使用者、但定义在此模块其他文件中的声明，
        // 你必须确保从根文件中重新导出它们。
        .root_source_file = b.path("src/root.zig"),
        // 稍后我们会将此模块用作测试可执行文件的根模块，
        // 这要求我们指定目标。
        .target = target,
    });

    // 这里我们定义一个可执行文件。可执行文件需要一个根模块，
    // 该模块需要暴露 `main` 函数。虽然我们可以向上面定义的模块添加 main 函数，
    // 但有时最好将业务逻辑和 CLI 拆分为两个独立的模块。
    //
    // 如果你的目标是创建一个供他人使用的 Zig 库，
    // 请考虑它是否也能从同时暴露一个 CLI 工具中受益。
    // 例如，一个用于数据序列化格式的解析器库也可以附带一个 CLI 语法检查器。
    //
    // 如果你的目标是创建一个可执行文件，
    // 请考虑用户是否也可能有兴趣将程序的核心功能嵌入他们自己的可执行文件中，
    // 以避免通过子进程调用你的 CLI 工具所带来的开销。
    //
    // 如果这两种情况都不适用于你，可以随意删除你不需要的声明，
    // 并把所有内容放在单个模块下。
    const exe = b.addExecutable(.{
        .name = "exerlx",
        .root_module = b.createModule(.{
            // `b.createModule` 定义一个新模块，就像 `b.addModule` 一样，
            // 但与 `b.addModule` 不同的是，它不会将此模块暴露给此包的使用者，
            // 这就是为什么在这种情况下我们不必给它命名。
            .root_source_file = b.path("src/main.zig"),
            // 在定义可执行文件或库（在根模块中）时，必须显式接入目标和优化级别；
            // 如果需要，你也可以为可执行文件或库的定义硬编码特定目标
            //（例如嵌入式设备的固件）。
            .target = target,
            .optimize = optimize,
            // 根模块所包含的源文件中可供导入的模块列表。
            .imports = &.{
                // 这里的 "exerlx" 是你在源代码中用来导入此模块的名称
                //（例如 `@import("exerlx")`）。名称重复出现是因为你可以重命名导入，
                // 这在发生冲突时非常有用（从不同包导入模块时可能发生冲突）。
                .{ .name = "exerlx", .module = mod },
            },
        }),
    });

    // 这声明了在运行 `zig build` 时（即执行默认步骤时），
    // 意图将可执行文件安装到安装前缀中。
    // 默认安装前缀是 `zig-out/`，但可以通过传递 `--prefix` 或 `-p` 来覆盖。
    b.installArtifact(exe);

    // 这会创建一个顶层步骤。顶层步骤有一个名称，
    // 可以在运行 `zig build` 时按名称调用（例如 `zig build run`）。
    // 这将执行 `run` 步骤而不是默认步骤。
    // 顶层步骤要真正做某事，必须依赖其他步骤
    //（例如 Run 步骤，我们马上就会看到）。
    const run_step = b.step("run", "Run the app");

    // 这会在构建图中创建一个 RunArtifact 步骤。
    // RunArtifact 步骤会调用由 Zig 编译的可执行文件。
    // 只有用户直接调用（对于顶层步骤而言）或其他步骤依赖它时，运行器才会执行步骤，
    // 因此何时以及如何执行此 Run 步骤由你定义。
    // 在我们的例子中，我们希望当用户运行 `zig build run` 时执行它，
    // 因此我们创建一个依赖链接。
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // 通过让 run 步骤依赖默认步骤，
    // 它将从安装目录运行，而不是直接从缓存目录中运行。
    run_cmd.step.dependOn(b.getInstallStep());

    // 这允许用户在构建命令本身中向应用程序传递参数，
    // 像这样：`zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // 创建一个可执行文件，它将运行所提供模块中的 `test` 块。
    // 这里 `mod` 需要定义目标，这就是为什么前面我们确保设置了相关字段。
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // 一个将运行测试可执行文件的 run 步骤。
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // 创建一个可执行文件，它将运行可执行文件根模块中的 `test` 块。
    // 请注意，测试可执行文件一次只测试一个模块，
    // 因此我们必须创建两个独立的测试可执行文件。
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // 一个将运行第二个测试可执行文件的 run 步骤。
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // 一个用于运行所有测试的顶层步骤。
    // `dependOn` 可以被多次调用，并且由于两个 run 步骤彼此不依赖，
    // 这将使它们并行运行。
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // 就像标志一样，顶层步骤也会列在 `--help` 菜单中。
    //
    // Zig 构建系统完全在用户态实现，这意味着它无法钩入编译器私有 API。
    // 由构建系统编排的所有编译工作都会导致调用其他 Zig 编译器子命令，
    // 并带上定义好的正确标志。当某个调用失败时（或者你传递一个提高详细程度的标志时），
    // 你可以观察这些调用，以验证假设并诊断问题。
    //
    // 最后，Zig 构建系统相对简单且自包含，
    // 阅读其源代码将使你掌握它。
}
