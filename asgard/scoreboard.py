#!/usr/bin/env python3
"""asgard/scoreboard.py [--csv] [MODEL ...] - graded E2E scoreboard from /data/ai/*-task-*/summary.txt.

Grades (13 Sep 2026, per the owner's ranking):
  FAIL-infra           the run was compromised by the machine, not the model (battery marker from e2e-test.sh; a
                       resume/downtime is only a note - the result stands, as in results-t0.md)
  FAIL-task s/T (...)  the program failed s of T verifier checks; the failed check names say *how* it failed
                       ("spec-only" when every functional check passed and only a spec check - signature, nodeps,
                       vet, strict, nolibc - was missed)
  PASS s/T             all checks passed; the quality columns (turns, wall, tool errors, tests written, edge-case
                       and performance lines of the verifier) say *how good* the run was
The check bits are parsed from the VERDICT line, so runs graded before the verifiers printed "score=" are graded
the same way retroactively. Superseded attempts (*-task-MODEL.prev-*) are listed with the attempt marker.
Default output is a Markdown table (paste into results-*.md); --csv for machine use.
"""
import glob, os, re, sys

ROOT = os.environ.get('E2E_ROOT', '/data/ai')
TASKS = ['rust', 'go', 'c', 'asm']
TOTAL = {'rust': 5, 'go': 5, 'c': 5, 'asm': 4}
SPEC = {'signature', 'nodeps', 'vet', 'strict', 'nolibc'}
# verifier lines that describe quality beyond pass/fail, per task (regex -> short label)
QUALITY = {
    'rust': [(r'tests in source: (\d+)', 'tests={}'), (r'unsafe blocks: (\d+)', 'unsafe={}'),
             (r'round-trips: (\d+) ok, (\d+) failed', 'roundtrips={}ok/{}bad')],
    'go':   [(r'^tests?[^:]*: (.*)$', 'tests={}'), (r'6 MB input: (\S+.*)$', '6MB={}'),
             (r'comparisons?: (\d+) ok, (\d+) failed', 'cmp={}ok/{}bad')],
    'c':    [(r'assert\(\) uses: (\d+)', 'asserts={}'), (r'malloc/free calls in bignum.c: (\d+) / (\d+)', 'malloc/free={}/{}'),
             (r'^arithmetic: (\d+) lines ok', 'arith={}ok'), (r'^arithmetic: .*?(FAIL.*)$', 'arith={}'),
             (r'^malformed/blank lines: (ok|FAIL)', 'malformed={}'), (r'^empty input: (ok|FAIL)', 'empty={}')],
    'asm':  [(r'^vectors: (.*)$', 'vectors={}'), (r'^(?:error cases|errors): (.*)$', 'errors={}'),
             (r'^(?:exit statuses|exit codes): (.*)$', 'exit={}')],
}


def parse(path):
    s = open(path, errors='replace').read()
    head = s.split('\n', 1)[0]
    r = {'file': path}
    m = re.search(r'== e2e-test (\S+) (\S+)\s+(.*?)\s+qwen rc=(\S+)\s+wall=(\d+) s', head)
    if not m:
        return None
    r['model'], r['task'], r['date'], r['rc'], r['wall'] = m.group(1), m.group(2), m.group(3), m.group(4), int(m.group(5))
    m = re.search(r'resumes=(\d+) downtime=(\d+) s', head); r['resumes'], r['downtime'] = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    m = re.search(r'ac_drops=(\d+)', head); r['ac_drops'] = int(m.group(1)) if m else None
    r['battery'] = 'FAIL-infra' in head or 'ON BATTERY' in head
    m = re.search(r'result: (\S+) \| turns: (\d+) \| duration: (\d+) s \| tool calls: (\{.*?\}) \| tool errors: (\d+)', s)
    if m:
        r['agent'], r['turns'], r['tool_errors'] = m.group(1), int(m.group(2)), int(m.group(5))
        r['tool_calls'] = sum(int(x) for x in re.findall(r": (\d+)", m.group(4)))
    else:
        r['agent'], r['turns'], r['tool_errors'], r['tool_calls'] = '?', None, None, None
    m = re.search(r'generated: (\d+) in ([\d.]+) s \(([\d.]+) t/s aggregate; per-request tg min ([\d.]+) / max ([\d.]+)\)', s)
    r['gen'], r['tg'], r['tg_min'], r['tg_max'] = (int(m.group(1)), float(m.group(3)), float(m.group(4)), float(m.group(5))) if m else (None, None, None, None)
    m = re.search(r'prompt tokens: (\d+) in ([\d.]+) s \(([\d.]+) t/s aggregate\)', s); r['pp'] = float(m.group(3)) if m else None
    m = re.search(r'context depth per request: first (\d+), max (\d+)', s); r['depth_max'] = int(m.group(2)) if m else None
    m = re.search(r'^VERDICT: (PASS|FAIL)(?: \(([^)]*)\))?', s, re.M)
    r['verdict'] = m.group(1) if m else None
    bits = dict(re.findall(r'([\w+]+)=([01])', m.group(2))) if m and m.group(2) else {}
    r['bits'] = bits
    total = TOTAL.get(r['task'], len(bits) or 0)
    if r['verdict'] == 'PASS':
        r['score'], r['total'], r['failed'] = total, total, []
    elif r['verdict'] == 'FAIL':
        r['score'] = sum(int(v) for v in bits.values()) if bits else 0
        r['total'] = len(bits) if bits else total
        r['failed'] = [k for k, v in bits.items() if v == '0'] if bits else [m.group(2) or 'no verdict details']
    else:
        r['score'], r['total'], r['failed'] = None, total, []
    q = []
    for rx, label in QUALITY.get(r['task'], []):
        mm = re.search(rx, s, re.M)
        if mm:
            q.append(label.format(*[(g.strip()[:37] + '…') if len(g.strip()) > 38 else g.strip() for g in mm.groups()]))
    r['quality'] = q
    return r


