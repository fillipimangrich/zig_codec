const std = @import("std");
const math = std.math;
const types = @import("types.zig");

// DCT-II 2D
pub fn forward_dct(block: []const f32, result: []f32) void {
    const N = types.BLOCK_SIZE;

    for (0..N) |u| {
        for (0..N) |v| {
            var sum: f32 = 0.0;
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

// IDCT-II 2D
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
