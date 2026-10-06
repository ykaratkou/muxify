#!/usr/bin/env bash
# Benchmarks the terminal this script runs in, so Muxify can be compared with
# Ghostty.app attached to the same tmux Session: run `make bench` in a Pane of
# each and compare the results in build/bench.
#
# Each run records two things:
#   1. idle CPU of the terminal app, sampled with top while nothing is drawn
#   2. PTY throughput with vtebench, saved as a gnuplot .dat file
#
# vtebench is cloned at $VTEBENCH_COMMIT into vendor/vtebench and built with
# cargo on first use.
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VTEBENCH="$ROOT/vendor/vtebench"
VTEBENCH_COMMIT=ead80032e57dee2e75f0b51f2ea67528647d9944
OUT="$ROOT/build/bench"
IDLE_SECS="${IDLE_SECS:-10}"

# The terminal app process that $1 runs under: its first ancestor that runs
# from inside an .app bundle. Prints nothing if there is none.
app_pid() {
    local pid=$1
    while [[ "$pid" -gt 1 ]]; do
        if [[ "$(ps -o comm= -p "$pid")" == *.app/Contents/MacOS/* ]]; then
            echo "$pid"
            return
        fi
        pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
    done
}

# Average %CPU of a process over $IDLE_SECS seconds. top's first sample has no
# previous one to diff against, so it is dropped.
idle_cpu() {
    top -l $((IDLE_SECS + 1)) -s 1 -pid "$1" -stats cpu |
        awk 'prev == "%CPU" { n++; if (n > 1) { sum += $1; count++ } } { prev = $1 }
             END { printf "%.1f", sum / count }'
}

if [[ ! -x "$VTEBENCH/target/release/vtebench" ]]; then
    command -v cargo >/dev/null || { echo "error: vtebench needs cargo (rustup.rs)" >&2; exit 1; }
    if [[ ! -d "$VTEBENCH/.git" ]]; then
        git clone --quiet https://github.com/alacritty/vtebench "$VTEBENCH"
    fi
    git -C "$VTEBENCH" checkout --quiet "$VTEBENCH_COMMIT"
    cargo build --quiet --release --manifest-path "$VTEBENCH/Cargo.toml"
fi

# Inside tmux this shell descends from the tmux server, not the terminal, so
# the terminal is found through a tmux client: the most recently active one
# that is not a control-mode client, which is the one `make bench` was just
# typed into. Any other client that shows this Window gets every update too and
# slows the throughput result, so the run stops.
start=$$
clients=""
if [[ -n "${TMUX:-}" ]]; then
    window=$(tmux display -p -t "$TMUX_PANE" '#{window_id}')
    clients=$(tmux list-clients \
        -F $'#{client_control_mode}\t#{client_activity}\t#{client_pid}\t#{window_id}\t#{client_name}' |
        awk -F'\t' '$1 == 0' | sort -t$'\t' -k2 -n)
    start=$(tail -1 <<<"$clients" | cut -f3)
fi
pid=$(app_pid "$start")
[[ -n "$pid" ]] || { echo "error: cannot find the terminal app that runs this script" >&2; exit 1; }
app=$(basename "$(ps -o comm= -p "$pid")")
size="$(tput cols)x$(tput lines)"
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

others=$(awk -F'\t' -v start="$start" -v window="${window:-}" \
    '$3 != start && $4 == window { print $5 }' <<<"$clients")
if [[ -n "$others" ]]; then
    echo "error: another tmux client shows this Window. tmux draws every update to" >&2
    echo "each client, which slows the throughput result. Close that terminal window" >&2
    echo "or detach it, then run again:" >&2
    while read -r name; do echo "  tmux detach-client -t $name" >&2; done <<<"$others"
    exit 1
fi

echo "Benchmarking $app (pid $pid) at ${size}."
echo "Measuring idle CPU for ${IDLE_SECS}s. Do not touch anything."
cpu=$(idle_cpu "$pid")

dat="$OUT/$app-$stamp.dat"
(cd "$VTEBENCH" && ./target/release/vtebench --dat "$dat")

printf '%s\t%s\t%s\t%s\t%s\n' "$stamp" "$app" "$size" "$cpu" "$(basename "$dat")" >>"$OUT/runs.tsv"
echo
echo "Idle CPU: ${cpu}%"
echo "Throughput: $dat"
echo
column -t -s $'\t' "$OUT/runs.tsv"

if command -v gnuplot >/dev/null; then
    "$VTEBENCH/gnuplot/summary.sh" "$OUT"/*.dat "$OUT/summary.svg"
    echo "Plot of all runs: $OUT/summary.svg"
else
    echo "Install gnuplot to plot all runs side by side."
fi
