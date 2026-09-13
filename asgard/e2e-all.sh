#!/bin/sh
# /data/local-ai/asgard/e2e-all.sh MODEL [TASKS...] - run the E2E coding tasks (default: rust go c asm, see
# e2e-tasks.sh) one after another against the RUNNING server, with a GAP (default 60 s) idle pause between tasks so
# each starts from a similar GPU temperature, then print a one-line-per-task summary table (wall, turns, tokens
# in/out, pp/tg t/s, max context depth, verdict). Full details: /data/ai/TASK-task-MODEL/summary.txt.
# Detached use: daemon -f -o ~/local-ai-runs/e2e-MODEL.log /data/local-ai/asgard/e2e-all.sh MODEL
d=$(dirname "$(realpath "$0")"); M=${1:-qwen35b}; shift; TASKS=${*:-rust go c asm}; GAP=${GAP:-60}
first=1
for T in $TASKS; do
  [ $first = 1 ] || sleep "$GAP"; first=0
  "$d/wait-ac.sh"; "$d/wait-no-verify.sh" 5400   # a task never starts on battery (wait-ac.sh) or during a model verification (PCH -> CPU turbo band off / cap); mid-task overlaps are noted in the report
  echo "=== $(date +%T) $M $T  pch=$(sysctl -n dev.pchtherm.0.temperature | cut -d. -f1) gpu=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader)C"
  "$d/e2e-test.sh" "$M" "$T" > /dev/null 2>&1
  grep -E "^== e2e-test|^requests:|^result:|^usage:|^VERDICT|^context depth|^speculative|^prompt batches" "/data/ai/$T-task-$M/summary.txt" | cut -c1-220
done
echo
echo "=== summary $M $(date '+%F %T')"
printf "%-5s %7s %6s %9s %8s %8s %7s %9s  %s\n" task wall_s turns tok_in tok_out pp_t/s tg_t/s ctx_max verdict
for T in $TASKS; do
  s=/data/ai/$T-task-$M/summary.txt; [ -f "$s" ] || { printf "%-5s  (no summary)\n" "$T"; continue; }
  wall=$(sed -n 's/.*wall=\([0-9]*\) s.*/\1/p' "$s" | head -1); turns=$(sed -n 's/.*turns: \([0-9]*\).*/\1/p' "$s" | head -1)
  tin=$(sed -n 's/^requests:.*prompt tokens: \([0-9]*\) in.*/\1/p' "$s"); pp=$(sed -n 's/^requests:.*(\([0-9]*\) t\/s aggregate) | generated.*/\1/p' "$s")
  tout=$(sed -n 's/^requests:.*generated: \([0-9]*\) in.*/\1/p' "$s"); tg=$(sed -n 's/^requests:.*generated: .* in [0-9.]* s (\([0-9.]*\) t\/s.*/\1/p' "$s")
  ctx=$(sed -n 's/^context depth.*max \([0-9]*\) tokens.*/\1/p' "$s"); v=$(grep '^VERDICT' "$s" | cut -c10-60)
  printf "%-5s %7s %6s %9s %8s %8s %7s %9s  %s\n" "$T" "${wall:--}" "${turns:--}" "${tin:--}" "${tout:--}" "${pp:--}" "${tg:--}" "${ctx:--}" "${v:--}"
done
