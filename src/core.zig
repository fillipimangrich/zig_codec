const std = @import("std");
const types = @import("types.zig");
const transform = @import("transform.zig");
const quant = @import("quantization.zig");
const pred = @import("prediction.zig");
const bitstream = @import("bitstream.zig");

const BLOCK_SIZE = types.BLOCK_SIZE;

// Helper para criar uma "visualização" de um plano específico como se fosse um Frame independente.
// Helper to create a "view" of a specific plane as if it were an independent Frame.
// Isso simplifica o código, permitindo tratar Y, U e V da mesma forma.
// This simplifies the code, allowing Y, U, and V to be treated in the same way.
pub fn make_plane_view(original: *types.Frame, plane: enum { Y, U, V }) types.Frame {
    switch (plane) {
        .Y => return types.Frame{
            .width = original.width,
            .height = original.height,
            .y = original.y,
            .u = undefined, // Não usado nesta view / Not used in this view
            .v = undefined, // Não usado nesta view / Not used in this view
            .allocator = original.allocator,
        },
        .U => return types.Frame{
            .width = original.width / 2,
            .height = original.height / 2,
            .y = original.u, // Mapeia U para Y da view / Maps U to Y of the view
            .u = undefined,
            .v = undefined,
            .allocator = original.allocator,
        },
        .V => return types.Frame{
            .width = original.width / 2,
            .height = original.height / 2,
            .y = original.v, // Mapeia V para Y da view / Maps V to Y of the view
            .u = undefined,
            .v = undefined,
            .allocator = original.allocator,
        },
    }
}

// Codifica um plano (Y, U ou V).
// Encodes a plane (Y, U, or V).
// O processo é dividido em blocos de 8x8 pixels.
// The process is divided into 8x8 pixel blocks.
pub fn encode_plane(
    bw: *bitstream.BitWriter,
    curr_view: *const types.Frame,
    ref_view: *const types.Frame,
    recon_view: *types.Frame,
    is_intra: bool,
) !void {
    // Buffers temporários para o processamento do bloco.
    // Temporary buffers for block processing.
    var blk_orig: [BLOCK_SIZE * BLOCK_SIZE]u8 = undefined;
    var blk_pred: [BLOCK_SIZE * BLOCK_SIZE]u8 = undefined;
    var blk_resid: [BLOCK_SIZE * BLOCK_SIZE]f32 = undefined;
    var blk_coeffs: [BLOCK_SIZE * BLOCK_SIZE]f32 = undefined;
    var blk_quant: [BLOCK_SIZE * BLOCK_SIZE]i16 = undefined;
    var blk_recon_resid: [BLOCK_SIZE * BLOCK_SIZE]f32 = undefined;

    var by: usize = 0;
    while (by < curr_view.height) : (by += BLOCK_SIZE) {
        var bx: usize = 0;
        while (bx < curr_view.width) : (bx += BLOCK_SIZE) {

            // 1. Extrair Bloco Original.
            // 1. Extract Original Block.
            for (0..BLOCK_SIZE) |y| {
                for (0..BLOCK_SIZE) |x| {
                    blk_orig[y * BLOCK_SIZE + x] = curr_view.y[(by + y) * curr_view.width + (bx + x)];
                }
            }

            // 2. Predição (Intra ou Inter).
            // 2. Prediction (Intra or Inter).
            if (is_intra) {
                // Intra: Prediz com base nos vizinhos já reconstruídos.
                // Intra: Predicts based on already reconstructed neighbors.
                pred.intra_dc(bx, by, recon_view, &blk_pred);
            } else {
                // Inter: Busca o melhor bloco no frame anterior (Motion Estimation).
                // Inter: Searches for the best block in the previous frame (Motion Estimation).
                const mv = pred.inter_motion_est(&blk_orig, bx, by, ref_view, &blk_pred);
                // Escreve o vetor de movimento no bitstream.
                // Writes the motion vector to the bitstream.
                try bw.writeSigned(@as(i16, mv.x));
                try bw.writeSigned(@as(i16, mv.y));
            }

            // 3. Resíduo (Erro de Predição).
            // 3. Residual (Prediction Error).
            // Subtrai a predição do original. O que sobra é o "erro" que precisamos corrigir.
            // Subtracts the prediction from the original. What remains is the "error" we need to fix.
            for (0..blk_orig.len) |i| {
                blk_resid[i] = @as(f32, @floatFromInt(blk_orig[i])) - @as(f32, @floatFromInt(blk_pred[i]));
            }

            // 4. Transformada & Quantização.
            // 4. Transform & Quantization.
            // Converte para frequência e descarta informações menos importantes.
            // Converts to frequency and discards less important information.
            transform.forward_dct(&blk_resid, &blk_coeffs);
            quant.quantize(&blk_coeffs, &blk_quant);

            // 5. Entropia.
            // 5. Entropy.
            // Escreve os coeficientes quantizados no arquivo.
            // Writes the quantized coefficients to the file.
            for (blk_quant) |q| {
                try bw.writeSigned(q);
            }

            // --- Reconstrução (Loop Local) ---
            // --- Reconstruction (Local Loop) ---
            // O encoder precisa simular o decoder para ter a mesma referência para os próximos frames/blocos.
            // The encoder needs to simulate the decoder to have the same reference for the next frames/blocks.
            quant.dequantize(&blk_quant, &blk_coeffs);
            transform.inverse_dct(&blk_coeffs, &blk_recon_resid);

            for (0..BLOCK_SIZE) |y| {
                for (0..BLOCK_SIZE) |x| {
                    const idx = y * BLOCK_SIZE + x;
                    const pred_val = @as(f32, @floatFromInt(blk_pred[idx]));
                    // Soma a predição com o resíduo reconstruído.
                    // Sums the prediction with the reconstructed residual.
                    const recon_val = std.math.clamp(pred_val + blk_recon_resid[idx], 0.0, 255.0);

                    recon_view.y[(by + y) * curr_view.width + (bx + x)] = @as(u8, @intFromFloat(recon_val));
                }
            }
        }
    }
}

