const std = @import("std");
const fs = std.fs;
const process = std.process;

const types = @import("types.zig");
const transform = @import("transform.zig");
const quant = @import("quantization.zig");
const pred = @import("prediction.zig");
const bitstream = @import("bitstream.zig");
const io = @import("io.zig");

const BLOCK_SIZE = types.BLOCK_SIZE;

// Helper para criar uma "visualização" de um plano específico como se fosse um Frame independente.
fn make_plane_view(original: *types.Frame, plane: enum { Y, U, V }) types.Frame {
    switch (plane) {
        .Y => return types.Frame{
            .width = original.width,
            .height = original.height,
            .y = original.y,
            .u = undefined,
            .v = undefined,
            .allocator = original.allocator,
        },
        .U => return types.Frame{
            .width = original.width / 2,
            .height = original.height / 2,
            .y = original.u,
            .u = undefined,
            .v = undefined,
            .allocator = original.allocator,
        },
        .V => return types.Frame{
            .width = original.width / 2,
            .height = original.height / 2,
            .y = original.v,
            .u = undefined,
            .v = undefined,
            .allocator = original.allocator,
        },
    }
}

fn encode_plane(
    bw: *bitstream.BitWriter,
    curr_view: *const types.Frame,
    ref_view: *const types.Frame,
    recon_view: *types.Frame,
    is_intra: bool,
) !void {
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

            // 1. Extrair Bloco Original
            for (0..BLOCK_SIZE) |y| {
                for (0..BLOCK_SIZE) |x| {
                    blk_orig[y * BLOCK_SIZE + x] = curr_view.y[(by + y) * curr_view.width + (bx + x)];
                }
            }

            // 2. Predição
            if (is_intra) {
                pred.intra_dc(bx, by, recon_view, &blk_pred);
            } else {
                const mv = pred.inter_motion_est(&blk_orig, bx, by, ref_view, &blk_pred);
                try bw.writeSigned(@as(i16, mv.x));
                try bw.writeSigned(@as(i16, mv.y));
            }

            // 3. Resíduo
            for (0..blk_orig.len) |i| {
                blk_resid[i] = @as(f32, @floatFromInt(blk_orig[i])) - @as(f32, @floatFromInt(blk_pred[i]));
            }

            // 4. Transformada & Quantização
            transform.forward_dct(&blk_resid, &blk_coeffs);
            quant.quantize(&blk_coeffs, &blk_quant);

            // 5. Entropia
            for (blk_quant) |q| {
                try bw.writeSigned(q);
            }

            // --- Reconstrução ---
            quant.dequantize(&blk_quant, &blk_coeffs);
            transform.inverse_dct(&blk_coeffs, &blk_recon_resid);

            for (0..BLOCK_SIZE) |y| {
                for (0..BLOCK_SIZE) |x| {
                    const idx = y * BLOCK_SIZE + x;
                    const pred_val = @as(f32, @floatFromInt(blk_pred[idx]));
                    const recon_val = std.math.clamp(pred_val + blk_recon_resid[idx], 0.0, 255.0);

                    recon_view.y[(by + y) * curr_view.width + (bx + x)] = @as(u8, @intFromFloat(recon_val));
                }
            }
        }
    }
}

fn decode_plane(
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

            // 1. Predição
            if (is_intra) {
                pred.intra_dc(bx, by, curr_view, &blk_pred);
            } else {
                const mv_x = try br.readSigned();
                const mv_y = try br.readSigned();
                pred.inter_motion_comp(bx, by, @as(i8, @intCast(mv_x)), @as(i8, @intCast(mv_y)), ref_view, &blk_pred);
            }

            // 2. Coeficientes
            for (0..BLOCK_SIZE * BLOCK_SIZE) |i| {
                blk_quant[i] = try br.readSigned();
            }
            quant.dequantize(&blk_quant, &blk_coeffs);

            // 3. IDCT
            transform.inverse_dct(&blk_coeffs, &blk_recon_resid);

            // 4. Reconstrução
            for (0..BLOCK_SIZE) |y| {
                for (0..BLOCK_SIZE) |x| {
                    const idx = y * BLOCK_SIZE + x;
                    const pred_val = @as(f32, @floatFromInt(blk_pred[idx]));
                    const recon_val = std.math.clamp(pred_val + blk_recon_resid[idx], 0.0, 255.0);

                    curr_view.y[(by + y) * curr_view.width + (bx + x)] = @as(u8, @intFromFloat(recon_val));
                }
            }
        }
    }
}

