const std = @import("std");

// Estrutura para escrever bits individuais em um buffer de bytes.
// Structure for writing individual bits into a byte buffer.
// Útil para compressão, onde os dados nem sempre alinham com 8 bits.
// Useful for compression, where data doesn't always align with 8 bits.
pub const BitWriter = struct {
    buffer: std.ArrayList(u8),
    current_byte: u8,
    bit_count: u3, // Contador de bits no byte atual (0..7) / Bit counter in current byte (0..7)

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

    // Escreve um único bit (0 ou 1).
    // Writes a single bit (0 or 1).
    // Implementação segura que evita overflow de u3 (0..7).
    // Safe implementation avoiding u3 overflow (0..7).
    pub fn writeBit(self: *BitWriter, bit: u1) !void {
        // Desloca o byte atual para a esquerda e insere o bit no LSB.
        // Shifts current byte left and inserts bit at LSB.
        self.current_byte = (self.current_byte << 1) | bit;

        // Truque: verificamos se chegamos a 7 ANTES de incrementar.
        // Trick: check if we reached 7 BEFORE incrementing.
        // Se fosse 8, não caberia em u3 e causaria erro em runtime/debug.
        // If it were 8, it wouldn't fit in u3 and would cause runtime/debug error.
        if (self.bit_count == 7) {
            try self.buffer.append(self.current_byte);
            self.bit_count = 0;
            self.current_byte = 0;
        } else {
            self.bit_count += 1;
        }
    }

    // Escreve múltiplos bits de um valor inteiro.
    // Writes multiple bits from an integer value.
    pub fn writeBits(self: *BitWriter, val: u32, count: u5) !void {
        var i: i32 = @as(i32, count) - 1;
        // Escreve do bit mais significativo para o menos significativo.
        // Writes from most significant bit to least significant.
        while (i >= 0) : (i -= 1) {
            const bit = @as(u1, @intCast((val >> @as(u5, @intCast(i))) & 1));
            try self.writeBit(bit);
        }
    }

    // Escreve um valor com sinal usando codificação Unária + Sinal.
    // Writes a signed value using Unary + Sign coding.
    // Exemplo: 3 -> 1110 (3 uns e um zero) + 0 (sinal positivo)
    // Example: -2 -> 110 (2 uns e um zero) + 1 (sinal negativo)
    // Esta é uma forma muito simples de codificação de entropia (Golomb-Rice simplificado).
    // This is a very simple form of entropy coding (simplified Golomb-Rice).
    pub fn writeSigned(self: *BitWriter, val: i16) !void {
        const abs_val = if (val < 0) -val else val;
        const sign: u1 = if (val < 0) 1 else 0;

        // Escreve N '1's, onde N é o valor absoluto.
        // Write N '1's, where N is the absolute value.
        for (0..@as(usize, @intCast(abs_val))) |_| {
            try self.writeBit(1);
        }
        // Escreve um '0' para terminar a sequência unária.
        // Write a '0' to terminate the unary sequence.
        try self.writeBit(0);

        // Se não for zero, escreve o bit de sinal.
        // If not zero, write the sign bit.
        if (abs_val > 0) {
            try self.writeBit(sign);
        }
    }

    // Preenche o último byte com zeros e escreve no buffer.
    // Pads the last byte with zeros and writes to buffer.
    pub fn flush(self: *BitWriter) !void {
        if (self.bit_count > 0) {
            // bit_count é u3 (0..7). 8 - bit_count cabe em u4.
            // bit_count is u3 (0..7). 8 - bit_count fits in u4.
            const remaining: u4 = 8 - @as(u4, self.bit_count);

            self.current_byte = self.current_byte << @as(u3, @intCast(remaining));
            try self.buffer.append(self.current_byte);
            self.bit_count = 0;
            self.current_byte = 0;
        }
    }
};

// Estrutura para ler bits de um slice de bytes.
// Structure for reading bits from a byte slice.
pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3, // Posição do bit atual no byte (0..7) / Current bit position in byte (0..7)

    pub fn init(data: []const u8) BitReader {
        return BitReader{ .data = data, .byte_pos = 0, .bit_pos = 0 };
    }

    // Lê um único bit.
    // Reads a single bit.
    pub fn readBit(self: *BitReader) !u1 {
        if (self.byte_pos >= self.data.len) return error.EndOfStream;
        // Extrai o bit na posição correta.
        // Extracts the bit at the correct position.
        const bit = (self.data[self.byte_pos] >> (7 - self.bit_pos)) & 1;

        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }

        return @as(u1, @intCast(bit));
    }

    // Lê múltiplos bits e retorna como u32.
    // Reads multiple bits and returns as u32.
    // Função ADICIONADA que faltava / ADDED function that was missing
    pub fn readBits(self: *BitReader, count: u5) !u32 {
        var val: u32 = 0;
        // Lê bit a bit, do mais significativo para o menos significativo.
        // Reads bit by bit, from most significant to least significant.
        var i: i32 = @as(i32, count) - 1;
        while (i >= 0) : (i -= 1) {
            const bit = try self.readBit();
            val |= @as(u32, bit) << @as(u5, @intCast(i));
        }
        return val;
    }

    // Lê um valor com sinal codificado em Unário + Sinal.
    // Reads a signed value encoded in Unary + Sign.
    pub fn readSigned(self: *BitReader) !i16 {
        var count: i16 = 0;
        // Conta quantos '1's existem antes do '0'.
        // Counts how many '1's exist before the '0'.
        while ((try self.readBit()) == 1) {
            count += 1;
            // Proteção contra streams corrompidos ou muito longos.
            // Protection against corrupted or too long streams.
            if (count > 255) return error.CorruptedStream;
        }
        if (count == 0) return 0;

        // Lê o bit de sinal.
        // Reads the sign bit.
        const sign = try self.readBit();
        return if (sign == 1) -count else count;
    }
};
