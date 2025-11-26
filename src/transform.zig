const std = @import("std");
const math = std.math;
const types = @import("types.zig");

// Transformada de Cosseno Discreta (DCT-II) 2D.
// Discrete Cosine Transform (DCT-II) 2D.
// A DCT converte um bloco de pixels (domínio espacial) para coeficientes de frequência (domínio da frequência).
// The DCT converts a block of pixels (spatial domain) to frequency coefficients (frequency domain).
// O objetivo é concentrar a energia da imagem em poucos coeficientes de baixa frequência (canto superior esquerdo).
// The goal is to concentrate the image energy into a few low-frequency coefficients (top-left corner).
// Isso facilita a compressão, pois as altas frequências (detalhes finos) podem ser descartadas com pouca perda visual.
// This facilitates compression, as high frequencies (fine details) can be discarded with little visual loss.
//
// NOTA: Esta é uma implementação "ingênua" O(N^4) para fins didáticos.
// NOTE: This is a "naive" O(N^4) implementation for educational purposes.
// Em produção, usa-se algoritmos rápidos O(N^2 log N) ou implementações SIMD.
// In production, fast O(N^2 log N) algorithms or SIMD implementations are used.
pub fn forward_dct(block: []const f32, result: []f32) void {
    const N = types.BLOCK_SIZE;

    for (0..N) |u| {
        for (0..N) |v| {
            var sum: f32 = 0.0;
            // Fatores de normalização para u=0 e v=0.
            // Normalization factors for u=0 and v=0.
            const cu: f32 = if (u == 0) 1.0 / math.sqrt(2.0) else 1.0;
            const cv: f32 = if (v == 0) 1.0 / math.sqrt(2.0) else 1.0;

            for (0..N) |x| {
                for (0..N) |y| {
                    const pixel = block[x * N + y];
                    const cos_x = math.cos(((2.0 * @as(f32, @floatFromInt(x)) + 1.0) * @as(f32, @floatFromInt(u)) * math.pi) / (2.0 * @as(f32, @floatFromInt(N))));
                    const cos_y = math.cos(((2.0 * @as(f32, @floatFromInt(y)) + 1.0) * @as(f32, @floatFromInt(v)) * math.pi) / (2.0 * @as(f32, @floatFromInt(N))));
                    sum += pixel * cos_x * cos_y;
                }
            }
            result[u * N + v] = 0.25 * cu * cv * sum;
        }
    }
}

// Transformada de Cosseno Discreta Inversa (IDCT-II) 2D.
// Inverse Discrete Cosine Transform (IDCT-II) 2D.
// Converte os coeficientes de frequência de volta para pixels (domínio espacial).
// Converts frequency coefficients back to pixels (spatial domain).
pub fn inverse_dct(coeffs: []const f32, result: []f32) void {
    const N = types.BLOCK_SIZE;

    for (0..N) |x| {
        for (0..N) |y| {
            var sum: f32 = 0.0;
            for (0..N) |u| {
                for (0..N) |v| {
                    const coeff = coeffs[u * N + v];
                    const cu: f32 = if (u == 0) 1.0 / math.sqrt(2.0) else 1.0;
                    const cv: f32 = if (v == 0) 1.0 / math.sqrt(2.0) else 1.0;

                    const cos_x = math.cos(((2.0 * @as(f32, @floatFromInt(x)) + 1.0) * @as(f32, @floatFromInt(u)) * math.pi) / (2.0 * @as(f32, @floatFromInt(N))));
                    const cos_y = math.cos(((2.0 * @as(f32, @floatFromInt(y)) + 1.0) * @as(f32, @floatFromInt(v)) * math.pi) / (2.0 * @as(f32, @floatFromInt(N))));
                    sum += cu * cv * coeff * cos_x * cos_y;
                }
            }
            result[x * N + y] = 0.25 * sum;
        }
    }
}
