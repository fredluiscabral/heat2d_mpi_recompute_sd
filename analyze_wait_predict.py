#!/usr/bin/env python3

import bisect
import random
import re
import statistics
import sys

if len(sys.argv) != 2:
    print(f"Uso: {sys.argv[0]} waittrace_*.txt")
    sys.exit(1)

fname = sys.argv[1]
EPS = 1.0e-30

re_trace = re.compile(
    r'^TRACE step=(\d+) '
    r'critical_world_rank=(\d+) '
    r'critical_node=(\d+) '
    r'critical_local_rank=(\d+)'
)

re_wait = re.compile(
    r'^WAITBIN step=(\d+) '
    r'world_rank=(\d+) '
    r'node=(\d+) '
    r'local_rank=(\d+) '
    r'direction=(up|down) '
    r'waits=(\d+) '
    r'wait_sum_s=([0-9.eE+-]+) '
    r'wait_max_s=([0-9.eE+-]+)'
)

runs = []
cur_trace = {}
cur_wait = {}

with open(fname, "r", errors="replace") as f:
    for line in f:
        line = line.strip()

        m = re_trace.match(line)
        if m:
            step = int(m.group(1))
            cur_trace[step] = {
                "world": int(m.group(2)),
                "node": int(m.group(3)),
                "local": int(m.group(4)),
            }
            continue

        m = re_wait.match(line)
        if m:
            step = int(m.group(1))
            world = int(m.group(2))
            node = int(m.group(3))
            local = int(m.group(4))
            direction = m.group(5)
            wait_sum = float(m.group(7))
            cur_wait.setdefault(step, []).append(
                (world, node, local, direction, wait_sum)
            )
            continue

        if line.startswith("RESULT "):
            meta = {}
            for tok in line.split()[1:]:
                if "=" not in tok:
                    continue
                k, v = tok.split("=", 1)
                if k in ("ranks", "nodes", "ppn"):
                    meta[k] = int(v)
            if cur_trace:
                runs.append((cur_trace, cur_wait, meta))
            cur_trace = {}
            cur_wait = {}

if cur_trace:
    # Fallback para arquivo truncado sem RESULT final.
    max_node = max((e[1] for ev in cur_wait.values() for e in ev), default=-1)
    max_local = max((e[2] for ev in cur_wait.values() for e in ev), default=-1)
    nodes = max_node + 1
    ppn = max_local + 1
    runs.append((cur_trace, cur_wait, {
        "nodes": nodes,
        "ppn": ppn,
        "ranks": nodes * ppn,
    }))

if not runs:
    raise SystemExit("Nenhuma execução TRACE/WAITBIN encontrada.")


def metrics_for_window(events, meta):
    nodes = meta["nodes"]
    ppn = meta["ppn"]
    nranks = meta["ranks"]

    incoming = [0.0] * nranks
    outgoing = [0.0] * nranks

    for world, node, local, direction, w in events:
        outgoing[world] += w

        producer_node = node - 1 if direction == "up" else node + 1
        if 0 <= producer_node < nodes:
            producer_world = producer_node * ppn + local
            if 0 <= producer_world < nranks:
                incoming[producer_world] += w

    pressure = [incoming[r] - outgoing[r] for r in range(nranks)]
    ratio = [
        incoming[r] / (incoming[r] + outgoing[r] + EPS)
        for r in range(nranks)
    ]

    return {"I": incoming, "P": pressure, "R": ratio}


def percentile(values, idx):
    x = values[idx]
    less = sum(v < x for v in values)
    equal = sum(v == x for v in values)
    return 100.0 * (less + 0.5 * equal) / len(values)


def top10_mask(values):
    sv = sorted(values)
    n = len(values)
    mask = []
    for x in values:
        lo = bisect.bisect_left(sv, x)
        hi = bisect.bisect_right(sv, x)
        pct = 100.0 * (lo + 0.5 * (hi - lo)) / n
        mask.append(pct >= 90.0)
    return mask


stats = {
    "all": {"I": [], "P": [], "R": []},
    "rank_change": {"I": [], "P": [], "R": []},
    "column_change": {"I": [], "P": [], "R": []},
}
far = {"I": [], "P": []}

