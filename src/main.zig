const std = @import("std");
const fs = std.fs;
const process = std.process;

const types = @import("types.zig");
const transform = @import("transform.zig");
const quant = @import("quantization.zig");
const pred = @import("prediction.zig");
const bitstream = @import("bitstream.zig");
const io = @import("io.zig");
const core = @import("core.zig");

const BLOCK_SIZE = types.BLOCK_SIZE;

// Função principal de codificação.
// Main encoding function.
// Lê um arquivo Y4M, comprime e escreve em um arquivo binário customizado.
// Reads a Y4M file, compresses it, and writes to a custom binary file.
fn encode(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const file = try fs.cwd().openFile(input_path, .{});
    defer file.close();

    var buffered = std.io.bufferedReader(file.reader());
    const reader = buffered.reader();

    // Lê o cabeçalho Y4M para saber a resolução.
    // Reads the Y4M header to get the resolution.
    const header = try io.readY4mHeader(reader);
    std.debug.print("Encoding: {d}x{d}\n", .{ header.width, header.height });

    const out_file = try fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var bw = bitstream.BitWriter.init(allocator);
    defer bw.deinit();

    // --- Header Binário / Binary Header ---
    // Escrevemos a largura e altura (16 bits cada) no início do arquivo.
    // We write the width and height (16 bits each) at the beginning of the file.
    try bw.writeBits(@as(u32, @intCast(header.width)), 16);
    try bw.writeBits(@as(u32, @intCast(header.height)), 16);

    // Aloca frames para o processo de codificação.
    // Allocates frames for the encoding process.
    // curr_raw_frame: O frame que acabamos de ler do arquivo (entrada).
    // curr_raw_frame: The frame we just read from the file (input).
    var curr_raw_frame = try types.Frame.init(allocator, header.width, header.height);
    defer curr_raw_frame.deinit();
    // recon_frame: O frame reconstruído após a compressão (o que o decoder vai ver).
    // recon_frame: The reconstructed frame after compression (what the decoder will see).
    var recon_frame = try types.Frame.init(allocator, header.width, header.height);
    defer recon_frame.deinit();
    // ref_frame: O frame anterior reconstruído, usado como referência para predição Inter.
    // ref_frame: The previous reconstructed frame, used as reference for Inter prediction.
    var ref_frame = try types.Frame.init(allocator, header.width, header.height);
    defer ref_frame.deinit();

    // Inicializa o frame de referência com cinza (128) para o primeiro frame.
    // Initializes the reference frame with gray (128) for the first frame.
    @memset(ref_frame.y, 128);
    @memset(ref_frame.u, 128);
    @memset(ref_frame.v, 128);

    var frame_idx: usize = 0;

    // Loop principal: lê frame a frame até acabar o arquivo.
    // Main loop: reads frame by frame until end of file.
    while (try io.readFrame(reader, &curr_raw_frame)) {
        std.debug.print("Encoding Frame {d}...\r", .{frame_idx});

        // Flag '1' indica que existe mais um frame.
        // Flag '1' indicates there is another frame.
        try bw.writeBit(1);

        // O primeiro frame é sempre Intra (I-Frame). Os outros são Inter (P-Frames).
        // The first frame is always Intra (I-Frame). The others are Inter (P-Frames).
        const is_intra = (frame_idx == 0);
        try bw.writeBit(if (is_intra) 1 else 0);

        // Codifica cada plano separadamente.
        // Encodes each plane separately.

        // Y (Luminância)
        var raw_y = core.make_plane_view(&curr_raw_frame, .Y);
        var ref_y = core.make_plane_view(&ref_frame, .Y);
        var recon_y = core.make_plane_view(&recon_frame, .Y);
        try core.encode_plane(&bw, &raw_y, &ref_y, &recon_y, is_intra);

        // U (Crominância)
        var raw_u = core.make_plane_view(&curr_raw_frame, .U);
        var ref_u = core.make_plane_view(&ref_frame, .U);
        var recon_u = core.make_plane_view(&recon_frame, .U);
        try core.encode_plane(&bw, &raw_u, &ref_u, &recon_u, is_intra);

        // V (Crominância)
        var raw_v = core.make_plane_view(&curr_raw_frame, .V);
        var ref_v = core.make_plane_view(&ref_frame, .V);
        var recon_v = core.make_plane_view(&recon_frame, .V);
        try core.encode_plane(&bw, &raw_v, &ref_v, &recon_v, is_intra);

        // Atualiza a referência: o frame reconstruído atual vira a referência para o próximo.
        // Updates reference: the current reconstructed frame becomes the reference for the next one.
        ref_frame.copyFrom(recon_frame);
        frame_idx += 1;
    }

    // Flag '0' indica fim do stream.
    // Flag '0' indicates end of stream.
    try bw.writeBit(0);

    try bw.flush();
    try out_file.writeAll(bw.buffer.items);
    std.debug.print("\nEncoding Complete. Size: {d} bytes\n", .{bw.buffer.items.len});
}

