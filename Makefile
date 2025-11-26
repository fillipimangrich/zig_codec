# Configurações
ZIG = zig
EXE = bin/zcodec
SRC = src/main.zig
INPUT = assets/videos/original/input.y4m
BIN = assets/encoded/output.bin
DECODED = assets/videos/decoded/decoded.y4m
# URL de teste (Akiyo CIF - leve e bom para testar)
URL = https://media.xiph.org/video/derf/y4m/akiyo_cif.y4m

# Alvo padrão (apenas compila)
all: build

# 1. Compilação (ReleaseFast para performance máxima)
build:
	$(ZIG) build-exe $(SRC) -O ReleaseFast --name zcodec
	mv zcodec $(EXE)

# 2. Baixar vídeo de teste se não existir
download:
	@if [ ! -f $(INPUT) ]; then \
		echo "Baixando $(INPUT)..."; \
		wget $(URL) -O $(INPUT); \
	else \
		echo "$(INPUT) já existe."; \
	fi

# 3. Codificar (Gera output.bin)
encode: build download
	@echo "Codificando..."
	./$(EXE) encode $(INPUT) $(BIN)

# 4. Decodificar (Gera decoded.y4m)
decode: encode
	@echo "Decodificando..."
	./$(EXE) decode $(BIN) $(DECODED)

# 5. Calcular PSNR
psnr: decode
	@echo "Calculando qualidade..."
	./$(EXE) psnr $(INPUT) $(DECODED)

# 6. Calcular Taxa de Compressão (NOVO)
ratio: encode
	@echo "--- Estatísticas de Compressão ---"
	@ORIG=$$(stat -c%s $(INPUT)); \
	COMP=$$(stat -c%s $(BIN)); \
	awk -v o=$$ORIG -v c=$$COMP 'BEGIN { printf "Tamanho Original:   %d bytes\nTamanho Comprimido: %d bytes\nRazão de Compressão: %.2f:1\nTamanho Final:      %.2f%% do original\n", o, c, o/c, (c/o)*100 }'

# 7. Visualizar Original
view-orig: download
	mpv --loop $(INPUT)

# 8. Visualizar Decodificado
view-dec: decode
	mpv --loop $(DECODED)

# Limpeza
clean:
	rm -f $(EXE) $(EXE).o $(BIN) $(DECODED)
	@echo "Limpo."

# Atalho para rodar tudo de uma vez
run: psnr ratio