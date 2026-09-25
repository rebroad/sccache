#!/usr/bin/env bash
set -euo pipefail
export TMPDIR=/var/tmp

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
zeroclaw_root=${ZEROCLAW_ROOT:-$repo/../zeroclaw}
codex_rust_root=${CODEX_RUST_ROOT:-$repo/../codex/codex-rs}
sccache_bin=${SCCACHE_BIN:-/home/rebroad/bin/sccache-incremental-prototype/sccache}
rustc_bin=${RUSTC_BIN:-/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc}
cargo_bin=${CARGO_BIN:-/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/cargo}
build_root=${BUILD_ROOT:-/mnt/kingston/builds/rebroad/src/sccache.build/real-project-probes}
run_id=$(date -u +%Y%m%dT%H%M%SZ)
result="$build_root/$run_id"
scratch=$(mktemp -d /var/tmp/sccache-real-projects.XXXXXX)
redis="sccache-real-projects-$$"
port=$((18000 + RANDOM % 20000))
mkdir -p "$result"
test -x "$sccache_bin" && test -x "$rustc_bin" && test -x "$cargo_bin"
cleanup() { docker rm -f "$redis" >/dev/null 2>&1 || true; rm -rf "$scratch"; }
trap cleanup EXIT
: > "$result/sccache.conf"
docker run --rm -d --network host --name "$redis" redis:7-alpine \
    redis-server --bind 127.0.0.1 --port "$port" --save '' --appendonly no >/dev/null
for _ in $(seq 1 30); do
    docker exec "$redis" redis-cli -p "$port" ping 2>/dev/null | grep -q PONG && break
    sleep 1
done
docker exec "$redis" redis-cli -p "$port" ping | grep -q PONG

printf 'project\tseed_wall_s\tedit_wall_s\trustc_edit_s\texact_hits\texact_misses\tpred_restores\treused_files\traw_restored_bytes\traw_published_bytes\n' > "$result/summary.tsv"
run_case() {
    local label=$1 source_repo=$2 package=$3 edit_file=$4 lock_mode=${5:-locked}
    local -a lock_args=()
    [[ $lock_mode == locked ]] && lock_args=(--locked)
    local source="$scratch/$label/source" target="$result/$label/target"
    local seed_log="$result/$label-seed.log" edit_log="$result/$label-edit.log"
    mkdir -p "$source" "$(dirname "$target")"
    tar -C "$source_repo" --exclude=.git --exclude=target -cf - . | tar -C "$source" -xf -
    docker exec "$redis" redis-cli -p "$port" FLUSHDB >/dev/null
    local start end seed_wall edit_wall rustc_s hits misses restores reused restored published
    export RUSTC="$rustc_bin" RUSTC_WRAPPER="$sccache_bin" CARGO_INCREMENTAL=1 RUSTC_BOOTSTRAP=1
    export CARGO_TARGET_DIR="$target"
    export SCCACHE_CONF="$result/sccache.conf" SCCACHE_REDIS="redis://127.0.0.1:$port"
    export SCCACHE_IN_PROCESS=1 SCCACHE_RUST_INCREMENTAL=1 SCCACHE_LOG=debug SCCACHE_DIR="$result/$label-cache"
    export RUSTFLAGS='-Z remap-cwd-prefix=/sccache-project -Z incremental-info -Z time-passes'
    start=$(date +%s%N)
    "$cargo_bin" build "${lock_args[@]}" --manifest-path "$source/Cargo.toml" -p "$package" -vv > "$seed_log" 2>&1 || { tail -60 "$seed_log" >&2; return 1; }
    end=$(date +%s%N)
    seed_wall=$(awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f",(e-s)/1e9}')
    printf '\n// opt-in incremental snapshot probe %s\n' "$run_id" >> "$source/$edit_file"
    rm -rf "$target"
    start=$(date +%s%N)
    "$cargo_bin" build "${lock_args[@]}" --manifest-path "$source/Cargo.toml" -p "$package" -vv > "$edit_log" 2>&1 || { tail -60 "$edit_log" >&2; return 1; }
    end=$(date +%s%N)
    edit_wall=$(awk -v s="$start" -v e="$end" 'BEGIN {printf "%.3f",(e-s)/1e9}')
    grep -F 'restored Rust incremental snapshot:' "$edit_log" >/dev/null || { echo "$label: predecessor not restored" >&2; return 1; }
    rustc_s=$(sed -n 's/.*Compiled in \([0-9.]*\) s.*/\1/p' "$edit_log" | awk '{s+=$1} END {printf "%.3f",s}')
    hits=$(grep -c 'Cache hit in' "$edit_log" || true)
    misses=$(grep -c 'Cache miss in' "$edit_log" || true)
    restores=$(grep -c 'restored Rust incremental snapshot:' "$edit_log" || true)
    reused=$(sed -n 's/.*session directory: \([0-9][0-9]*\) files hard-linked.*/\1/p' "$edit_log" | awk '{s+=$1} END {print s+0}')
    restored=$(sed -n 's/.*restored Rust incremental snapshot: archive_bytes=\([0-9]*\).*/\1/p' "$edit_log" | awk '{s+=$1} END {print s+0}')
    published=$(sed -n 's/.*published Rust incremental snapshot: archive_bytes=\([0-9]*\).*/\1/p' "$edit_log" | awk '{s+=$1} END {print s+0}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label:$package" "$seed_wall" "$edit_wall" "$rustc_s" "$hits" "$misses" "$restores" "$reused" "$restored" "$published" >> "$result/summary.tsv"
    printf '%s: seed=%ss edit=%ss rustc=%ss exact_hits=%s misses=%s predecessor_restores=%s reused_files=%s raw_restored=%s raw_published=%s\n' "$label" "$seed_wall" "$edit_wall" "$rustc_s" "$hits" "$misses" "$restores" "$reused" "$restored" "$published"
}

run_case zeroclaw-api "$zeroclaw_root" zeroclaw-api crates/zeroclaw-api/src/lib.rs
run_case codex-absolute-path "$codex_rust_root" codex-utils-absolute-path utils/absolute-path/src/lib.rs unlocked

printf 'rustc=' > "$result/environment.txt"
"$rustc_bin" -Vv >> "$result/environment.txt"
printf 'sidecar=' >> "$result/environment.txt"
"$sccache_bin" --version >> "$result/environment.txt"
printf 'results=%s\n' "$result"
cat "$result/summary.tsv"
