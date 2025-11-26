const std = @import("std");
const math = std.math;
const types = @import("types.zig");

// Quantização Uniforme Escalar.
// Uniform Scalar Quantization.
// Este é o passo onde ocorre a perda de informação (Lossy Compression).
// This is the step where information loss occurs (Lossy Compression).
// Dividimos os coeficientes por um fator de escala e arredondamos para o inteiro mais próximo.
// We divide the coefficients by a scaling factor and round to the nearest integer.
// Isso reduz a precisão dos valores, fazendo com que valores pequenos se tornem zero.
// This reduces the precision of the values, causing small values to become zero.
pub fn quantize(coeffs: []const f32, result: []i16) void {
    for (coeffs, 0..) |c, i| {
        result[i] = @as(i16, @intFromFloat(math.round(c / types.QUANT_SCALE)));
    }
}

// Dequantização (Reconstrução).
// Dequantization (Reconstruction).
// Multiplicamos os valores quantizados pelo fator de escala para recuperar uma aproximação do valor original.
// We multiply the quantized values by the scaling factor to recover an approximation of the original value.
// Note que nunca recuperamos o valor exato original devido ao arredondamento na quantização.
// Note that we never recover the exact original value due to rounding in quantization.
pub fn dequantize(q_coeffs: []const i16, result: []f32) void {
    for (q_coeffs, 0..) |qc, i| {
        result[i] = @as(f32, @floatFromInt(qc)) * types.QUANT_SCALE;
    }
}
