const std = @import("std");
const Io = std.Io;

const exerlx = @import("exerlx");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    // 输出到标准错误（stderr），不进行缓冲，并忽略潜在的错误。
    // .{"codebase"} 是一个匿名结构体/元组，里面只有一个字符串 "codebase"，用来填充前面的 {s}。
    // 所以最终 {s} 被替换成 codebase。
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    // 这适用于任何生命周期与进程相同的对象。
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    // 访问命令行参数
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    // 为了执行 I/O 操作，需要一个 Io 实例。
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    // 标准输出用于应用程序的实际输出，例如，如果你
    // 正在实现 gzip，那么只有压缩后的字节应该发送到
    // 标准输出，而不是任何调试消息。
    // undefined不进行初始化
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try exerlx.printAnotherMessage(stdout_writer);

    try stdout_writer.flush(); // Don't forget to flush!
    // 别忘了刷新！（flush）
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    // 试着把这行注释掉，看看 Zig 是否能检测到内存泄漏！
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try running `zig build test --fuzz` and see if it manages to fail this test case!
    // 试着运行 `zig build test --fuzz`，看看它能不能让这个测试用例失败！

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
