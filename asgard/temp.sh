#!/bin/sh
# temp.sh — how hot is this machine right now?  usage: ./temp.sh [-w SECONDS]  (-w = refresh loop)
# Reads core/PCH/NVMe temps, package power, frequency caps, GPU power state and the
# thermal-watchdog status. Needs root for MSR/NVMe access -> re-execs itself via sudo.
[ "$(id -u)" -eq 0 ] || exec sudo -- /bin/sh "$(realpath "$0")" "$@"
WATCH=0; [ "${1:-}" = -w ] && WATCH=${2:-5}
kldload -n cpuctl coretemp 2>/dev/null
NCPU=$(sysctl -n hw.ncpu)
R='\033[1;31m'; Y='\033[1;33m'; G='\033[1;32m'; B='\033[1;34m'; N='\033[0m'
c() { # value warn crit -> colored "NNC"
	awk -v v="$1" -v w="$2" -v k="$3" -v R="$R" -v Y="$Y" -v G="$G" -v N="$N" \
	    'BEGIN{ col = (v+0 >= k) ? R : (v+0 >= w) ? Y : G; printf "%s%3dC%s", col, v, N }'
}
msr() { cpucontrol -m "$1" /dev/cpuctl0 2>/dev/null | awk '{sub(/^0x/,"",$4); print $3 $4}'; }
dstate() { # PCI power state (PMCSR bits 1:0) of a device: "D0".."D3", "?" without a PM capability
	local reg; reg=$(pciconf -lc "$1" 2>/dev/null | sed -n 's/.*cap 01\[\([0-9a-f]*\)\].*/\1/p' | head -1)
	[ -n "$reg" ] && printf 'D%d' $(( 0x$(pciconf -rh "$1" "$(printf '0x%x' $(( 0x$reg + 4 )))" | tr -d ' ') & 3 )) || printf '?'
}
DBG=/var/run/lindebugfs
i915_dbg() { # i915 debugfs dir (mounts lindebugfs on demand); empty when i915kms is not loaded
	[ -d "$DBG/dri" ] || { mkdir -p "$DBG" && mount -t lindebugfs lindebugfs "$DBG" 2>/dev/null; }
	local n; n=$(grep -ls '^i915' "$DBG"/dri/*/name 2>/dev/null | head -1); [ -n "$n" ] && echo "${n%/name}"
}
rc6_us() { [ -n "$1" ] && awk '/^RC6 residency since boot/{gsub(/[()]/,""); print $(NF-1)}' "$1/gt0/drpc" 2>/dev/null; }
# gpu_pin CLIENT -> "boost-lock: ..." — is the dGPU pinned? (2026-09-14, local-ai/asgard/results-t1.md §6.2; refined 15 Sep):
# after an AC "acpi_acad0: Off Line" blip (the adapter trips on a partial-offload prefill ramp: 9 of ~11 service starts so far,
# 15 Sep 15:14:49 was a 7 s blip on the T2 soft-start) the Dell EC drives the GPU's hardware power-brake pin until a COLD
# power-off (shutdown -p, not a reboot). The brake is DUTY-CYCLED, not a clock latch: 15 Sep the "HW Power Braking" counter
# grew 1069 s in a 1500 s client session (71 %), most samples sat at the 1035 MHz base clock / P2 / <=57 W, yet 5 of ~40
# telemetry samples showed 1440-1875 MHz boosts — so a single SM > 1035 MHz sample does NOT prove "not pinned". Effect:
# T1 tg 16 t/s instead of 61; T2 (flashnext) 82K-token prefill 135 -> 44 t/s, 4096-token ramp step 260 -> 98 t/s (3x slower).
# Signals: (1) AC drops since the last ---<<BOOT>>--- marker in /var/log/messages (works at idle; a cold power-off starts a
# new boot section); (2) with a client attached, nvidia-smi's "HW Power Braking" counter: > 0 = the brake bit while this
# client's session was running (definitive), sampled twice ~1 s apart so "active now" (still growing) is separated from
# "asserted earlier this session". The counter resets on RM re-init and only counts while the GPU asks for more than the
# braked clock, so a session that STARTS pinned keeps it at 0 (the driver then caps at 1035 and no boost is ever seen) and an
# idle GPU with no client is unprobeable (1035 MHz P0 after the wake-up in both states) -> then the AC-drop count decides.
# "not pinned" is only claimed when the counter reads 0 AND a boost > 1035 MHz was seen under load.
gpu_pin() {
	local n last brake brake2 client sm util q age duty now
	client=$1
	set -- $(awk '/---<<BOOT>>---/{n=0; last=""} /acpi_acad0: Off Line/{n++; last=$3} END{printf "%d %s\n", n, last}' /var/log/messages 2>/dev/null)
	n=${1:-0}; last=${2:-}; brake=; brake2=; sm=0; util=0; age=; duty=; now=
	if [ -n "$client" ]; then   # cheap while a client keeps the GPU initialised: 3 samples, keep the max SM clock and max util
		brake=$(/usr/local/bin/nvidia-smi -q -d PERFORMANCE 2>/dev/null | awk -F': *' '/HW Power Braking/{printf "%d", $2/1000000}')
		for q in 1 2 3; do
			set -- $(/usr/local/bin/nvidia-smi --query-gpu=clocks.sm,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ',')
			[ "${1:-0}" -gt "$sm" ] 2>/dev/null && sm=$1; [ "${2:-0}" -gt "$util" ] 2>/dev/null && util=$2; sleep 0.3
		done
		if [ -n "$brake" ] && [ "$brake" -gt 0 ]; then   # second read: is the brake asserted right now (counter still growing)?
			brake2=$(/usr/local/bin/nvidia-smi -q -d PERFORMANCE 2>/dev/null | awk -F': *' '/HW Power Braking/{printf "%d", $2/1000000}')
			[ -n "$brake2" ] && { [ "$brake2" -gt "$brake" ] && now="asserted right now" || now="not asserted at this instant"; }
			age=$(ps -o etimes= -p "$(pgrep -x "$client" 2>/dev/null | head -1)" 2>/dev/null | tr -d ' ')
			[ -n "$age" ] && [ "$age" -gt 0 ] 2>/dev/null && duty=$(( brake * 100 / age ))
		fi
	fi
	if [ -n "$brake" ] && [ "$brake" -gt 0 ]; then
		printf "boost-lock: ${R}PINNED${N} (EC power-brake %s s in this %s session%s%s; AC dropped %sx this boot, last %s; max SM %s MHz seen — brief boosts above 1035 happen while pinned; only a cold power-off clears it)" \
		    "$brake" "$client" "${age:+ of $age s}" "${duty:+ = $duty % duty${now:+, $now}}" "$n" "${last:-?}" "$sm"
	elif [ -n "$client" ] && [ "$brake" = 0 ] && [ "$sm" -gt 1035 ]; then
		printf "boost-lock: ${G}none${N} (brake counter 0 and boost %s MHz seen under load%s)" "$sm" "$([ "$n" -gt 0 ] && printf ' — despite %sx AC drop this boot, last %s' "$n" "$last")"
	elif [ "$n" -gt 0 ]; then
		if [ -n "$client" ] && [ "$sm" -gt 1035 ]; then printf "boost-lock: ${R}probably PINNED${N} (AC dropped %sx this boot, last %s -> EC power-brake; boost %s MHz seen but the brake counter is unreadable (nvidia-smi -q failed) and boosts above 1035 do happen while pinned; only a cold power-off clears it)" "$n" "$last" "$sm"
		elif [ -n "$client" ]; then printf "boost-lock: ${R}PINNED${N} (AC dropped %sx this boot, last %s -> EC power-brake; SM %s MHz at util %s %% now (%s); only a cold power-off clears it)" "$n" "$last" "$sm" "$util" "$([ "$brake" = 0 ] && echo 'brake counter 0: session started pinned, driver caps at 1035' || echo 'brake counter unreadable')"
		else printf "boost-lock: ${R}PINNED${N} (AC dropped %sx this boot, last %s -> EC power-brake, SM <= 1035 MHz under load; idle GPU cannot be probed; only a cold power-off clears it)" "$n" "$last"; fi
	elif [ -n "$client" ] && [ "$util" -ge 50 ]; then
		printf "boost-lock: ${Y}unclear${N} (no AC drop this boot, brake counter %s, but SM %s MHz at util %s %% — throttled? see clock-limit reasons below)" "${brake:-unreadable}" "$sm" "$util"
	elif [ -n "$client" ]; then printf "boost-lock: ${G}none${N} (no AC drop this boot, brake counter %s; client attached, GPU mostly idle in this sample — SM %s MHz at util %s %%)" "${brake:-unreadable}" "$sm" "$util"
	else printf "boost-lock: ${G}none${N} (no AC drop this boot; idle GPU, not probed)"; fi
}
snapshot() {
	local i cores e1 e2 g1 g2 r1 r2 u dri pkgt gw busy gem v caps pch n t nv lim cur
	cores=$(i=0; while [ $i -lt $NCPU ]; do sysctl -n dev.cpu.$i.temperature; i=$((i+1)); done | tr -d C | cut -d. -f1)
	dri=$(i915_dbg); u=$(( ( $(msr 0x606) >> 8 ) & 0x1f ))
	# one 1 s window for package energy (MSR 0x611), graphics-domain energy (MSR 0x641, iGPU) and RC6 residency
	e1=$(( $(msr 0x611) & 0xffffffff )); g1=$(( $(msr 0x641) & 0xffffffff )); r1=$(rc6_us "$dri"); sleep 1
	r2=$(rc6_us "$dri"); g2=$(( $(msr 0x641) & 0xffffffff )); e2=$(( $(msr 0x611) & 0xffffffff ))
	[ $e2 -lt $e1 ] && e2=$(( e2 + 4294967296 )); [ $g2 -lt $g1 ] && g2=$(( g2 + 4294967296 ))
	printf "${B}== %s thermal snapshot  %s  up %s ==${N}\n" "$(hostname -s)" "$(date '+%F %T')" "$(uptime | sed 's/.*up \([^,]*,[^,]*\),.*/\1/')"
	v=$(msr 0x1a0); caps=$(msr 0x774)
	printf "CPU   %s\n" "$(sysctl -n hw.model | sed 's/  */ /g')"
	printf "      turbo %s | HWP cap %d MHz | EPP %s | idle %s | Tjmax %s, throttle at %sC (TCC offset %d) | pkg %s W\n" \
	    "$([ $(( (v >> 38) & 1 )) -eq 1 ] && echo OFF || echo ON)" $(( ((caps >> 8) & 0xff) * 100 )) "$(sysctl -n dev.hwpstate_intel.0.epp)" \
	    "$(sysctl -n hw.acpi.cpu.cx_lowest)" "$(sysctl -n dev.cpu.0.coretemp.tjmax)" \
	    $(( (( $(msr 0x1a2) >> 16) & 0xff) - (( $(msr 0x1a2) >> 24) & 0x3f) )) $(( ( $(msr 0x1a2) >> 24) & 0x3f )) \
	    "$(awk -v d=$(( e2 - e1 )) -v u=$u 'BEGIN{printf "%.1f", d / (2^u)}')"
	printf "      cores max %s avg %s  freq %s MHz  throttle_log %s\n      per core:" \
	    "$(c "$(echo "$cores" | sort -n | tail -1)" 75 90)" "$(c "$(echo "$cores" | awk '{s+=$1} END{printf "%d", s/NR}')" 75 90)" \
	    "$(sysctl -n dev.cpu.0.freq)" "$(i=0; while [ $i -lt $NCPU ]; do sysctl -n dev.cpu.$i.coretemp.throttle_log; i=$((i+1)); done | sort -u | tail -1)"
	for t in $cores; do printf ' %s' "$(c $t 75 90)"; done; echo
	pch=$(sysctl -n dev.pchtherm.0.temperature 2>/dev/null | cut -d. -f1)
	# pmtemp = PCH "hot" power-management threshold; t0/t1/t2temp = hardware link (DMI/PCIe/NVMe) throttle levels, BIOS-set, read-only
	printf "PCH   %s  (pm threshold %s, hw link throttle T0/T1/T2 %s/%s/%s, catastrophic %s)\n" "$(c "${pch:-0}" 80 95)" \
	    "$(sysctl -n dev.pchtherm.0.pmtemp 2>/dev/null)" "$(sysctl -n dev.pchtherm.0.t0temp 2>/dev/null)" "$(sysctl -n dev.pchtherm.0.t1temp 2>/dev/null)" \
	    "$(sysctl -n dev.pchtherm.0.t2temp 2>/dev/null)" "$(sysctl -n dev.pchtherm.0.ctt 2>/dev/null)"
	printf "NVMe "
	for n in $(nvmecontrol devlist 2>/dev/null | awk '/^ *nvme[0-9]+:/{sub(":","",$1); print $1}'); do
		t=$(nvmecontrol logpage -p 2 "$n" 2>/dev/null | awk -F'[ ,]+' '/^Temperature:/{print $2-273; exit}')
		v=$(nvmecontrol admin-passthru --opcode=0x0a --cdw10=0x10 "$n" 2>/dev/null | awk '{print $NF}')
		printf ' %s %s (thr %d/%d, APST %s)' "$n" "$(c "${t:-0}" 60 75)" $(( (v >> 16) - 273 )) $(( (v & 0xffff) - 273 )) \
		    "$([ $(( $(nvmecontrol admin-passthru --opcode=0x0a --cdw10=0x0c "$n" 2>/dev/null | awk '{print $NF}') & 1 )) -eq 1 ] && echo on || echo off)"
	done; echo
	# iGPU: on the CPU die (package thermal sensor, MSR 0x1b1), powered from the RAPL graphics domain, no VRAM (GEM in shared RAM)
	pkgt=$(( (( $(msr 0x1a2) >> 16) & 0xff) - (( $(msr 0x1b1) >> 16) & 0x7f) ))
	gw=$(awk -v d=$(( g2 - g1 )) -v u=$u 'BEGIN{printf "%.1f", d / (2^u)}')
	printf "iGPU  Intel UHD Graphics P630 (pci0:0:2:0): %s%s\n" "$(dstate pci0:0:2:0)" "$(kldstat -q -n i915kms.ko && echo ', i915kms' || echo ', i915kms NOT loaded')"
	if [ -n "$dri" ] && [ -n "$r1" ] && [ -n "$r2" ]; then
		set -- $(awk -F': *' '/^Actual freq/{a=$2+0} /^Current freq/{c=$2+0} /^Min freq/{mn=$2+0} /^Max freq/{mx=$2+0} END{print a, c, mn, mx}' "$dri/i915_frequency_info")
		busy=$(awk -v a="$r1" -v b="$r2" 'BEGIN{p = 100 - (b - a) / 10000; if (p < 0) p = 0; if (p > 100) p = 100; printf "%.1f", p}')
		gem=$(awk '/objects,/{printf "%.1f", $(NF-1) / 1048576; exit}' "$dri/i915_gem_objects")
		printf "      i915: die %s (CPU package sensor), %s W (RAPL gfx), freq act %s MHz (cur %s, range %s-%s), busy %s %% (from RC6 residency), gem %s MiB (shared RAM, no VRAM)\n" \
		    "$(c $pkgt 75 90)" "$gw" "$1" "$2" "$3" "$4" "$busy" "${gem:-?}"
	else
		printf "      i915: die %s (CPU package sensor), %s W (RAPL gfx) — freq/busy/gem need i915kms + lindebugfs\n" "$(c $pkgt 75 90)" "$gw"
	fi
	cur=$(dstate pci0:1:0:0)
	nv=$(fstat 2>/dev/null | awk '$5=="/dev" && $8=="nvidia0" && $2!="nvidia-smi"{print $2; exit}')
	printf "GPU   NVIDIA Quadro RTX 5000 (pci0:1:0:0): %s%s | %s\n" "$cur" "$([ "$cur" = D3 ] && echo ' (powered down, no driver)')" "$(gpu_pin "$nv")"
	if kldstat -q -n nvidia.ko && [ -x /usr/local/bin/nvidia-smi ]; then
		set -- $(/usr/local/bin/nvidia-smi --query-gpu=temperature.gpu,power.draw,pstate,utilization.gpu,memory.used,memory.total,clocks.sm,clocks.mem,clocks.max.sm,clocks.max.mem --format=csv,noheader,nounits 2>&1 | head -1 | tr -d ',')
		case "${1:-}" in
		''|*[!0-9]*) printf "      nvidia-driver: ${R}nvidia-smi error:${N} %s (reload: kldunload nvidia-modeset; kldload nvidia-modeset)\n" "$*";;
		*) lim=$(/usr/local/bin/nvidia-smi -q -d TEMPERATURE 2>/dev/null | awk -F': *' '/GPU Target Temperature/{t=$2+0} /GPU Slowdown Temp/{s=$2+0} END{print (t ? t : 87), (s ? s : 97)}')
		   printf "      nvidia-driver: %s (throttles at %sC, slowdown %sC), %s W, %s, util %s %%, vram used %s / total %s MiB%s\n" \
		       "$(c "$1" 75 "${lim%% *}")" "${lim%% *}" "${lim##* }" "$2" "$3" "$4" "$5" "$6" \
		       "$([ -n "$nv" ] && printf ', client: %s' "$nv" || printf ', no client (this query woke the GPU: RM re-init at P0; real idle draw is lower)')"
		   # clocks: healthy under load 1830-2100 MHz SM (P0, boost); 1035 MHz = the base/default clock -> either idle-woken by this query
		   # (no client) or boost-locked (12 Sep 23:10 AC drop: stuck at 1035 MHz P2/P3 under load, 15 t/s instead of 58, only a cold power-off cleared it)
		   # -> the verdict is on the GPU line above (gpu_pin); "hw-power-brake" hardly ever shows in the reasons list even when pinned (the counter does)
		   why=$(/usr/local/bin/nvidia-smi --query-gpu=clocks_event_reasons.gpu_idle,clocks_event_reasons.applications_clocks_setting,clocks_event_reasons.sw_power_cap,clocks_event_reasons.hw_slowdown,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.hw_power_brake_slowdown,clocks_event_reasons.sw_thermal_slowdown --format=csv,noheader 2>/dev/null \
		       | awk -F', *' '{n[1]="idle"; n[2]="app-clocks"; n[3]="sw-power-cap"; n[4]="hw-slowdown"; n[5]="hw-thermal"; n[6]="hw-power-brake"; n[7]="sw-thermal"
		                       for (i = 1; i <= NF; i++) if ($i == "Active") s = s (s ? "," : "") n[i]; print (s ? s : "none")}')
		   printf "      clocks: SM %s MHz (max %s), mem %s MHz (max %s), %s, clock-limit reasons: %s%s\n" "$7" "$9" "$8" "${10}" "$3" "${why:-?}" \
		       "$([ -n "$nv" ] || printf ' [no client: 1035 MHz P0 here is the wake-up default, not a measurement]')";;
		esac
	fi
	printf "ACPI  tz0 %s (dummy zone, _CRT %s) | AC %s | battery %s | fans: EC-controlled, not readable on FreeBSD\n" \
	    "$(sysctl -n hw.acpi.thermal.tz0.temperature)" "$(sysctl -n hw.acpi.thermal.tz0._CRT)" \
	    "$([ "$(sysctl -n hw.acpi.acline)" = 1 ] && echo online || echo OFFLINE)" "$(acpiconf -i 0 2>/dev/null | awk -F':[ \t]*' '/Remaining capacity/{c=$2} /^State/{s=$2} END{print c, s}')"
	if [ -r /var/run/thermal_watchdog.pid ] && kill -0 "$(cat /var/run/thermal_watchdog.pid)" 2>/dev/null; then
		printf "WDOG  ${G}running${N} (cap %s MHz) last: %s\n" "$(( $(cat /var/run/thermal-policy.ratio 2>/dev/null || echo 0) * 100 ))" "$(tail -1 /var/log/thermal.log 2>/dev/null)"
	else printf "WDOG  ${R}NOT RUNNING${N} — service thermal_watchdog start\n"; fi
}
if [ "$WATCH" -gt 0 ]; then while :; do clear; snapshot; sleep "$WATCH"; done; else snapshot; fi
