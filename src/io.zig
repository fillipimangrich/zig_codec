const std = @import("std");
const fs = std.fs;
const types = @import("types.zig");

// Lê o cabeçalho do arquivo Y4M.
// Reads the Y4M file header.
// O formato Y4M começa com "YUV4MPEG2" seguido de tags como W (largura), H (altura), etc.
// The Y4M format starts with "YUV4MPEG2" followed by tags like W (width), H (height), etc.
pub fn readY4mHeader(reader: anytype) !types.Y4mHeader {
    // Lê a primeira linha até encontrar '\n'.
    // Reads the first line until '\n' is found.
    const line = try reader.readUntilDelimiterOrEofAlloc(std.heap.page_allocator, '\n', 1024) orelse return error.InvalidFormat;
    defer std.heap.page_allocator.free(line);

    if (!std.mem.startsWith(u8, line, "YUV4MPEG2")) return error.InvalidFormat;

    var width: usize = 0;
    var height: usize = 0;

    // Parseia as tags separadas por espaço.
    // Parses space-separated tags.
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

// Lê um frame do arquivo Y4M.
// Reads a frame from the Y4M file.
// Cada frame começa com a string "FRAME" seguida de um '\n' (0x0A).
// Each frame starts with the string "FRAME" followed by a '\n' (0x0A).
// Depois vêm os bytes crus dos planos Y, U e V.
// Then come the raw bytes of the Y, U, and V planes.
pub fn readFrame(reader: anytype, frame: *types.Frame) !bool {
    var header: [6]u8 = undefined;

    // Lê os 6 bytes do header FRAME (5 letras + \n).
    // Reads the 6 bytes of the FRAME header (5 letters + \n).
    const bytes_read = try reader.read(&header);
    if (bytes_read == 0) return false; // Fim do arquivo / End of file
    if (bytes_read < 6) return false; // Arquivo cortado / Truncated file

    if (!std.mem.eql(u8, header[0..5], "FRAME")) return false;

    // readNoEof garante que o frame inteiro foi lido.
    // readNoEof ensures the entire frame was read.
    // Se faltar dados no meio do frame, retorna erro.
    // If data is missing in the middle of the frame, returns error.
    try reader.readNoEof(frame.y);
    try reader.readNoEof(frame.u);
    try reader.readNoEof(frame.v);
    return true;
}
