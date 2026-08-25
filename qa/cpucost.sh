#!/bin/bash
# Cumulative-CPU-time delta for a pid, over a wall-clock window.
# `ps %cpu` is a decaying average and is useless here; this is the real thing.
#
#   usage: cpucost.sh <pid> <seconds> [label]
#
# Prints: label  cpu_delta_s  wall_s  pct_of_one_core

pid="$1"; secs="${2:-20}"; label="${3:-}"

# ps -o time= gives [dd-]hh:mm:ss.ss (cumulative user+sys). Parse to seconds.
cputime() {
  ps -o time= -p "$1" 2>/dev/null | tr -d ' ' | awk -F: '
    { n=NF; s=0; m=1
      for (i=n; i>=1; i--) { split($i, a, "-"); v=a[length(a)]
        if (length(a)>1) { s += a[1]*86400 }
        s += v*m; m*=60 }
      printf "%.2f", s }'
}

# Sub-second resolution wall clock without depending on GNU date.
wall() { python3 -c 'import time;print(f"{time.time():.3f}")'; }

t0=$(cputime "$pid"); w0=$(wall)
[ -z "$t0" ] && { echo "pid $pid not running" >&2; exit 1; }
sleep "$secs"
t1=$(cputime "$pid"); w1=$(wall)
[ -z "$t1" ] && { echo "pid $pid exited during the window" >&2; exit 1; }

awk -v t0="$t0" -v t1="$t1" -v w0="$w0" -v w1="$w1" -v l="$label" 'BEGIN{
  dc=t1-t0; dw=w1-w0
  printf "%-28s cpu=%6.2fs  wall=%6.2fs  %6.2f%% of one core\n", l, dc, dw, dc/dw*100
}'