def grade(r):
    if r['battery']:
        return 'FAIL-infra (on battery)'
    if r['verdict'] is None:
        if r.get('prev'):
            return 'no summary (attempt lost - freeze/kill; see results-t0.md)'
        return 'no verdict' + (' (running?)' if r['agent'] == '?' else '')
    if r['verdict'] == 'PASS':
        return f"PASS {r['score']}/{r['total']}"
    kind = 'spec-only' if r['failed'] and all(f in SPEC for f in r['failed']) else 'functional'
    return f"FAIL-task {r['score']}/{r['total']} ({kind}: {', '.join(r['failed'])})"


def notes(r):
    n = []
    if r['rc'] == '124':
        n.append('hit the wall-time cap')
    if r['resumes']:
        n.append(f"{r['resumes']} resume(s), {r['downtime']} s downtime")
    if r['ac_drops']:
        n.append(f"{r['ac_drops']} AC drop(s)")
    if r['agent'] not in ('success', '?'):
        n.append(f"agent said {r['agent']}")
    return n


def fmt_wall(w):
    return f"{w // 60} min" if w >= 600 else f"{w} s"


def main():
    csv = '--csv' in sys.argv
    models = [a for a in sys.argv[1:] if not a.startswith('--')]
    rows = []
    for d in sorted(glob.glob(f'{ROOT}/*-task-*')):
        base = os.path.basename(d)
        m = re.match(r'(\w+)-task-(.+?)(\.prev-(\S+))?$', base)
        if not m:
            continue
        task, model, prev = m.group(1), m.group(2), m.group(4)
        if models and model not in models:
            continue
        f = os.path.join(d, 'summary.txt')
        r = parse(f) if os.path.exists(f) else None
        if r is None:
            r = {'model': model, 'task': task, 'verdict': None, 'agent': '?', 'wall': 0, 'turns': None, 'tool_errors': None,
                 'tg': None, 'depth_max': None, 'quality': [], 'battery': False, 'rc': '', 'resumes': 0, 'downtime': 0,
                 'ac_drops': None, 'score': None, 'total': TOTAL.get(task, 0), 'failed': [], 'pp': None, 'tool_calls': None}
        r['prev'] = prev
        rows.append(r)
    order = {t: i for i, t in enumerate(TASKS)}
    rows.sort(key=lambda r: (r['model'], order.get(r['task'], 9), r['prev'] or ''))
    if csv:
        print('model,task,attempt,grade,score,total,wall_s,turns,tool_calls,tool_errors,tg_tps,pp_tps,depth_max,failed_checks,quality,notes')
        for r in rows:
            print(','.join(str(x) if x is not None else '' for x in [
                r['model'], r['task'], r['prev'] or 'final', grade(r).split(' (')[0], r['score'], r['total'], r['wall'], r['turns'],
                r['tool_calls'], r['tool_errors'], r['tg'], r['pp'], r['depth_max'], ' '.join(r['failed']),
                ' '.join(r['quality']).replace(',', ';'), '; '.join(notes(r)).replace(',', ';')]))
        return
    print('| model | task | grade | wall | turns / tool calls / errors | tg t/s (agg; min–max) | max depth | quality | notes |')
    print('|---|---|---|---|---|---|---|---|---|')
    for r in rows:
        name = r['model'] + (f" *(superseded attempt {r['prev']})*" if r['prev'] else '')
        tc = f"{r['turns']} / {r['tool_calls']} / {r['tool_errors']}" if r['turns'] is not None else '—'
        tg = f"{r['tg']} ({r['tg_min']}–{r['tg_max']})" if r.get('tg') else '—'
        depth = f"{r['depth_max'] // 1000}K" if r['depth_max'] else '—'
        g = grade(r)
        if g.startswith('PASS'):
            g = f"**{g}**"
        print(f"| {name} | {r['task']} | {g} | {fmt_wall(r['wall']) if r['wall'] else '—'} | {tc} | {tg} | {depth} | "
              f"{', '.join(r['quality']) or '—'} | {'; '.join(notes(r)) or '—'} |")


if __name__ == '__main__':
    main()
