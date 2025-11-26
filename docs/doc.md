ZCodec: Manual Técnico e Princípios de FuncionamentoEste documento detalha o funcionamento interno do ZCodec, um codificador de vídeo educacional escrito em Zig. O codec segue a arquitetura clássica de Codificação Híbrida Baseada em Blocos (Block-Based Hybrid Coding), a mesma fundação utilizada em padrões como MPEG-2, H.264 e HEVC.1. Visão Geral da ArquiteturaO ZCodec opera dividindo a imagem em blocos de pixels (neste caso, $8 \times 8$) e processando-os sequencialmente. A compressão é alcançada através da remoção de dois tipos de redundância:Redundância Espacial (Intra): Pixels vizinhos tendem a ser similares.Redundância Temporal (Inter): Quadros consecutivos tendem a ser similares, apenas com objetos se movendo.Redundância Psicovisual: O olho humano é menos sensível a altas frequências (detalhes finos).Fluxograma do Codificador (Encoder)O codificador contém um decodificador embutido (o loop de feedback) para garantir que a referência usada para predição seja idêntica à que o decodificador terá.flowchart TD
    Input[Entrada YUV] --> Sub[Subtração (-)]
    Pred[Predição] --> Sub
    Sub --> Resid[Resíduo]
    Resid --> DCT[Transformada DCT]
    DCT --> Coeffs[Coeficientes]
    Coeffs --> Quant[Quantização]
    Quant --> Levels[Níveis Quantizados]
    Levels --> Entropy[Codificação de Entropia]
    Entropy --> Bitstream[Arquivo Binário]

    %% Loop de Reconstrução
    Levels --> Dequant[Desquantização]
    Dequant --> IDCT[DCT Inversa]
    IDCT --> ReconResid[Resíduo Reconstruído]
    ReconResid --> Add[Soma (+)]
    Pred --> Add
    Add --> ReconFrame[Frame Reconstruído]
    ReconFrame --> RefFrame[Frame de Referência]
    RefFrame --> MotionEst[Estimativa de Movimento]
    MotionEst --> Pred