// Função principal de decodificação.
// Main decoding function.
// Lê o arquivo binário comprimido e reconstrói o vídeo em formato Y4M.
// Reads the compressed binary file and reconstructs the video in Y4M format.
fn decode(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const file = try fs.cwd().openFile(input_path, .{});
    defer file.close();

    // Lê o arquivo inteiro para a memória (simples, mas consome RAM).
    // Reads the entire file into memory (simple, but consumes RAM).
    const file_data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(file_data);

    var br = bitstream.BitReader.init(file_data);

    // Lê o cabeçalho binário.
    // Reads the binary header.
    const width = try br.readBits(16);
    const height = try br.readBits(16);
    std.debug.print("Decoding: {d}x{d}\n", .{ width, height });

    const out_file = try fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var out_writer = out_file.writer();

    // Escreve o cabeçalho Y4M no arquivo de saída.
    // Writes the Y4M header to the output file.
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
        // Verifica se há mais frames (lê o flag '1' ou '0').
        // Checks if there are more frames (reads flag '1' or '0').
        const has_frame_bit = br.readBit() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        if (has_frame_bit == 0) {
            // Fim do stream lógico encontrado.
            // Logical end of stream found.
            break;
        }

        // Lê o tipo do frame (Intra ou Inter).
        // Reads frame type (Intra or Inter).
        const is_intra_bit = try br.readBit();
        const is_intra = (is_intra_bit == 1);

        std.debug.print("Decoding Frame {d} ({s})...\r", .{ frame_idx, if (is_intra) "I" else "P" });

        // Decodifica cada plano.
        // Decodes each plane.

        // Y
        var ref_y = core.make_plane_view(&ref_frame, .Y);
        var curr_y = core.make_plane_view(&curr_frame, .Y);
        try core.decode_plane(&br, &ref_y, &curr_y, is_intra);

        // U
        var ref_u = core.make_plane_view(&ref_frame, .U);
        var curr_u = core.make_plane_view(&curr_frame, .U);
        try core.decode_plane(&br, &ref_u, &curr_u, is_intra);

        // V
        var ref_v = core.make_plane_view(&ref_frame, .V);
        var curr_v = core.make_plane_view(&curr_frame, .V);
        try core.decode_plane(&br, &ref_v, &curr_v, is_intra);

        // Escreve o frame decodificado no arquivo Y4M.
        // Writes the decoded frame to the Y4M file.
        try out_writer.writeAll("FRAME\n");
        try out_writer.writeAll(curr_frame.y);
        try out_writer.writeAll(curr_frame.u);
        try out_writer.writeAll(curr_frame.v);

        // Atualiza a referência.
        // Updates reference.
        ref_frame.copyFrom(curr_frame);
        frame_idx += 1;
    }
    std.debug.print("\nDecoding Complete.\n", .{});
}

// Calcula o PSNR (Peak Signal-to-Noise Ratio).
// Calculates PSNR (Peak Signal-to-Noise Ratio).
// Compara o vídeo original com o decodificado para medir a qualidade.
// Compares the original video with the decoded one to measure quality.
// Quanto maior o PSNR, melhor a qualidade (menos distorção).
// The higher the PSNR, the better the quality (less distortion).
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
        // Calcula o Erro Quadrático Médio (MSE) apenas para o plano Y.
        // Calculates Mean Squared Error (MSE) for Y plane only.
        for (frame_a.y, frame_b.y) |p_a, p_b| {
            const diff = @as(f64, @floatFromInt(p_a)) - @as(f64, @floatFromInt(p_b));
            mse += diff * diff;
        }
        mse /= @as(f64, @floatFromInt(header_a.width * header_a.height));
        total_mse += mse;
        frame_count += 1;
    }

    const avg_mse = total_mse / @as(f64, @floatFromInt(frame_count));
    // Fórmula do PSNR: 10 * log10(MAX^2 / MSE)
    // PSNR Formula: 10 * log10(MAX^2 / MSE)
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
