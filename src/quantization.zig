const std = @import("std");
const math = std.math;
const types = @import("types.zig");

pub fn quantize(coeffs: []const f32, result: []i16) void {
    for (coeffs, 0..) |c, i| {
        result[i] = @as(i16, @intFromFloat(math.round(c / types.QUANT_SCALE)));
    }
}

pub fn dequantize(q_coeffs: []const i16, result: []f32) void {
    for (q_coeffs, 0..) |qc, i| {
        result[i] = @as(f32, @floatFromInt(qc)) * types.QUANT_SCALE;
    }
}