2. Estrutura de Dados: YUV 4:2:0O vídeo digital cru geralmente não usa RGB, mas sim YUV (ou YCbCr).Y (Luma): Brilho/Luminosidade (imagem em preto e branco). O olho humano é muito sensível a isso.U/V (Chroma): Informação de cor (diferença de azul e vermelho). O olho humano é menos sensível a cor.Subamostragem 4:2:0:No ZCodec, para cada bloco de $2 \times 2$ pixels (4 pixels totais), temos:4 amostras de Y.1 amostra de U.1 amostra de V.Isso reduz o tamanho do arquivo cru pela metade antes mesmo de começarmos a comprimir ($1 + 0.25 + 0.25 = 1.5$ bytes por pixel vs 3 bytes do RGB).3. Predição (Prediction)A ideia central é: Nunca codifique o pixel real. Codifique o erro de uma tentativa de adivinhar o pixel.$$ Resíduo = Original - Predição $$3.1. Predição Intra (I-Frame)Usada em quadros chave (Keyframes) ou quando a cena muda drasticamente. A predição é feita usando apenas informações do quadro atual já codificado.Modo DC (Implementado):O codec calcula a média dos pixels da borda superior e da borda esquerda do bloco atual.$$ P_{x,y} = \frac{\sum_{i=0}^{7} Top_i + \sum_{j=0}^{7} Left_j}{16} $$Se não houver vizinhos (canto superior esquerdo da imagem), assume-se um valor cinza médio (128).3.2. Predição Inter e Estimativa de Movimento (P-Frame)Usada para aproveitar a redundância temporal. O codec procura no quadro anterior (RefFrame) um bloco de $8 \times 8$ que seja muito parecido com o bloco atual.Algoritmo: Full Search Block MatchingPara cada posição $(dx, dy)$ dentro de uma janela de busca (Search Range = $\pm 8$ pixels):Compara o bloco atual $C$ com o bloco de referência $R$ deslocado por $(dx, dy)$.Calcula o custo usando SAD (Sum of Absolute Differences):$$ SAD(dx, dy) = \sum_{y=0}^{7} \sum_{x=0}^{7} | C(x,y) - R(x+dx, y+dy) | $$O vetor $(dx, dy)$ que resultar no menor SAD é escolhido como o Vetor de Movimento (MV).Esse vetor é enviado no bitstream.4. Transformada (DCT - Discrete Cosine Transform)O resíduo (a diferença entre o original e a predição) geralmente contém pouca energia, mas ainda está no domínio espacial. A DCT converte isso para o Domínio da Frequência.Por que usar DCT?Ela compacta a energia no canto superior esquerdo da matriz (baixas frequências). Detalhes finos e ruídos vão para o canto inferior direito (altas frequências).Fórmula da DCT-II 2D ($N=8$):$$ X_{u,v} = \frac{1}{4} C(u)C(v) \sum_{x=0}^{7} \sum_{y=0}^{7} x_{i,j} \cos\left[\frac{(2x+1)u\pi}{16}\right] \cos\left[\frac{(2y+1)v\pi}{16}\right] $$Onde:$u, v$: coordenadas de frequência (horizontal, vertical).$x, y$: coordenadas espaciais.$C(k) = \frac{1}{\sqrt{2}}$ se $k=0$, senão $1$.No código (transform.zig), usamos uma implementação "ingênua" de complexidade $O(N^4)$ para clareza didática. Codecs reais usam algoritmos rápidos tipo "Butterfly" ($O(N \log N)$).5. QuantizaçãoÉ aqui que ocorre a compressão com perdas (Lossy Compression).Nós dividimos os coeficientes da DCT por um fator de escala (QUANT_SCALE) e arredondamos para o inteiro mais próximo.$$ Nível_{u,v} = \text{round}\left( \frac{Coeficiente_{u,v}}{QScale} \right) $$Efeito: Coeficientes de alta frequência (que geralmente são pequenos) tornam-se ZERO.Controle: Aumentar o QScale cria mais zeros (menor arquivo), mas perde mais detalhes (pior qualidade).No ZCodec, usamos QUANT_SCALE = 10.0.6. Codificação de Entropia (Bitstream)Depois da quantização, temos uma matriz cheia de zeros e alguns números pequenos. Precisamos escrever isso em bits da forma mais compacta possível.O ZCodec usa uma implementação simplificada:Header: Largura e Altura (16 bits cada).Flags de Frame: 1 bit indicando se existe frame, 1 bit indicando se é Intra ou Inter.Vetores de Movimento (Inter): Codificados como inteiros com sinal.Coeficientes: A matriz $8 \times 8$ linearizada é escrita sequencialmente.Codificação de Inteiros (BitWriter):Usamos um esquema unário simplificado para números com sinal:Ex: Para codificar o número -3:Escreve magnitude: 1110 (três 1s seguidos de 0).Escreve sinal: 1 (negativo).Resultado: 11101.Isso é eficiente para números pequenos (comuns no resíduo quantizado), mas ineficiente para números grandes. Codecs reais usam Huffman ou Aritmética (CABAC).7. O DecodificadorO decodificador faz o processo inverso. É crucial que ele seja determinístico.flowchart TD
    Bitstream[Arquivo Binário] --> Entropy[Decodificação Entropia]
    Entropy --> MVs[Vetores Movimento]
    Entropy --> Levels[Níveis Quantizados]
    
    Levels --> Dequant[Desquantização]
    Dequant --> IDCT[DCT Inversa]
    IDCT --> ReconResid[Resíduo Reconstruído]

    MVs --> PredGen[Compensação de Movimento]
    RefFrame[Frame Anterior] --> PredGen
    PredGen --> Pred[Predição]
    
    ReconResid --> Add[Soma (+)]
    Pred --> Add
    Add --> Out[Saída YUV]
    Out --> RefFrame
Passos Críticos:Desquantização: $Coeficiente' = Nível \times QScale$. (Note que não recuperamos o valor original exato, pois houve arredondamento).IDCT: Transforma frequência de volta para pixels (resíduo).Compensação: Soma o resíduo recuperado à predição feita usando os vetores de movimento lidos.8. Métricas: PSNRPara medir se o codec é bom, usamos o PSNR (Peak Signal-to-Noise Ratio). Ele compara o vídeo original com o vídeo que passou pelo processo de codificação/decodificação.$$ MSE = \frac{1}{W \cdot H} \sum_{i,j} (Original_{i,j} - Decodificado_{i,j})^2 $$$$ PSNR_{dB} = 10 \cdot \log_{10}\left( \frac{255^2}{MSE} \right) $$> 40 dB: Excelente.30-40 dB: Bom.< 20 dB: Ruim.Resumo das Fórmulas Implementadas no CódigoEtapaArquivoOperação PrincipalDCTtransform.zigProduto escalar com cossenos.Quantizaçãoquantization.zigDivisão inteira: round(x / 10.0)SADprediction.zigSoma de diferenças absolutas: `Driftmain.zigrecon_frame = clamp(pred + resid)