const std = @import("std");
const fs = std.fs;
const types = @import("types.zig");

pub fn readY4mHeader(reader: anytype) !types.Y4mHeader {
    const line = try reader.readUntilDelimiterOrEofAlloc(std.heap.page_allocator, '\n', 1024) orelse return error.InvalidFormat;
    defer std.heap.page_allocator.free(line);

    if (!std.mem.startsWith(u8, line, "YUV4MPEG2")) return error.InvalidFormat;

    var width: usize = 0;
    var height: usize = 0;

    var it = std.mem.splitScalar(u8, line, ' ');
    while (it.next()) |chunk| {
        if (chunk.len == 0) continue;
        switch (chunk[0]) {
            'W' => width = try std.fmt.parseInt(usize, chunk[1..], 10),
            'H' => height = try std.fmt.parseInt(usize, chunk[1..], 10),
            else => {},
        }
    }

    return types.Y4mHeader{ .width = width, .height = height, .fps_num = 30, .fps_den = 1 };
}

pub fn readFrame(reader: anytype, frame: *types.Frame) !bool {
    var header: [6]u8 = undefined;

    // Lê os 6 bytes do header FRAME
    const bytes_read = try reader.read(&header);
    if (bytes_read == 0) return false; // Fim do arquivo
    if (bytes_read < 6) return false; // Arquivo cortado

    if (!std.mem.eql(u8, header[0..5], "FRAME")) return false;

    // readNoEof garante que o frame inteiro foi lido
    try reader.readNoEof(frame.y);
    try reader.readNoEof(frame.u);
    try reader.readNoEof(frame.v);
    return true;
}
