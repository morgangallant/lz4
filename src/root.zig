const std = @import("std");
const Io = std.Io;
const XxHash32 = std.hash.XxHash32;

// Stored as a little-endian header for an LZ4 frame.
const MAGIC_NUMBER: u32 = 0x184D2204;

// Note: All reserved bits must be set to 0.

// The FLG (Frame Flags) byte.
const FLG = packed struct(u8) {
    dict_id: u1, // dictionary ID included after flags?
    reserved: u1,
    content_checksum: u1, // 32-bit content checksum after end mark?
    content_size: u1, // Uncompressed size included after flags?
    block_checksum: u1, // Each data block followed by a 4-byte checksum?
    block_independence: u1, // 1 = independent blocks. 0 = dependent blocks.
    version: u2, // Must be set to 01.
};

// The BD (Block Descriptor) byte.
const BD = packed struct(u8) {
    reserved: u4,
    // 4 = 64 KB, 5 = 256 KB, 6 = 1 MB, 7 = 4 MB
    // Used to help decoder allocate memory for decompression.
    block_max_size: u3,
    reserved2: u1,

    pub fn blockMaxSize(self: BD) !usize {
        return switch (self.block_max_size) {
            4 => 64 * 1024,
            5 => 256 * 1024,
            6 => 1 * 1024 * 1024,
            7 => 4 * 1024 * 1024,
            else => return error.UnsupportedBlockMaxSize,
        };
    }

    fn newForBlockSize(block_size: usize) !BD {
        const block_max_size: u3 = if (block_size <= 64 * 1024)
            4
        else if (block_size <= 256 * 1024)
            5
        else if (block_size <= 1 * 1024 * 1024)
            6
        else if (block_size <= 4 * 1024 * 1024)
            7
        else
            return error.UnsupportedBlockMaxSize;
        return .{
            .reserved = 0,
            .block_max_size = block_max_size,
            .reserved2 = 0,
        };
    }
};

const Token = packed struct(u8) {
    // The number of bytes to copy from the previous match. If the value is 15,
    // Like `literal_length`, subsequent bytes are read to determine the actual length.
    // Each subsequent byte adds 255 to the length until a byte less than 255 is found.
    match_length: u4,

    // Total number of literal bytes.
    // If the value is 15, then subsequent bytes are read to determine the actual length.
    // Each subsequent byte adds 255 to the length until a byte less than 255 is found.
    literal_length: u4,
};

// Allows customization of how data is compressed.
const CompressionOptions = struct {
    write_content_checksum: bool = true,
    write_content_size: bool = false,
    write_block_checksum: bool = false,
};

// Compresses the input data using the LZ4 algorithm, writing the output
// to the provided `ArrayList`. Returns the number of bytes written to the output.
pub fn compress(
    allocator: std.mem.Allocator,
    input: []const u8, // TODO input reader?
    output: *std.ArrayList(u8),
    options: CompressionOptions,
) !usize {
    var allocating_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, output);
    defer output.* = allocating_writer.toArrayList();
    const w = &allocating_writer.writer;

    // Keep track of the starting point to be able to return the number of written bytes
    const start = allocating_writer.writer.end;

    // Write the magic number to the output.
    try w.writeInt(u32, MAGIC_NUMBER, .little);

    // FLG byte.
    const flg: FLG = .{
        .dict_id = 0,
        .reserved = 0,
        .content_checksum = if (options.write_content_checksum) 1 else 0,
        .content_size = if (options.write_content_size) 1 else 0,
        .block_checksum = if (options.write_block_checksum) 1 else 0,
        .block_independence = 1,
        .version = 1,
    };
    const flg_byte: u8 = @backingInt(flg);
    try w.writeInt(u8, flg_byte, .little);

    // BD byte.
    // TODO how do we handle inputs > 4MB?
    const bd = try BD.newForBlockSize(input.len);
    const bd_byte: u8 = @backingInt(bd);
    try w.writeInt(u8, bd_byte, .little);

    // If content size is included, write it to the output.
    if (options.write_content_size) {
        const content_size: u64 = @intCast(input.len);
        try w.writeInt(u64, content_size, .little);
    }

    // TODO: Write the dictionary ID if included.

    // Checksum the header (FLG, BD, and optional fields) using XXHash32,
    // then write the bottom byte of the checksum to the output.
    const header_checksum = hash: {
        const written = allocating_writer.written();
        const header_bytes = written[start + 4 ..]; // Doesn't include the magic number
        const computed_hash = XxHash32.hash(0, header_bytes);
        const top_byte: u8 = @truncate(computed_hash >> 8);
        break :hash top_byte;
    };
    try w.writeInt(u8, header_checksum, .little);

    return allocating_writer.writer.end - start;
}