// Decodifica um plano.
// Decodes a plane.
// Realiza o processo inverso do encode_plane.
// Performs the inverse process of encode_plane.
pub fn decode_plane(
    br: *bitstream.BitReader,
    ref_view: *const types.Frame,
    curr_view: *types.Frame,
    is_intra: bool,
) !void {
    var blk_pred: [BLOCK_SIZE * BLOCK_SIZE]u8 = undefined;
    var blk_coeffs: [BLOCK_SIZE * BLOCK_SIZE]f32 = undefined;
    var blk_quant: [BLOCK_SIZE * BLOCK_SIZE]i16 = undefined;
    var blk_recon_resid: [BLOCK_SIZE * BLOCK_SIZE]f32 = undefined;

    var by: usize = 0;
    while (by < curr_view.height) : (by += BLOCK_SIZE) {
        var bx: usize = 0;
        while (bx < curr_view.width) : (bx += BLOCK_SIZE) {

            // 1. Predição.
            // 1. Prediction.
            if (is_intra) {
                pred.intra_dc(bx, by, curr_view, &blk_pred);
            } else {
                // Lê o vetor de movimento do bitstream.
                // Reads the motion vector from the bitstream.
                const mv_x = try br.readSigned();
                const mv_y = try br.readSigned();
                // Reconstrói o bloco predito usando o frame de referência.
                // Reconstructs the predicted block using the reference frame.
                pred.inter_motion_comp(bx, by, @as(i8, @intCast(mv_x)), @as(i8, @intCast(mv_y)), ref_view, &blk_pred);
            }

            // 2. Coeficientes (Entropia).
            // 2. Coefficients (Entropy).
            for (0..BLOCK_SIZE * BLOCK_SIZE) |i| {
                blk_quant[i] = try br.readSigned();
            }
            // Dequantiza para recuperar os coeficientes aproximados.
            // Dequantizes to recover approximate coefficients.
            quant.dequantize(&blk_quant, &blk_coeffs);

            // 3. IDCT (Transformada Inversa).
            // 3. IDCT (Inverse Transform).
            // Recupera o resíduo (erro de predição).
            // Recovers the residual (prediction error).
            transform.inverse_dct(&blk_coeffs, &blk_recon_resid);

            // 4. Reconstrução Final.
            // 4. Final Reconstruction.
            for (0..BLOCK_SIZE) |y| {
                for (0..BLOCK_SIZE) |x| {
                    const idx = y * BLOCK_SIZE + x;
                    const pred_val = @as(f32, @floatFromInt(blk_pred[idx]));
                    // Soma a predição com o resíduo.
                    // Sums the prediction with the residual.
                    const recon_val = std.math.clamp(pred_val + blk_recon_resid[idx], 0.0, 255.0);

                    curr_view.y[(by + y) * curr_view.width + (bx + x)] = @as(u8, @intFromFloat(recon_val));
                }
            }
        }
    }
}
