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
};

const Token = packed struct(u8) {
    // Total number of literal bytes.
    // If the value is 15, then subsequent bytes are read to determine the actual length.
    // Each subsequent byte adds 255 to the length until a byte less than 255 is found.
    literal_length: u4,

    // The number of bytes to copy from the previous match. If the value is 15,
    // Like `literal_length`, subsequent bytes are read to determine the actual length.
    // Each subsequent byte adds 255 to the length until a byte less than 255 is found.
    match_length: u4,
};

// The block size is stored as a 31-bit integer, with the highest bit indicating
// whether the block is compressed with LZ4 or not.
const DataBlockSize = packed struct(u32) {
    size: u31,
    is_uncompressed: u1,
};

// Compresses the input data using the LZ4 algorithm, writing the output
// to the provided `ArrayList`. Returns the number of bytes written to the output.
pub fn compress(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: Io.Writer,
) !usize {
    _ = allocator;
    _ = input;

    var written: usize = 0;

    // Magic number always comes first.
    try output.writeInt(u32, MAGIC_NUMBER, .little);
    written += @sizeOf(u32);

    return written;
}

// 04 22 4d 18 - Magic Number
// 64 - FLG (01000000) (version=01, block_independence=
//
// 64 40 a7 9c
// 03 00 00 f3 a9 4d 49 54

// Decompresses an LZ4 frame from the input data, writing to the provided `ArrayList`.
// Returns the number of bytes written to the output.
fn decompressFrame(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList(u8),
) !usize {
    const written: usize = 0;
    var offset: usize = 0;

    // Magic number always comes first.
    try readMagicNumber(input, &offset);

    // Next, we decode the frame descriptor.
    const flg, const bd = try readFLGAndBG(input, &offset);

    if (flg.version != 1) {
        return error.UnsupportedVersion;
    } else if (flg.reserved != 0 or bd.reserved != 0 or bd.reserved2 != 0) {
        return error.UnsupportedReservedBits;
    }

    // Determine how much space to pre-allocate for the output buffer.
    // If the content size is included, then we can use that to exactly
    // pre-allocate the output buffer. Otherwise, we use the block_max_size
    // as an upper bound for the output buffer size.
    const block_max_size: usize = switch (bd.block_max_size) {
        4 => 64 * 1024,
        5 => 256 * 1024,
        6 => 1 * 1024 * 1024,
        7 => 4 * 1024 * 1024,
        else => return error.UnsupportedBlockSize,
    };
    const preallocate_amount = blk: {
        if (flg.content_size == 1) {
            const content_size = try readInt(u64, input, &offset);
            break :blk content_size;
        }
        break :blk block_max_size;
    };
    try output.ensureUnusedCapacity(allocator, preallocate_amount);

    // If the dictionary ID is included, read it now.
    const dictionary_id: ?u32 = if (flg.dict_id == 1)
        try readInt(u32, input, &offset)
    else
        null;
    if (dictionary_id) |_| {
        @panic("dict id not supported yet");
    }

    // The final byte of the frame descriptor is a checksum.
    // Specifically, just the lower 8 bits of the XXHash32 of the frame descriptor.
    {
        const computed_checksum = (contentHash(input[4..offset]) >> 8) & 0xFF;
        const expected_checksum = try readInt(u8, input, &offset);
        if (expected_checksum != computed_checksum) {
            return error.InvalidHeaderChecksum;
        }
    }

    // Now, we read data blocks.
    while (true) {
        const block_size_int = try readInt(u32, input, &offset);
        if (block_size_int == 0) {
            break; // End mark.
        }
        const data_block_size: DataBlockSize = @fromBackingInt(block_size_int);
        if (data_block_size.size > block_max_size) {
            return error.BlockSizeExceedsMax;
        }
        std.debug.print("data_block_size: size={} is_uncompressed={}\n", .{ data_block_size.size, data_block_size.is_uncompressed });
        const n_written: usize = blk: switch (data_block_size.is_uncompressed) {
            0 => {
                break :blk try decompressBlock(allocator, input, &offset, output);
            },
            1 => {
                const block_size: usize = data_block_size.size;
                if (input[offset..].len < block_size) {
                    return error.InvalidInput;
                }
                const block = input[offset .. offset + block_size];
                offset += block_size;
                try output.appendSlice(allocator, block);
                break :blk block_size;
            },
        };
        if (flg.block_checksum == 1) {
            const expected_checksum = try readInt(u32, input, &offset);
            const computed_checksum = contentHash(output.items[output.items.len - n_written ..]);
            if (expected_checksum != computed_checksum) {
                return error.InvalidBlockChecksum;
            }
        }
    }

    // Verify the content checksum if it is included.
    if (flg.content_checksum == 1) {
        const expected_checksum = try readInt(u32, input, &offset);
        const computed_checksum = contentHash(output.items);
        if (expected_checksum != computed_checksum) {
            return error.InvalidContentChecksum;
        }
    }

    return written;
}

