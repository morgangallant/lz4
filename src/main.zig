const std = @import("std");
const lz4 = @import("lz4");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.toSlice(init.arena.allocator());
    args = args[1..]; // Skip the program name

    if (args.len == 0) {
        printUsage();
        return;
    }

    const command = args[0];
    if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else if (std.mem.eql(u8, command, "info")) {
        args = args[1..]; // Skip the command name
        try infoCmd(gpa, io, args);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print("Usage: lz4 <command> [options]\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  help        Show this help message\n", .{});
    std.debug.print("  info        Show information about an LZ4 compressed file\n", .{});
}

fn infoCmd(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: lz4 info <file>\n", .{});
        return;
    }

    const file_path = args[0];
    const f = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer f.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = f.reader(io, &buffer);
    const rdr = &reader.interface;

    const frame_header = try lz4.readFrameHeader(rdr);
    std.debug.print("LZ4 Frame Header:\n", .{});
    std.debug.print("  Version: {d}\n", .{frame_header.flg.version});
    std.debug.print("  Block Independence: {d}\n", .{frame_header.flg.block_independence});
    std.debug.print("  Block Checksum: {d}\n", .{frame_header.flg.block_checksum});
    std.debug.print("  Content Size: {d}\n", .{frame_header.flg.content_size});
    std.debug.print("  Content Checksum: {d}\n", .{frame_header.flg.content_checksum});
    std.debug.print("  Dictionary ID: {d}\n", .{frame_header.flg.dict_id});
    std.debug.print(
        "  Block max size: {d} ({d})\n",
        .{ frame_header.bd.block_max_size, try frame_header.bd.blockMaxSize() },
    );

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const written = try lz4.readDataBlocks(gpa, rdr, frame_header, &out);
    std.debug.print("Decompressed size: {d}\n", .{written});

    std.debug.print("Decompressed data: {s}\n", .{out.items});
}
