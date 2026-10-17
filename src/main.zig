const std = @import("std");
const Io = std.Io;
const lz4 = @import("lz4");
const assert = std.debug.assert;

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
        try infoCmd(io, args);
    } else if (std.mem.eql(u8, command, "decompress")) {
        args = args[1..]; // Skip the command name
        try decompressCmd(gpa, io, args);
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
    std.debug.print("  decompress  Decompress an LZ4 compressed file\n", .{});
}

fn infoCmd(io: std.Io, args: []const []const u8) !void {
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

    // TODO walk the frames, printing more information about each
}

fn decompressCmd(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: lz4 decompress <file> <output>\n", .{});
        return;
    }

    const input_file_path = args[0];
    const output_file_path = args[1];

    if (std.mem.eql(u8, input_file_path, output_file_path)) {
        return error.InputOutputFileSame;
    }

    const input_file = try std.Io.Dir.cwd().openFile(
        io,
        input_file_path,
        .{ .mode = .read_only },
    );
    defer input_file.close(io);

    const input_file_stat = try input_file.stat(io);

    var buffer: [4096]u8 = undefined;
    var input_reader = input_file.reader(io, &buffer);
    const input_rdr = &input_reader.interface;

    // TODO can we write directly to the output file instead of buffering in memory?
    // How can we read previous bytes from the output file for matches?
    var output_buffer: std.ArrayList(u8) = .empty;
    defer output_buffer.deinit(gpa);

    const start: Io.Timestamp = .now(io, .awake);

    const frame_header = try lz4.readFrameHeader(input_rdr);
    const written_bytes = try lz4.readDataBlocks(
        gpa,
        input_rdr,
        frame_header,
        &output_buffer,
    );
    assert(written_bytes == output_buffer.items.len);

    try std.Io.Dir.cwd().writeFile(
        io,
        .{ .sub_path = output_file_path, .data = output_buffer.items },
    );

    const elapsed = start.untilNow(io, .awake);

    std.debug.print("Decompressed {d} bytes ({d} bytes compressed) from {s}, wrote to {s}\n", .{
        written_bytes,
        input_file_stat.size,
        input_file_path,
        output_file_path,
    });

    const elapsed_ms = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_ms;
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
    const throughput_mib_per_s = @as(f64, @floatFromInt(written_bytes)) /
        (1024.0 * 1024.0) / elapsed_seconds;
    std.debug.print("Took {d:.2}ms ({d:.2} MiB/s)\n", .{ elapsed_ms, throughput_mib_per_s });
}
