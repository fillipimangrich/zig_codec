const std = @import("std");

// --- Constantes de Configuração ---
// Mantemos aqui para fácil ajuste global
pub const BLOCK_SIZE: usize = 8;
pub const SEARCH_RANGE: usize = 8; // Alcance da busca de movimento
pub const QUANT_SCALE: f32 = 10.0;

// --- Estruturas Compartilhadas ---

pub const Y4mHeader = struct {
    width: usize,
    height: usize,
    fps_num: usize,
    fps_den: usize,
};

pub const Frame = struct {
    width: usize,
    height: usize,
    y: []u8,
    u: []u8,
    v: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Frame {
        const y_size = width * height;
        const uv_size = (width / 2) * (height / 2); // 4:2:0

        return Frame{
            .width = width,
            .height = height,
            .y = try allocator.alloc(u8, y_size),
            .u = try allocator.alloc(u8, uv_size),
            .v = try allocator.alloc(u8, uv_size),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.y);
        self.allocator.free(self.u);
        self.allocator.free(self.v);
    }

    pub fn copyFrom(self: *Frame, other: Frame) void {
        @memcpy(self.y, other.y);
        @memcpy(self.u, other.u);
        @memcpy(self.v, other.v);
    }
};