// Reads and validates the magic number from the input slice, updating the offset.
fn readMagicNumber(input: []const u8, offset: *usize) !void {
    const magic_value = try readInt(u32, input, offset);
    if (magic_value != MAGIC_NUMBER) {
        return error.InvalidMagicNumber;
    }
}

// Reads the FLG and BD bytes from the input slice, updating the offset.
fn readFLGAndBG(input: []const u8, offset: *usize) !struct { FLG, BD } {
    const flg_byte = try readInt(u8, input, offset);
    const flg: FLG = @fromBackingInt(flg_byte);
    std.debug.print("flg_byte={b}\n", .{flg_byte});
    std.debug.print("flg: version={} block_independence={} block_checksum={} content_size={} content_checksum={} reserved={} dict_id={}\n", .{ flg.version, flg.block_independence, flg.block_checksum, flg.content_size, flg.content_checksum, flg.reserved, flg.dict_id });

    const bd_byte = try readInt(u8, input, offset);
    const bd: BD = @fromBackingInt(bd_byte);
    std.debug.print("bd_byte={b}\n", .{bd_byte});
    std.debug.print("bd: reserved={} block_max_size={} reserved2={}\n", .{ bd.reserved, bd.block_max_size, bd.reserved2 });

    return .{ flg, bd };
}

// Decompresses a block of LZ4-compressed data, writing the output to the
// provided `ArrayList`. Returns the number of bytes written to the output.
fn decompressBlock(
    allocator: std.mem.Allocator,
    input: []const u8,
    offset: *usize,
    output: *std.ArrayList(u8),
) !usize {
    var written: usize = 0;

    const token = try readToken(input, offset);

    // If the literal length is 15, then we need to read
    // the following bytes to determine the actual length.
    var literal_length: usize = token.literal_length;
    if (literal_length == 15) {
        literal_length += try readLSIC(input, offset);
    }
    std.debug.print("literal_length={}\n", .{literal_length});

    // At this point, we have a literal length, so we literally
    // can copy that many bytes from the input to the output.
    if (input[offset.*..].len < literal_length) {
        return error.InvalidInput;
    }
    const literal = input[offset.* .. offset.* + literal_length];
    try output.appendSlice(allocator, literal);
    offset.* += literal_length;
    written += literal_length;

    // Now, read the offset, and the match length.
    const match_offset = try readInt(u16, input, offset);
    var match_length: usize = token.match_length;
    if (match_length == 15) {
        match_length += try readLSIC(input, offset);
    }
    match_length += 4; // The minimum match length is 4.
    std.debug.print("match_offset={} match_length={}\n", .{ match_offset, match_length });

    // Now, we need to copy `match_length` bytes from the output buffer,
    // starting at `match_offset` bytes before the current end of the output.
    if (match_offset == 0 or match_offset > output.items.len) {
        return error.InvalidInput;
    }
    const match_start = output.items.len - match_offset;
    if (match_start + match_length > output.items.len) {
        return error.InvalidInput;
    }
    const match_bytes = output.items[match_start .. match_start + match_length];
    try output.appendSlice(allocator, match_bytes);
    written += match_length;

    return written;
}

// Reads a Token from the input slice, updating offset.
fn readToken(input: []const u8, offset: *usize) !Token {
    const token_byte = try readInt(u8, input, offset);
    return @fromBackingInt(token_byte);
}

// Reads a variable-length integer from the input slice, starting at the
// given offset. For each byte read, adds its value to the total until
// a byte less than 255 is encountered. Updates offset along the way,
// returning the total value read.
fn readLSIC(input: []const u8, offset: *usize) !u32 {
    var value: u32 = 0;
    while (true) {
        const byte = try readInt(u8, input, offset);
        value += byte;
        if (byte != 255) break;
    }
    return value;
}

// Reads an integer of type `T` from the input slice, starting at the given offset.
// Updates the offset and returns the integer value read.
fn readInt(comptime T: type, input: []const u8, offset: *usize) !T {
    const size = @sizeOf(T);
    if (offset.* + size > input.len) {
        return error.InvalidInput;
    }
    const int_bytes = input[offset.* .. offset.* + size][0..size];
    offset.* += size;
    return std.mem.readInt(T, int_bytes, .little);
}

// Hashes a byte slice using the XXHash32 algorithm, used by LZ4.
fn contentHash(data: []const u8) u32 {
    const seed = 0; // From the LZ4 spec.
    return XxHash32.hash(seed, data);
}

pub fn name() []const u8 {
    return "lz4";
}

// `LICENSE.lz4` was compressed with the reference `lz4` CLI tool.
// This test ensures we can decompress it correctly.
test "decompress lz4-cli output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const compressed = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "LICENSE.lz4",
        allocator,
        .unlimited,
    );
    defer allocator.free(compressed);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    const n_written = try decompressFrame(allocator, compressed, &output);
    try std.testing.expectEqual(output.items.len, n_written);

    const expected = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "LICENSE",
        allocator,
        .unlimited,
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, output.items);
}
