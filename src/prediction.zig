const std = @import("std");
const types = @import("types.zig");

// Predição INTRA DC
pub fn intra_dc(block_x: usize, block_y: usize, frame: *const types.Frame, out_pred: []u8) void {
    var sum: u32 = 0;
    var count: u32 = 0;
    const stride = frame.width;
    const bs = types.BLOCK_SIZE;

    // Top
    if (block_y > 0) {
        for (0..bs) |x| {
            sum += frame.y[(block_y - 1) * stride + (block_x + x)];
            count += 1;
        }
    }
    // Left
    if (block_x > 0) {
        for (0..bs) |y| {
            sum += frame.y[(block_y + y) * stride + (block_x - 1)];
            count += 1;
        }
    }

    const dc_val: u8 = if (count > 0) @as(u8, @intCast(sum / count)) else 128;
    @memset(out_pred, dc_val);
}

// Predição INTER (Motion Estimation - Full Search)
// Retorna o vetor de movimento e preenche out_pred para o Encoder
pub fn inter_motion_est(curr_block: []const u8, bx: usize, by: usize, ref_frame: *const types.Frame, out_pred: []u8) struct { x: i8, y: i8 } {
    const stride = ref_frame.width;
    const bs = types.BLOCK_SIZE;
    var best_sad: u32 = std.math.maxInt(u32);
    var best_mv_x: i8 = 0;
    var best_mv_y: i8 = 0;

    const range = types.SEARCH_RANGE;

    var dy: isize = -@as(isize, @intCast(range));
    while (dy <= range) : (dy += 1) {
        var dx: isize = -@as(isize, @intCast(range));
        while (dx <= range) : (dx += 1) {
            const ref_x = @as(isize, @intCast(bx)) + dx;
            const ref_y = @as(isize, @intCast(by)) + dy;

            // Check bounds
            if (ref_x < 0 or ref_y < 0 or ref_x + bs > ref_frame.width or ref_y + bs > ref_frame.height) {
                continue;
            }

            // Calc SAD
            var current_sad: u32 = 0;
            for (0..bs) |blk_y| {
                for (0..bs) |blk_x| {
                    const p_orig = curr_block[blk_y * bs + blk_x];
                    const r_idx = (@as(usize, @intCast(ref_y)) + blk_y) * stride + (@as(usize, @intCast(ref_x)) + blk_x);
                    const p_ref = ref_frame.y[r_idx];
                    current_sad += if (p_orig > p_ref) p_orig - p_ref else p_ref - p_orig;
                }
                if (current_sad >= best_sad) break;
            }

            if (current_sad < best_sad) {
                best_sad = current_sad;
                best_mv_x = @as(i8, @intCast(dx));
                best_mv_y = @as(i8, @intCast(dy));
            }
        }
    }

    // Aplica a compensação para gerar o bloco predito final
    inter_motion_comp(bx, by, best_mv_x, best_mv_y, ref_frame, out_pred);

    return .{ .x = best_mv_x, .y = best_mv_y };
}

// NOVO: Motion Compensation (Usado pelo Decoder e pelo final do Encoder)
// Reconstrói o bloco predito baseado apenas no vetor de movimento e no frame de referência
pub fn inter_motion_comp(bx: usize, by: usize, mv_x: i8, mv_y: i8, ref_frame: *const types.Frame, out_pred: []u8) void {
    const stride = ref_frame.width;
    const bs = types.BLOCK_SIZE;

    const ref_x = @as(isize, @intCast(bx)) + mv_x;
    const ref_y = @as(isize, @intCast(by)) + mv_y;

    // Em um decoder real, precisaria tratar boundaries (clipping).
    // Aqui assumimos que o bitstream é válido e aponta para dentro.

    for (0..bs) |blk_y| {
        for (0..bs) |blk_x| {
            const r_idx = (@as(usize, @intCast(ref_y)) + blk_y) * stride + (@as(usize, @intCast(ref_x)) + blk_x);
            out_pred[blk_y * bs + blk_x] = ref_frame.y[r_idx];
        }
    }
}
