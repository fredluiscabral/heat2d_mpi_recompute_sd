#!/usr/bin/env python3
import argparse, glob, os, re, statistics
from collections import defaultdict

p=argparse.ArgumentParser()
p.add_argument('path', nargs='?', default='results/raw')
p.add_argument('--exclude-warmup', action='store_true')
a=p.parse_args()

files=glob.glob(os.path.join(a.path,'*.txt')) if os.path.isdir(a.path) else [a.path]
rows=[]
for fn in files:
    if a.exclude_warmup and 'warmup' in os.path.basename(fn):
        continue
    try:
        text=open(fn,errors='replace').read().splitlines()
    except OSError:
        continue
    for line in text:
        if not line.startswith('RESULT '):
            continue
        d={'file':os.path.basename(fn)}
        for tok in line.split()[1:]:
            if '=' not in tok: continue
            k,v=tok.split('=',1)
            d[k]=v
        for k in ['makespan_s','wait_sum_s','recompute_sum_s','cleanup_wait_sum_s','late_validation_max','l2_error','max_error']:
            if k in d:
                try: d[k]=float(d[k])
                except ValueError: pass
        for k in ['ranks','nodes','ppn','nx','ny','steps','reads','waits','recomputes','support_unavailable','cleanup_waits','inject_us','inject_every','inject_node','inject_local_rank']:
            if k in d:
                try: d[k]=int(d[k])
                except ValueError: pass
        rows.append(d)

if not rows:
    print('Nenhum RESULT encontrado.')
    raise SystemExit(1)

key_fields=['variant','policy','ranks','nodes','ppn','nx','ny','steps','inject_us','inject_every','inject_node','inject_local_rank']
groups=defaultdict(list)
for r in rows:
    key=tuple(r.get(k) for k in key_fields)
    groups[key].append(r)

print('\nMEDIANAS')
print('variant policy ranks nx ny steps inject_us n median_s min_s max_s rec_med waits_med support_unavail_med cleanup_wait_s_med late_diff_max')
summaries=[]
for key,rs in sorted(groups.items(), key=lambda kv: str(kv[0])):
    times=[r['makespan_s'] for r in rs]
    rec=[r.get('recomputes',0) for r in rs]
    waits=[r.get('waits',0) for r in rs]
    sup=[r.get('support_unavailable',0) for r in rs]
    clean=[r.get('cleanup_wait_sum_s',0.0) for r in rs]
    late=max(r.get('late_validation_max',0.0) for r in rs)
    s=dict(zip(key_fields,key))
    s.update(n=len(rs), median=statistics.median(times), min=min(times), max=max(times),
             rec=statistics.median(rec), waits=statistics.median(waits), sup=statistics.median(sup),
             clean=statistics.median(clean), late=late)
    summaries.append(s)
    print(f"{s['variant']} {s['policy']} {s['ranks']} {s['nx']} {s['ny']} {s['steps']} {s['inject_us']} "
          f"{s['n']} {s['median']:.9f} {s['min']:.9f} {s['max']:.9f} {s['rec']} {s['waits']} {s['sup']} {s['clean']:.6e} {s['late']:.3e}")

print('\nCOMPARAÇÕES (mesma configuração)')
base={}; control={}
for s in summaries:
    common=(s['ranks'],s['nodes'],s['ppn'],s['nx'],s['ny'],s['steps'],s['inject_us'],s['inject_every'],s['inject_node'],s['inject_local_rank'])
    if s['variant']=='naive': base[common]=s
    elif s['variant']=='support_wait': control[common]=s
for s in summaries:
    common=(s['ranks'],s['nodes'],s['ppn'],s['nx'],s['ny'],s['steps'],s['inject_us'],s['inject_every'],s['inject_node'],s['inject_local_rank'])
    if s['variant']=='support_wait' and common in base:
        b=base[common]
        ratio=s['median']/b['median']
        print(f"SUPPORT overhead ranks={s['ranks']} nx={s['nx']} ny={s['ny']} inject_us={s['inject_us']}: "
              f"naive={b['median']:.9f}s support_wait={s['median']:.9f}s ratio={ratio:.6f} ({(ratio-1)*100:+.3f}%)")
    if s['variant']!='recompute':
        continue
    if common in base:
        b=base[common]
        speed=b['median']/s['median']
        pct=(speed-1.0)*100.0
        print(f"TOTAL policy={s['policy']} ranks={s['ranks']} nx={s['nx']} ny={s['ny']} inject_us={s['inject_us']}: "
              f"naive={b['median']:.9f}s recompute={s['median']:.9f}s speedup={speed:.6f} ({pct:+.3f}%)")
    if common in control:
        c=control[common]
        speed=c['median']/s['median']
        print(f"MECHANISM policy={s['policy']} support_wait={c['median']:.9f}s recompute={s['median']:.9f}s "
              f"speedup={speed:.6f} ({(speed-1)*100:+.3f}%)")
