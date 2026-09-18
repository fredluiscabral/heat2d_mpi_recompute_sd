# Heat2D MPI — WAIT, RECOMPUTE e PREDICT no SDumont II

Este repositório contém o protótipo MPI usado para estudar dependências numéricas atrasadas em um método explícito para a equação do calor 2D. O solver principal usa FTCS e compara três possibilidades no consumidor de um halo inter-nó: aguardar o dado real (`WAIT`), reconstruí-lo exatamente a partir do estado anterior (`RECOMPUTE`) e, em uma variante ainda diagnóstica, estimá-lo por extrapolação temporal (`PREDICT`).

O objetivo atual não é reduzir o volume de comunicação MPI. O foco é medir quando vale a pena evitar uma espera exposta sem comprometer a solução numérica.

## Topologia

O código usa `MPI_Comm_split_type(..., MPI_COMM_TYPE_SHARED, ...)` para descobrir os nós físicos. Com `Nnodes` nós e `Ppn` ranks por nó, a decomposição lógica é

```text
Py x Px = Nnodes x Ppn
```

Cada nó recebe uma faixa em `y`; os ranks dentro do nó subdividem `x`. Assim, esquerda/direita ficam intra-nó e cima/baixo ficam inter-nó.

No SDumont II usado nestes experimentos, cada nó possui dois AMD EPYC 9684X, com 96 núcleos físicos por socket, totalizando 192 núcleos físicos por nó. Portanto, `4 x 192` usa 768 ranks MPI e ocupa os 192 núcleos físicos de cada nó. O script `run_compare_4n96.sbatch` é um controle de meia densidade, com 96 ranks por nó; ele não deve ser interpretado como “um rank por todos os núcleos físicos do nó”.

## Variantes

`heat2d_naive` é o baseline: se o halo não chegou quando é necessário, o rank faz `MPI_Wait`.

`heat2d_recompute` mantém a comunicação normal, mas pode reconstruir exatamente o halo atrasado no consumidor. A variante aceita `--policy always`, `--policy cost` e `--policy wait`. A política `cost` usa EWMAs do custo de espera e do custo de reconstrução; `--policy wait` serve como controle `SUPPORT+WAIT`, enviando o tráfego de suporte sem usar a reconstrução.

`heat2d_predict` é, neste momento, **somente diagnóstico**. Quando um halo ainda não chegou, ele calcula

```text
Uhat^n = 2 U^(n-1) - U^(n-2)
```

usando dois halos reais consecutivos. A previsão ainda **não substitui o halo real na solução**: o código espera o MPI, compara previsão e halo verdadeiro e imprime uma linha `PREDICT_DIAG` com número de testes, erro L-infinito médio e erro L-infinito máximo. O critério numérico de admissibilidade para usar PREDICT de fato ainda será incorporado.

`heat2d_naive_trace` e `heat2d_naive_waittrace` são variantes de instrumentação. Elas foram usadas para estudar criticidade dinâmica e propagação de espera; não fazem parte da política principal de produção.

## RECOMPUTE exato

No passo `n`, o halo normal continua sendo enviado. A variante adaptativa envia também um pacote de suporte contendo a linha imediatamente mais profunda no subdomínio produtor e os dois valores laterais necessários nas extremidades da fronteira. Se o halo atual estiver atrasado e o suporte anterior estiver disponível, o consumidor reconstrói o valor que o produtor obteria pelo mesmo stencil FTCS.

A mensagem normal não é cancelada. Quando chega, pode ser comparada com a reconstrução por `late_validation_max`. Em execuções corretas, essa diferença fica em zero ou no nível de arredondamento de ponto flutuante.

## Compilação no SDumont II

```bash
source ./env_sd.sh
make
```

ou simplesmente:

```bash
./build_sd.sh
```

O `Makefile` usa `mpicxx` explicitamente, evitando o problema de o `make` escolher `g++` e não encontrar `mpi.h`.

Os alvos são:

```bash
make core         # naive, recompute, predict
make diagnostics  # trace, waittrace
make              # todos
make clean
```

## Teste inicial

```bash
sbatch run_smoke.sbatch
```

Depois, para a comparação principal em 4 nós x 192 ranks:

```bash
sbatch run_compare_4n192.sbatch
```

Parâmetros podem ser sobrescritos pelo ambiente, por exemplo:

```bash
NX=8192 NY=8192 STEPS=10000 REPS=10 POLICY=cost BETA=1.0 \
  sbatch run_compare_4n192.sbatch
```

Os resultados são gravados em `results/`, que é ignorado pelo Git. Os arquivos de stdout do Slurm também são direcionados para `results/` nos scripts desta versão limpa, evitando poluir a raiz do repositório.

## Experimentos disponíveis

- `run_smoke.sbatch`: teste funcional curto.
- `run_compare_4n192.sbatch`: comparação principal NAIVE / SUPPORT+WAIT / RECOMPUTE.
- `run_compare_4n96.sbatch`: controle de meia densidade, 96 ranks por nó.
- `run_delay_sweep_4n192.sbatch`: atraso sintético controlado.
- `run_beta_same_nodes.sbatch`: sweep de `beta` na mesma alocação.
- `run_beta_confirm.sbatch`: confirmação pareada para betas selecionados.
- `run_phi_probe.sbatch`, `run_phi_delay_sweep.sbatch`, `run_phi_rankpos.sbatch`: experimentos exploratórios de criticidade.
- `run_critical_baseline.sbatch`, `run_critical_trace.sbatch`, `run_critical_trace_balanced.sbatch`: instrumentação temporal do caminho crítico observado.
- `run_waittrace_balanced.sbatch`: cruza trajetória crítica e esperas locais agregadas.
- `run_predict_diag.sbatch`: teste diagnóstico do extrapolador PREDICT.

Os quatro nós `sdumont2nd1011`, `sdumont2nd1018`, `sdumont2nd1023` e `sdumont2nd1031` são excluídos nos experimentos controlados mais recentes porque execuções anteriores apresentaram anomalias muito grandes nesse conjunto. Isso é uma precaução experimental; não constitui diagnóstico de falha física desses nós.

## Análise

Para arquivos `RESULT` em um mesmo diretório:

```bash
python3 analyze_results.py caminho --exclude-warmup
```

`analyze_wait_predict.py` reproduz a análise exploratória do `WAITTRACE`. Ela deve ser interpretada junto com `RESEARCH_STATUS.md`, pois uma associação forte entre pressão de bloqueio e criticidade não se transformou em capacidade preditiva temporal quando testada contra um nulo que preserva a estrutura espacial.

## Estado da pesquisa

O histórico resumido dos experimentos, resultados negativos importantes e o próximo passo estão em [`RESEARCH_STATUS.md`](RESEARCH_STATUS.md).

## Novo clone no SDumont II

Depois de publicar esta versão no GitHub:

```bash
git clone https://github.com/fredluiscabral/heat2d_mpi_recompute_sd.git
cd heat2d_mpi_recompute_sd
./build_sd.sh
```

O backup completo antigo, com binários, logs e resultados brutos, deve ser mantido fora do repositório Git.
