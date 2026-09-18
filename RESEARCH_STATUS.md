# Estado da pesquisa — checkpoint de setembro de 2026

Este arquivo preserva o estado experimental que existia antes da limpeza do diretório do SDumont II. Os dados brutos e logs completos não estão versionados no Git; eles permanecem no backup externo `heat2d_mpi_recompute_sd_full_20260917.tar.gz`.

## 1. Núcleo do problema

O protótipo trata dependências numéricas atrasadas em FTCS 2D com MPI puro. A pergunta principal é se um consumidor deve aguardar um halo (`WAIT`) ou substituí-lo por uma alternativa numérica (`RECOMPUTE`, e futuramente `PREDICT`).

O resultado experimental mais importante até aqui é que reduzir espera local não implica automaticamente reduzir o makespan global. A política de custo local é útil como componente, mas não é uma medida de criticidade global.

## 2. RECOMPUTE e política de custo

A reconstrução no consumidor reproduz o halo FTCS com erro de validação tardia no nível de arredondamento (`late_validation_max` tipicamente próximo de `2.22e-16`). A mensagem MPI real continua em voo e é drenada posteriormente.

No sweep do job 609148, com `8192 x 8192`, 10.000 passos e 10 repetições, as medianas observadas foram aproximadamente:

| tratamento | mediana do makespan |
|---|---:|
| NAIVE | 1.752602 s |
| SUPPORT+WAIT | 1.728634 s |
| cost, beta=0.5 | 1.638302 s |
| cost, beta=1.0 | 1.645679 s |
| cost, beta=2.0 | 1.808382 s |
| cost, beta=4.0 | 1.585718 s |

Esse sweep parecia favorável a alguns betas, mas a confirmação maior não sustentou uma superioridade robusta.

No job 609509, com 30 repetições pareadas:

- NAIVE: mediana 1.687560 s;
- beta=0.5: mediana 1.675082 s, 18/30 vitórias pareadas e mediana do ganho pareado de cerca de 2.8%;
- beta=4.0: mediana 1.754209 s, 13/30 vitórias e um outlier grande.

A conclusão adotada é: **há tendência positiva em algumas condições, mas não evidência de superioridade robusta da política puramente local**.

## 3. Investigação de criticidade

A investigação de criticidade foi feita para entender por que retirar WAIT nem sempre melhora o makespan. Ela foi encerrada como linha principal para evitar transformar o trabalho em um estudo separado de previsão de caminho crítico em MPI.

No job 617877, 30 baselines de 10.000 passos mostraram o nó crítico final distribuído como:

```text
node0 = 12
node1 = 2
node2 = 5
node3 = 11
```

Portanto, não existe um nó final fixo intrinsecamente crítico.

No TRACE dinâmico do job 619096 (`8192 x 8192`), 971/1000 amostras globais críticas caíram em `local_rank < 128`. Isso coincidiu com a decomposição desigual em `x`: 128 ranks tinham 43 colunas e 64 ranks tinham 42. Apesar desse viés, 831/1000 amostras tinham os quatro máximos por nó alinhados em colunas com diferença máxima de um rank.

O job 619970 repetiu o TRACE com `8256 x 8256`, exatamente divisível por 192 em `x`. Com todos os ranks recebendo 43 colunas:

- `local_rank < 128` caiu para 708/1000 amostras, próximo da proporção geométrica 128/192;
- o alinhamento das colunas críticas permaneceu: 827/1000 amostras com spread de no máximo 1;
- a distribuição do nó crítico mudou fortemente em relação ao caso 8192.

Interpretação: **o desequilíbrio 43/42 explicava grande parte do viés espacial, mas não a existência do alinhamento em colunas**. Isso é consistente com dinâmica de dependências/progresso, sem provar um mecanismo único.

## 4. WAITTRACE e resultado negativo importante

O job 621561 agregou esperas reais por rank, direção e janela de 100 passos, junto com TRACE. A análise mostrou uma associação forte entre a criticidade observada e a quantidade de espera que um produtor causa em outros ranks. Entretanto, essa associação não se transformou em previsão temporal robusta.

Foi testada uma pressão de bloqueio

```text
P = incoming_wait - outgoing_wait
```

Nos saltos de coluna crítica maiores que 10 posições, `P(k)` colocava o crítico de `k+1` no top 10% em 39.17% dos casos. Esse número parecia alto frente a um nulo ingênuo de 10%, mas um teste por deslocamento circular dentro de cada execução — preservando a estrutura espacial e quebrando apenas a relação temporal — produziu:

```text
observado_top10 = 39.17%
null_media      = 39.86%
null_mediana    = 39.58%
null_maximo     = 54.17%
p_perm          = 0.640636
```

Conclusão: **a pressão de bloqueio está associada à estrutura crítica, mas não demonstrou informação temporal adicional suficiente para servir como preditor online**. Não será desenvolvido, por enquanto, um estimador online de `phi` a partir desse sinal.

O papel de `phi` permanece conceitual: representar quanto uma espera local realmente vale para o makespan global. O resultado experimental que deve ser preservado é

```text
custo local de WAIT != impacto global no makespan
```

## 5. PREDICT — estado atual

A direção principal voltou para o método numérico.

`heat2d_predict` é uma variante diagnóstica baseada no arquivo `heat2d_common_predict.hpp`. Quando um halo não chegou e existem dois halos reais consecutivos anteriores, ela calcula

```text
Uhat^n = 2 U^(n-1) - U^(n-2)
```

mas ainda faz `MPI_Wait` e usa o halo real na solução. O objetivo é medir o erro real da extrapolação antes de permitir que PREDICT altere a solução.

A variante imprime:

```text
PREDICT_DIAG tests=... mean_linf_error=... max_linf_error=...
```

O job 625600 (`run_predict_diag.sbatch`) foi submetido depois da criação do backup completo usado para esta limpeza. Portanto, o resultado desse job **não está contido no backup de 17/09** e deve ser recuperado separadamente no SDumont II antes de remover o diretório antigo.

Próximo passo técnico: validar esse diagnóstico e, depois, incorporar o critério numérico de admissibilidade já derivado para PREDICT, mantendo separada a decisão de desempenho da decisão de erro numérico.

## 6. Nós excluídos

Os jobs 607590, 607591 e 607592 apresentaram tempos anômalos no conjunto físico `sdumont2nd[1011,1018,1023,1031]`. Um teste posterior excluindo esse conjunto voltou ao regime normal. Isso motivou a exclusão preventiva desses quatro nós nos experimentos controlados seguintes.

Não há evidência suficiente para afirmar que os nós tenham defeito físico; a causa pode envolver sistema, rede ou outra condição de execução.

## 7. Arquivos deliberadamente não versionados

A versão limpa não inclui:

- binários compilados;
- `results/` de jobs anteriores;
- `slurm-*.out`;
- arquivos agregados `trace_*.txt`, `waittrace_*.txt`, `control_*.txt`;
- backups intermediários `*.bak_*`;
- `submitted_beta_jobs.txt`;
- `analyze_job.sh` e `separar_resultados.sh`, que eram scripts auxiliares obsoletos.

Esses materiais continuam preservados no backup completo externo.
