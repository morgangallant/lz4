const std = @import("std");
const lz4 = @import("lz4");

pub fn main() !void {
    std.debug.print("hello {s}\n", .{lz4.name()});
}
