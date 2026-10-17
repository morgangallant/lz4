const std = @import("std");

pub fn name() []const u8 {
    return "lz4";
}

test "hello world" {
    try std.testing.expectEqual(2, 1 + 1);
}