// The frame header consists of the FLG and BD bytes, followed by optional
// content size and dictionary ID fields. It is checksummed w/ XXHash32.
const FrameHeader = struct {
    flg: FLG,
    bd: BD,
    content_size: ?u64,
    dictionary_id: ?u32,

    pub fn sizeToPreallocate(self: FrameHeader) !usize {
        if (self.flg.content_size == 1) {
            return self.content_size.?;
        }
        return self.bd.blockMaxSize();
    }
};

// Small helper function to read a value of type `T` from the reader, updating the hash.
fn takeAndHash(comptime T: type, rdr: *Io.Reader, hasher: *XxHash32) !T {
    const arr = try rdr.takeArray(@sizeOf(T));
    hasher.update(arr);
    return std.mem.readInt(T, arr, .little);
}

// Parse a frame header from the reader, ensuring the magic
// number and checksum match the expected values. Returns the
// parsed frame header on success.
pub fn readFrameHeader(rdr: *Io.Reader) !FrameHeader {
    var hasher = XxHash32.init(0);

    // Magic number is not part of the hash.
    const magic_number = try rdr.takeInt(u32, .little);
    if (magic_number != MAGIC_NUMBER) {
        return error.InvalidMagicNumber;
    }

    const fg_byte = try takeAndHash(u8, rdr, &hasher);
    const flg: FLG = @fromBackingInt(fg_byte);
    if (flg.version != 1) {
        return error.UnsupportedVersion;
    } else if (flg.reserved != 0) {
        return error.UnsupportedReservedBits;
    }

    const bd_byte = try takeAndHash(u8, rdr, &hasher);
    const bd: BD = @fromBackingInt(bd_byte);
    if (bd.reserved != 0 or bd.reserved2 != 0) {
        return error.UnsupportedReservedBits;
    }

    var content_size: ?u64 = null;
    if (flg.content_size == 1) {
        content_size = try takeAndHash(u64, rdr, &hasher);
    }

    var dictionary_id: ?u32 = null;
    if (flg.dict_id == 1) {
        dictionary_id = try takeAndHash(u32, rdr, &hasher);
    }

    const expected_checksum = try rdr.takeInt(u8, .little);
    const computed_checksum = (hasher.final() >> 8) & 0xFF;
    if (expected_checksum != computed_checksum) {
        return error.InvalidHeaderChecksum;
    }

    return .{
        .flg = flg,
        .bd = bd,
        .content_size = content_size,
        .dictionary_id = dictionary_id,
    };
}

// The block size is stored as a 31-bit integer, with the highest bit indicating
// whether the block is compressed with LZ4 or not.
const DataBlockSize = packed struct(u32) {
    size: u31,
    is_uncompressed: u1,
};

// Read a sequence of data blocks from the reader, decompressing if necessary.
// Returns the total number of bytes written to the output (`out`).
pub fn readDataBlocks(
    allocator: std.mem.Allocator,
    rdr: *Io.Reader,
    header: FrameHeader,
    out: *std.ArrayList(u8),
) !usize {
    var written: usize = 0;
    while (true) {
        const block_size_int = try rdr.takeInt(u32, .little);
        if (block_size_int == 0) {
            break; // End mark.
        }
        const data_block_size: DataBlockSize = @fromBackingInt(block_size_int);
        if (data_block_size.size > try header.bd.blockMaxSize()) {
            return error.BlockSizeExceedsMax;
        }

        // This is relatively important - we pass a limited reader to the decompress
        // function, to ensure it can detect the end of the block (error.EndOfStream).
        var buffer: [4096]u8 = undefined;
        var block_reader = rdr.limited(.limited(data_block_size.size), &buffer);
        written += blk: switch (data_block_size.is_uncompressed) {
            0 => {
                break :blk try decompressLZ4Blocks(allocator, &block_reader.interface, out);
            },
            1 => {
                @panic("todo: support uncompressed blocks");
            },
        };

        // If the block checksum flag is set, read and verify the checksum.
        if (header.flg.block_checksum == 1) {
            _ = try rdr.takeInt(u32, .little);
            @panic("todo: implement block checksum verification");
        }
    }
    return written;
}

