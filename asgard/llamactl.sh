#!/bin/sh
# /data/local-ai/asgard/llamactl.sh start [MODEL] | stop | restart [MODEL] | status - the llama service, in one place.
# /usr/local/etc/rc.d/llama is a stub that only calls this file (sudo service llama start|stop|restart|status), so during
# the research phase only this file (and start.sh / serve.sh / models.sh behind it) changes; it is never in the boot
# sequence (rc.d KEYWORD nostart). Always runs as SERVICE_USER: invoked as root it re-executes itself via su -l.
#   start [MODEL]  MODEL given (qwen35b = frozen T-1 winner; T0 candidates qwen35b-q4|kat-q4|qwen35b-q8; asgard/models.sh) -> asgard/start.sh MODEL with that model's
#                  defaults (NP=1, ctx 262144, per-model spec/cache-ram); knobs (NP= CTX= SPEC= NCMOE= IGPU_MOE= ...)
#                  pass through the environment when run as the user, e.g. NP=2 ./llamactl.sh start qwen35b
#                  no MODEL -> replay the last start, whoever made it (start.sh --last, ~/local-ai-runs/last-start.env),
#                  or DEFAULT_MODEL if nothing was ever started
#   stop           asgard/stop.sh (TERM, KILL after 30 s) - the pidfile's server or, without one, whatever llama-server
#                  listens on :18080 (a server started by hand with daemon -f ./serve.sh ... is found and stopped too)
#   restart [..]   stop, then start with the same rules (no MODEL = the same config again; a hand-started server is
#                  relaunched identically - argv/env/cwd from the kernel, asgard/unstick.sh restart)
#   status         pid, how it was started, /health, /props, /slots - metadata only (asgard/health.sh sends a real
#                  completion: never while a task runs, with NP=1 it would evict the task's cache)
SERVICE_USER=lgryglicki
DEFAULT_MODEL=qwen35b   # T-1 winner, 12 Sep 2026 (results-t1.md §5)
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
d=$(dirname "$(realpath "$0")"); MODE=${1:-status}; [ $# -gt 0 ] && shift
if [ "$(id -un)" != "$SERVICE_USER" ]; then
  [ "$(id -u)" = 0 ] || { echo "run as $SERVICE_USER or root"; exit 1; }
  exec su -l "$SERVICE_USER" -c "$(realpath "$0") $MODE $*"
fi
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; export LOCAL_AI_RUNS=$RUNS
u=http://10.253.254.1:18080; k=$(cat "$d/../key.secret" 2>/dev/null)
running() {   # sets p (pid) and how (start.sh | hand): the pidfile's live pid, else the llama-server listening on :18080
  p=$(cat "$RUNS/llama.pid" 2>/dev/null) && kill -0 "$p" 2>/dev/null && { how=start.sh; return 0; }
  p=$(sockstat -4l -p 18080 2>/dev/null | awk 'NR>1 && $2 ~ /^llama/ {print $3; exit}'); [ -n "$p" ] && { how=hand; return 0; }
  return 1
}
describe() {   # uses p how
  if [ "$how" = start.sh ]; then echo "pid $p via start.sh: $(tr '\n' ' ' < "$RUNS/last-start.env" 2>/dev/null)"
  else echo "pid $p (user $(ps -o user= -p "$p" | tr -d ' ')) started by hand, no pidfile - argv: $(procstat -c "$p" 2>/dev/null | awk 'NR>1{$1=$2="";print}' | tr -s ' ' | cut -c1-400)"; fi
}
start() {
  if running; then echo "already running: $(describe)"; return 0; fi
  if [ -n "${1:-}" ]; then exec "$d/start.sh" "$1"
  elif [ -f "$RUNS/last-start.env" ]; then exec "$d/start.sh" --last
  else exec "$d/start.sh" "$DEFAULT_MODEL"; fi
}
status() {
  if running; then echo "llama is running: $(describe)"
  else echo "llama is not running (no live pid in $RUNS/llama.pid, nothing listening on :18080)"; fi
  h=$(curl -s -m 5 "$u/health") || { echo "health: no answer on $u/health"; running; return; }
  echo "health: $h"
  { curl -s -m 5 -H "Authorization: Bearer $k" "$u/props"; echo; curl -s -m 5 -H "Authorization: Bearer $k" "$u/slots"; } | python3 -c '
import json, sys
lines = sys.stdin.read().split("\n")
try:
    p = json.loads(lines[0]); g = p.get("default_generation_settings", {})
    print("model: %s | %s | slots: %s x %s ctx" % (p.get("model_alias"), p.get("model_path", "").rsplit("/", 1)[-1], p.get("total_slots"), g.get("n_ctx")))
except Exception as e:
    print("props: unreadable (%s)" % e)
try:
    for s in json.loads(lines[1]):
        print("slot %s: %s" % (s["id"], "PROCESSING task %s, prompt %s tok (cached %s), speculative %s" % (s.get("id_task"), s.get("n_prompt_tokens"), s.get("n_prompt_tokens_cache"), s.get("speculative")) if s.get("is_processing") else "idle"))
except Exception as e:
    print("slots: unreadable (%s)" % e)'
  running
}
case $MODE in
  start) start "$@" ;;
  stop) exec "$d/stop.sh" ;;
  restart) if [ -z "${1:-}" ] && running && [ "$how" = hand ]; then exec "$d/unstick.sh" restart; fi
           "$d/stop.sh"; start "$@" ;;
  status) status ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
