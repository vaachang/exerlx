const std = @import("std");
const Io = std.Io;

const exerlx = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    std.debug.print("All you {s} are belong to us.", .{"codebase"});

    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writter: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer: Io.Writer = &stdout_file_writter.interface;

    try exerlx.printAnotherMessage(stdout_writer);
    try stdout_writer.flush();
}