fn encode(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const file = try fs.cwd().openFile(input_path, .{});
    defer file.close();

    var buffered = std.io.bufferedReader(file.reader());
    const reader = buffered.reader();

    const header = try io.readY4mHeader(reader);
    std.debug.print("Encoding: {d}x{d}\n", .{ header.width, header.height });

    const out_file = try fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var bw = bitstream.BitWriter.init(allocator);
    defer bw.deinit();

    // Header Binário
    try bw.writeBits(@as(u32, @intCast(header.width)), 16);
    try bw.writeBits(@as(u32, @intCast(header.height)), 16);

    var curr_raw_frame = try types.Frame.init(allocator, header.width, header.height);
    defer curr_raw_frame.deinit();
    var recon_frame = try types.Frame.init(allocator, header.width, header.height);
    defer recon_frame.deinit();
    var ref_frame = try types.Frame.init(allocator, header.width, header.height);
    defer ref_frame.deinit();

    @memset(ref_frame.y, 128);
    @memset(ref_frame.u, 128);
    @memset(ref_frame.v, 128);

    var frame_idx: usize = 0;

    while (try io.readFrame(reader, &curr_raw_frame)) {
        std.debug.print("Encoding Frame {d}...\r", .{frame_idx});

        // CORREÇÃO: Escreve flag '1' para indicar que existe um frame.
        try bw.writeBit(1);

        const is_intra = (frame_idx == 0);
        try bw.writeBit(if (is_intra) 1 else 0);

        // Y
        var raw_y = make_plane_view(&curr_raw_frame, .Y);
        var ref_y = make_plane_view(&ref_frame, .Y);
        var recon_y = make_plane_view(&recon_frame, .Y);
        try encode_plane(&bw, &raw_y, &ref_y, &recon_y, is_intra);

        // U
        var raw_u = make_plane_view(&curr_raw_frame, .U);
        var ref_u = make_plane_view(&ref_frame, .U);
        var recon_u = make_plane_view(&recon_frame, .U);
        try encode_plane(&bw, &raw_u, &ref_u, &recon_u, is_intra);

        // V
        var raw_v = make_plane_view(&curr_raw_frame, .V);
        var ref_v = make_plane_view(&ref_frame, .V);
        var recon_v = make_plane_view(&recon_frame, .V);
        try encode_plane(&bw, &raw_v, &ref_v, &recon_v, is_intra);

        ref_frame.copyFrom(recon_frame);
        frame_idx += 1;
    }

    // CORREÇÃO: Escreve flag '0' para indicar fim do stream antes do flush.
    // O decoder lerá esse 0 e saberá que acabou, ignorando o padding.
    try bw.writeBit(0);

    try bw.flush();
    try out_file.writeAll(bw.buffer.items);
    std.debug.print("\nEncoding Complete. Size: {d} bytes\n", .{bw.buffer.items.len});
}

