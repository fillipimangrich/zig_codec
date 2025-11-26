const std = @import("std");

// --- Constantes de Configuração / Configuration Constants ---
// Mantemos aqui para fácil ajuste global.
// Kept here for easy global adjustment.

// Tamanho do bloco para a Transformada de Cosseno Discreta (DCT).
// Block size for the Discrete Cosine Transform (DCT).
// 8x8 é o padrão em codecs antigos como JPEG, MPEG-1, MPEG-2, H.261.
// 8x8 is the standard in older codecs like JPEG, MPEG-1, MPEG-2, H.261.
pub const BLOCK_SIZE: usize = 8;

// Alcance da busca de movimento (Motion Estimation).
// Range for motion estimation search.
// Define quantos pixels ao redor do bloco atual vamos procurar por uma correspondência no frame anterior.
// Defines how many pixels around the current block we search for a match in the previous frame.
pub const SEARCH_RANGE: usize = 8;

// Fator de escala para quantização.
// Scaling factor for quantization.
// Quanto maior este valor, mais compressão e menos qualidade (mais perda).
// The higher this value, the more compression and less quality (more loss).
pub const QUANT_SCALE: f32 = 10.0;

// --- Estruturas Compartilhadas ---

// Cabeçalho do formato Y4M (YUV4MPEG2).
// Header for the Y4M (YUV4MPEG2) format.
// Este formato é um container simples para vídeo raw (não comprimido).
// This format is a simple container for raw (uncompressed) video.
pub const Y4mHeader = struct {
    width: usize,
    height: usize,
    fps_num: usize,
    fps_den: usize,
};

// Representação de um Frame de vídeo em memória.
// Representation of a video Frame in memory.
// Usamos o espaço de cor YUV (Luminância + Crominância).
// We use the YUV color space (Luminance + Chrominance).
pub const Frame = struct {
    width: usize,
    height: usize,
    // Plano Y (Luminância/Brilho) - Resolução total.
    // Y Plane (Luminance/Brightness) - Full resolution.
    y: []u8,
    // Plano U (Crominância Azul) - Subamostrado (menor resolução).
    // U Plane (Blue Chrominance) - Subsampled (lower resolution).
    u: []u8,
    // Plano V (Crominância Vermelha) - Subamostrado (menor resolução).
    // V Plane (Red Chrominance) - Subsampled (lower resolution).
    v: []u8,
    allocator: std.mem.Allocator,

    // Inicializa um frame alocando memória para os planos.
    // Initializes a frame by allocating memory for the planes.
    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Frame {
        const y_size = width * height;
        // Subamostragem 4:2:0: U e V têm metade da largura e metade da altura de Y.
        // 4:2:0 Subsampling: U and V have half the width and half the height of Y.
        // Isso reduz a quantidade de dados de cor em 75% sem muita perda visual perceptível.
        // This reduces color data by 75% without much perceptible visual loss.
        const uv_size = (width / 2) * (height / 2);

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

    // Copia o conteúdo de outro frame para este.
    // Copies the content from another frame to this one.
    pub fn copyFrom(self: *Frame, other: Frame) void {
        @memcpy(self.y, other.y);
        @memcpy(self.u, other.u);
        @memcpy(self.v, other.v);
    }
};
