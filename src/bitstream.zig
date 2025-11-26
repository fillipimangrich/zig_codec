const std = @import("std");

pub const BitWriter = struct {
    buffer: std.ArrayList(u8),
    current_byte: u8,
    bit_count: u3,

    pub fn init(allocator: std.mem.Allocator) BitWriter {
        return BitWriter{
            .buffer = std.ArrayList(u8).init(allocator),
            .current_byte = 0,
            .bit_count = 0,
        };
    }
    pub fn deinit(self: *BitWriter) void {
        self.buffer.deinit();
    }

    // Implementação segura que evita overflow de u3 (0..7)
    pub fn writeBit(self: *BitWriter, bit: u1) !void {
        self.current_byte = (self.current_byte << 1) | bit;

        // Truque: verificamos se chegamos a 7 ANTES de incrementar
        // Se fosse 8, não caberia em u3 e causaria erro em runtime/debug
        if (self.bit_count == 7) {
            try self.buffer.append(self.current_byte);
            self.bit_count = 0;
            self.current_byte = 0;
        } else {
            self.bit_count += 1;
        }
    }

    pub fn writeBits(self: *BitWriter, val: u32, count: u5) !void {
        var i: i32 = @as(i32, count) - 1;
        while (i >= 0) : (i -= 1) {
            const bit = @as(u1, @intCast((val >> @as(u5, @intCast(i))) & 1));
            try self.writeBit(bit);
        }
    }

    pub fn writeSigned(self: *BitWriter, val: i16) !void {
        const abs_val = if (val < 0) -val else val;
        const sign: u1 = if (val < 0) 1 else 0;

        for (0..@as(usize, @intCast(abs_val))) |_| {
            try self.writeBit(1);
        }
        try self.writeBit(0);
        if (abs_val > 0) {
            try self.writeBit(sign);
        }
    }

    pub fn flush(self: *BitWriter) !void {
        if (self.bit_count > 0) {
            // bit_count é u3 (0..7). 8 - bit_count cabe em u4.
            const remaining: u4 = 8 - @as(u4, self.bit_count);

            self.current_byte = self.current_byte << @as(u3, @intCast(remaining));
            try self.buffer.append(self.current_byte);
            self.bit_count = 0;
            self.current_byte = 0;
        }
    }
};

pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3,

    pub fn init(data: []const u8) BitReader {
        return BitReader{ .data = data, .byte_pos = 0, .bit_pos = 0 };
    }

    pub fn readBit(self: *BitReader) !u1 {
        if (self.byte_pos >= self.data.len) return error.EndOfStream;
        const bit = (self.data[self.byte_pos] >> (7 - self.bit_pos)) & 1;

        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }

        return @as(u1, @intCast(bit));
    }

    // Função ADICIONADA que faltava
    pub fn readBits(self: *BitReader, count: u5) !u32 {
        var val: u32 = 0;
        // Lê bit a bit, do mais significativo para o menos significativo
        var i: i32 = @as(i32, count) - 1;
        while (i >= 0) : (i -= 1) {
            const bit = try self.readBit();
            val |= @as(u32, bit) << @as(u5, @intCast(i));
        }
        return val;
    }

    pub fn readSigned(self: *BitReader) !i16 {
        var count: i16 = 0;
        while ((try self.readBit()) == 1) {
            count += 1;
            if (count > 255) return error.CorruptedStream;
        }
        if (count == 0) return 0;

        const sign = try self.readBit();
        return if (sign == 1) -count else count;
    }
};