fn decompressLZ4Blocks(
    allocator: std.mem.Allocator,
    rdr: *Io.Reader,
    out: *std.ArrayList(u8),
) !usize {
    var written: usize = 0;
    while (true) {
        // Always starts with a token byte.
        const token_byte = try rdr.takeInt(u8, .little);
        const token: Token = @fromBackingInt(token_byte);

        // Compute the literal length from the token.
        // If the literal length is 15, then we need to read
        // subsequent bytes to determine the total length.
        var literal_length: usize = token.literal_length;
        if (literal_length == 15) {
            while (true) {
                const byte = try rdr.takeInt(u8, .little);
                literal_length += byte;
                if (byte != 255) break;
            }
        }

        // Write the literal bytes to the output.
        if (literal_length > 0) {
            const dst = try out.addManyAsSlice(allocator, literal_length);
            try rdr.readSliceAll(dst);
            written += literal_length;
        }

        // An LZ4 block will end with a missing match offset, e.g.
        // the end of the block is reached when we cannot read a match offset.
        const match_offset = rdr.takeInt(u16, .little) catch |err| switch (err) {
            error.EndOfStream => break, // No offset indicates the end of the block.
            else => return err,
        };
        if (match_offset == 0) {
            return error.InvalidMatchOffset;
        }

        // The match length is 4 + the value in the token.
        // If the token value is 15, then we'll read subsequent
        // bytes to determine the total match length.
        var match_length: usize = token.match_length;
        if (match_length == 15) {
            while (true) {
                const byte = try rdr.takeInt(u8, .little);
                match_length += byte;
                if (byte != 255) break;
            }
        }
        match_length += 4; // The match length is always at least 4.

        // Copy the match bytes from the output buffer.
        const match_start = out.items.len - match_offset;
        const match_end = match_start + match_length;
        if (match_start >= out.items.len) {
            return error.InvalidMatchOffset;
        } else if (match_end > out.items.len) {
            return error.InvalidMatchLength;
        }
        const match_bytes = out.items[match_start..match_end];
        const dst = try out.addManyAsSlice(allocator, match_length);
        @memcpy(dst, match_bytes);

        written += match_length;
    }

    return written;
}

// `LICENSE.lz4` was compressed with the reference `lz4` CLI tool.
// This test ensures we can decompress it correctly.
test "decompress lz4-cli output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const compressed_file_path = "LICENSE.lz4";
    const f = try std.Io.Dir.cwd().openFile(
        io,
        compressed_file_path,
        .{ .mode = .read_only },
    );
    defer f.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = f.reader(io, &buffer);
    const rdr = &reader.interface;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    const header = try readFrameHeader(rdr);
    const written = try readDataBlocks(allocator, rdr, header, &output);
    try std.testing.expectEqual(output.items.len, written);

    const expected = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "LICENSE",
        allocator,
        .unlimited,
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, output.items);
}

test "compress & decompress roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const input_file_path = "LICENSE";
    const input_file = try std.Io.Dir.cwd().readFileAlloc(
        io,
        input_file_path,
        allocator,
        .unlimited,
    );
    defer allocator.free(input_file);

    const input_size = input_file.len;

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);

    const written = try compress(allocator, input_file, &compressed, .{});
    try std.testing.expectEqual(compressed.items.len, written);

    // We expect the compressed output to be smaller than the input.
    try std.testing.expect(compressed.items.len < input_size);

    var decompressed: std.ArrayList(u8) = .empty;
    defer decompressed.deinit(allocator);

    var compressed_reader: std.Io.Reader = .fixed(compressed.items);
    const header = try readFrameHeader(&compressed_reader);
    const decompressed_written = try readDataBlocks(
        allocator,
        &compressed_reader,
        header,
        &decompressed,
    );
    try std.testing.expectEqual(decompressed.items.len, decompressed_written);

    // The decompressed output should match the original input.
    try std.testing.expectEqualStrings(input_file, decompressed.items);
}
