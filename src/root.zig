//! By convention, root.zig is the root source file when making a package.
//! 按照惯例，在创建包时，root.zig 是根源文件。
const std = @import("std");
const Io = std.Io;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
/// 这是一条文档注释，用于解释下面的 `printAnotherMessage` 函数。
/// 接受一个 `Io.Writer` 实例是编写可复用代码的一种便捷方式。
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    // try 的作用就是：如果 print 调用成功，就继续执行；如果失败，则立刻终止当前函数，并将这个错误原样返回给调用者。
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
