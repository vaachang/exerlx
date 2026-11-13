const std = @import("std");

const id_render = @import("../id_render.zig");

const preamble =
    \\// This file is generated from the Khronos Vulkan XML API registry by vulkan-zig.
    \\
    \\ const std = @import("std");
;

const Renderer = struct {
    const Self = @This();
    const RenderTypeInfoError = std.Io.Writer.Error || std.fmt.ParseIntError || error{ OutOfMemory, InvalidRegistry };

    const BitflagName = struct {
        base_name: []const u8,
        revision: ?[]const u8,
        tag: ?[]const u8,
    };

    const ParamType = enum {
        in_pointer,
        out_pointer,
        in_out_pointer,
        bit_flags,
        mut_buffer_len,
        buffer_len,
        dispatch_handle,
        slice,
        other,
    };
};