n_pairs = 0
same_rank = 0
same_column = 0

for traces, waits, meta in runs:
    steps = sorted(traces)
    for i in range(len(steps) - 1):
        s0, s1 = steps[i], steps[i + 1]
        m = metrics_for_window(waits.get(s0, []), meta)
        current = traces[s0]
        future = traces[s1]

        n_pairs += 1
        rank_same = current["world"] == future["world"]
        col_same = current["local"] == future["local"]
        same_rank += int(rank_same)
        same_column += int(col_same)

        for name in ("I", "P", "R"):
            pct = percentile(m[name], future["world"])
            stats["all"][name].append(pct)
            if not rank_same:
                stats["rank_change"][name].append(pct)
            if not col_same:
                stats["column_change"][name].append(pct)

        if abs(future["local"] - current["local"]) > 10:
            for name in ("I", "P"):
                far[name].append(percentile(m[name], future["world"]))


def show(title, data, names=("I", "P", "R")):
    print()
    print(title)
    for name in names:
        vals = data[name]
        if not vals:
            print(f"  {name}: sem casos")
            continue
        top10 = sum(v >= 90.0 for v in vals)
        print(
            f"  {name}: N={len(vals)} "
            f"mean_pct={statistics.mean(vals):.2f} "
            f"median_pct={statistics.median(vals):.2f} "
            f"top10={top10}/{len(vals)} "
            f"({100.0 * top10 / len(vals):.1f}%)"
        )


print(f"runs={len(runs)}")
print(f"transicoes={n_pairs}")
print(f"persistencia_rank={same_rank}/{n_pairs} ({100.0*same_rank/n_pairs:.1f}%)")
print(f"persistencia_coluna={same_column}/{n_pairs} ({100.0*same_column/n_pairs:.1f}%)")

show("TODAS AS TRANSICOES k -> k+1", stats["all"])
show("SOMENTE QUANDO MUDA O RANK CRITICO", stats["rank_change"])
show("SOMENTE QUANDO MUDA A COLUNA CRITICA", stats["column_change"])
show("SALTOS DE COLUNA > 10", far, names=("I", "P"))

# Teste nulo que preserva a estrutura espacial de cada run e quebra apenas
# o alinhamento temporal entre P(k) e o crítico de k+1. Este teste é essencial:
# comparar o top-10 observado diretamente com 10% produz um baseline enganoso.
prepared = []
obs_hits = 0
obs_total = 0

for traces, waits, meta in runs:
    steps = sorted(traces)
    top = {}
    for s in steps:
        P = metrics_for_window(waits.get(s, []), meta)["P"]
        top[s] = top10_mask(P)

    cases = []
    for i in range(len(steps) - 1):
        s0, s1 = steps[i], steps[i + 1]
        if abs(traces[s1]["local"] - traces[s0]["local"]) <= 10:
            continue
        future = traces[s1]["world"]
        cases.append((i, future))
        obs_hits += int(top[s0][future])
        obs_total += 1

    shift_hits = []
    for shift in range(1, len(steps)):
        h = 0
        for i, future in cases:
            shifted_step = steps[(i + shift) % len(steps)]
            h += int(top[shifted_step][future])
        shift_hits.append(h)
    prepared.append((len(cases), shift_hits))

if obs_total:
    obs = obs_hits / obs_total
    rng = random.Random(12345)
    nperm = 10000
    null = []
    for _ in range(nperm):
        hits = 0
        total = 0
        for nc, shift_hits in prepared:
            if not shift_hits:
                continue
            hits += rng.choice(shift_hits)
            total += nc
        null.append(hits / total if total else 0.0)

    p_perm = (1 + sum(x >= obs for x in null)) / (nperm + 1)

    print()
    print("PERMUTACAO CIRCULAR: P(k) -> critico(k+1), apenas saltos > 10")
    print(f"  observado_top10={100*obs:.2f}%")
    print(f"  null_media={100*statistics.mean(null):.2f}%")
    print(f"  null_mediana={100*statistics.median(null):.2f}%")
    print(f"  null_maximo={100*max(null):.2f}%")
    print(f"  p_perm={p_perm:.6f}")