fn decode(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const file = try fs.cwd().openFile(input_path, .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(file_data);

    var br = bitstream.BitReader.init(file_data);

    const width = try br.readBits(16);
    const height = try br.readBits(16);
    std.debug.print("Decoding: {d}x{d}\n", .{ width, height });

    const out_file = try fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var out_writer = out_file.writer();

    try out_writer.print("YUV4MPEG2 W{d} H{d} F30:1 Ip A1:1 C420\n", .{ width, height });

    var curr_frame = try types.Frame.init(allocator, width, height);
    var ref_frame = try types.Frame.init(allocator, width, height);
    defer curr_frame.deinit();
    defer ref_frame.deinit();

    @memset(ref_frame.y, 128);
    @memset(ref_frame.u, 128);
    @memset(ref_frame.v, 128);

    var frame_idx: usize = 0;

    while (true) {
        // CORREÇÃO: Lê o flag de "Existe Frame?".
        // Se ler 0, sai do loop limpo.
        const has_frame_bit = br.readBit() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        if (has_frame_bit == 0) {
            // Fim do stream lógico encontrado.
            break;
        }

        // Se chegou aqui, existe um frame. Agora lê se é Intra ou Inter.
        const is_intra_bit = try br.readBit();
        const is_intra = (is_intra_bit == 1);

        std.debug.print("Decoding Frame {d} ({s})...\r", .{ frame_idx, if (is_intra) "I" else "P" });

        // Y
        var ref_y = make_plane_view(&ref_frame, .Y);
        var curr_y = make_plane_view(&curr_frame, .Y);
        try decode_plane(&br, &ref_y, &curr_y, is_intra);

        // U
        var ref_u = make_plane_view(&ref_frame, .U);
        var curr_u = make_plane_view(&curr_frame, .U);
        try decode_plane(&br, &ref_u, &curr_u, is_intra);

        // V
        var ref_v = make_plane_view(&ref_frame, .V);
        var curr_v = make_plane_view(&curr_frame, .V);
        try decode_plane(&br, &ref_v, &curr_v, is_intra);

        // Saída Y4M
        try out_writer.writeAll("FRAME\n");
        try out_writer.writeAll(curr_frame.y);
        try out_writer.writeAll(curr_frame.u);
        try out_writer.writeAll(curr_frame.v);

        ref_frame.copyFrom(curr_frame);
        frame_idx += 1;
    }
    std.debug.print("\nDecoding Complete.\n", .{});
}

fn calculate_psnr(path_a: []const u8, path_b: []const u8) !void {
    const file_a = try fs.cwd().openFile(path_a, .{});
    defer file_a.close();
    const file_b = try fs.cwd().openFile(path_b, .{});
    defer file_b.close();

    var buffered_a = std.io.bufferedReader(file_a.reader());
    const reader_a = buffered_a.reader();
    var buffered_b = std.io.bufferedReader(file_b.reader());
    const reader_b = buffered_b.reader();

    const header_a = try io.readY4mHeader(reader_a);
    const header_b = try io.readY4mHeader(reader_b);

    var frame_a = try types.Frame.init(std.heap.page_allocator, header_a.width, header_a.height);
    defer frame_a.deinit();
    var frame_b = try types.Frame.init(std.heap.page_allocator, header_b.width, header_b.height);
    defer frame_b.deinit();

    var frame_count: usize = 0;
    var total_mse: f64 = 0.0;

    while (true) {
        const has_a = try io.readFrame(reader_a, &frame_a);
        const has_b = try io.readFrame(reader_b, &frame_b);
        if (!has_a or !has_b) break;

        var mse: f64 = 0.0;
        for (frame_a.y, frame_b.y) |p_a, p_b| {
            const diff = @as(f64, @floatFromInt(p_a)) - @as(f64, @floatFromInt(p_b));
            mse += diff * diff;
        }
        mse /= @as(f64, @floatFromInt(header_a.width * header_a.height));
        total_mse += mse;
        frame_count += 1;
    }

    const avg_mse = total_mse / @as(f64, @floatFromInt(frame_count));
    const psnr = 10.0 * std.math.log10((255.0 * 255.0) / avg_mse);
    std.debug.print("Processed {d} frames. PSNR (Y only): {d:.2} dB\n", .{ frame_count, psnr });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage:\n  zcodec encode <input.y4m> <output.bin>\n  zcodec decode <input.bin> <output.y4m>\n  zcodec psnr <orig.y4m> <dec.y4m>\n", .{});
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "encode")) {
        if (args.len != 4) return error.InvalidArgs;
        try encode(allocator, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "decode")) {
        if (args.len != 4) return error.InvalidArgs;
        try decode(allocator, args[2], args[3]);
    } else if (std.mem.eql(u8, command, "psnr")) {
        if (args.len != 4) return error.InvalidArgs;
        try calculate_psnr(args[2], args[3]);
    } else {
        std.debug.print("Unknown command\n", .{});
    }
}
