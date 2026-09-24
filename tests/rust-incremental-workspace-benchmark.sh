#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]] || ! command -v docker >/dev/null; then
    echo "This benchmark requires Linux and Docker for its isolated Redis backend." >&2
    exit 2
fi

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cargo_bin=${CARGO_BIN:-cargo}
rustc_bin=${RUSTC_BIN:-rustc}
sccache_bin=${SCCACHE_BIN:-/mnt/kingston/builds/rebroad/src/sccache-bench.build/target/debug/sccache}
build_root=${BENCH_BUILD_ROOT:-/mnt/kingston/builds/rebroad/src/sccache-bench.build}
test -x "$sccache_bin"

run_id=$(date -u +%Y%m%dT%H%M%SZ)
results="$build_root/workspace-benchmark-$run_id"
scratch=$(mktemp -d /var/tmp/sccache-workspace-bench.XXXXXX)
redis="sccache-workspace-bench-$$"
port=$((18000 + RANDOM % 20000))
mkdir -p "$results"
: > "$results/sccache.conf"
summary="$results/summary.tsv"
printf 'case\twall_s\trustc_compile_s\tsnapshot_restores\thardlinked_files\traw_snapshot_bytes_published\traw_snapshot_bytes_restored\tfetch_ms\tunpack_ms\tredis_payload_uploaded_bytes\tredis_payload_downloaded_bytes\tcompressed_snapshot_payload_bytes\tcache_dataset_bytes\tlocal_cache_bytes\texact_cache_hits\n' > "$summary"

cleanup() {
    docker rm -f "$redis" >/dev/null 2>&1 || true
    rm -rf "$scratch"
}
trap cleanup EXIT

copy_workspace() {
    local source=$1 destination=$2
    mkdir -p "$destination"
    tar -C "$source" --exclude=.git --exclude=target -cf - . | tar -C "$destination" -xf -
}

make_workspace() {
    local source=$1 target=$2
    if [[ ! -e "$source/target" && ! -L "$source/target" ]]; then
        ln -s "$target" "$source/target"
    fi
}

small_edit() {
    sed -i 's/const MAX_CANDIDATES: usize = 8;/const MAX_CANDIDATES: usize = 9;/' \
        "$1/src/compiler/rust_incremental.rs"
}

moderate_edit() {
    local source=$1 index
    for index in $(seq 0 63); do
        printf '/// Benchmark-only marker for incremental compilation.\n#[doc(hidden)]\npub fn sccache_bench_marker_%02d() -> usize { %d }\n' "$index" "$index" \
            >> "$source/src/lib.rs"
    done
}

redis_dataset_bytes() {
    docker exec "$redis" redis-cli -p "$port" EVAL \
        'local keys=redis.call("KEYS","*"); local sum=0; for _,k in ipairs(keys) do if redis.call("TYPE",k).ok == "string" then sum=sum+redis.call("STRLEN",k) end end; return sum' 0
}

run_build() {
    local label=$1 source=$2 target=$3 incremental=$4 cache=$5 cache_dir=$6 remote=$7 keep_target=$8
    local log="$results/$label.log" start end wall rustc_time raw_published raw_restored
    local fetch_ms unpack_ms restores hardlinks exact_hits before_in=0 before_out=0
    local storage_uploaded=0 storage_downloaded=0 snapshot_record_bytes=0 dataset=0 local_cache_bytes=0
    if [[ "$keep_target" != 1 && ( -e "$target" || -L "$target" ) ]]; then
        rm -rf "$target"
    fi
    mkdir -p "$target"
    make_workspace "$source" "$target"
    if [[ "$keep_target" != 1 ]] && find "$target" -mindepth 1 -print -quit | grep -q .; then
        echo "target directory was not empty before $label: $target" >&2
        return 1
    fi
    start=$(date +%s%N)
    (
        cd "$source"
        export RUSTC_BOOTSTRAP=1
        export RUSTC="$rustc_bin"
        export RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info -Z time-passes'
        if [[ "$remote" == 1 && "${BENCH_PATH_REMAP:-0}" == 1 ]]; then
            export RUSTFLAGS+=" --remap-path-prefix=$scratch/remote-a=/sccache-workspace"
            export RUSTFLAGS+=" --remap-path-prefix=$scratch/remote-small=/sccache-workspace"
            export RUSTFLAGS+=" --remap-path-prefix=$scratch/remote-moderate=/sccache-workspace"
            export RUSTFLAGS+=" --remap-path-prefix=$target=/sccache-target"
        fi
        export CARGO_INCREMENTAL=$incremental
        export SCCACHE_CONF="$results/sccache.conf"
        export SCCACHE_DIR="$cache_dir"
        export SCCACHE_IN_PROCESS=1
        export SCCACHE_LOG=debug
        if [[ "$cache" == 1 ]]; then
            export RUSTC_WRAPPER="$sccache_bin"
        else
            export RUSTC_WRAPPER=
        fi
        if [[ "$cache" == 1 && "$incremental" == 1 ]]; then
            export SCCACHE_RUST_INCREMENTAL=1
        else
            unset SCCACHE_RUST_INCREMENTAL
        fi
        if [[ "$remote" == 1 ]]; then
            export SCCACHE_REDIS="redis://127.0.0.1:$port"
        else
            unset SCCACHE_REDIS
        fi
        "$cargo_bin" build --workspace --locked -vv
    ) > "$log" 2>&1 || {
        echo "benchmark case failed: $label (see $log)" >&2
        tail -80 "$log" >&2
        return 1
    }
    end=$(date +%s%N)
    wall=$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f", (end-start)/1000000000 }')
    if [[ "$cache" == 1 ]]; then
        rustc_time=$(sed -n 's/.*Compiled in \([0-9.]*\) s.*/\1/p' "$log" | awk '{sum += $1} END {printf "%.3f", sum}')
    else
        rustc_time=$(awk '/^time:.*total$/ { value=$2; sub(/;$/, "", value); sum+=value } END { printf "%.3f", sum }' "$log")
    fi
    raw_published=$(sed -n 's/.*published Rust incremental snapshot: archive_bytes=\([0-9]*\).*/\1/p' "$log" | awk '{sum += $1} END {print sum + 0}')
    raw_restored=$(sed -n 's/.*restored Rust incremental snapshot: archive_bytes=\([0-9]*\).*/\1/p' "$log" | awk '{sum += $1} END {print sum + 0}')
    fetch_ms=$(sed -n 's/.*restored Rust incremental snapshot: archive_bytes=[0-9]* chunks=[0-9]* fetch_ms=\([0-9.]*\).*/\1/p' "$log" | awk '{sum += $1} END {printf "%.3f", sum}')
    unpack_ms=$(sed -n 's/.*restored Rust incremental snapshot: archive_bytes=[0-9]* chunks=[0-9]* fetch_ms=[0-9.]* unpack_ms=\([0-9.]*\).*/\1/p' "$log" | awk '{sum += $1} END {printf "%.3f", sum}')
    restores=$(grep -c 'restored Rust incremental snapshot:' "$log" || true)
    hardlinks=$(sed -n 's/.*session directory: \([0-9][0-9]*\) files hard-linked.*/\1/p' "$log" | awk '{sum += $1} END {print sum + 0}')
    exact_hits=$(grep -c 'Cache hit in' "$log" || true)
    if [[ "$remote" == 1 ]]; then
        storage_uploaded=$(sed -n 's/.*service=redis .* written=\([0-9][0-9]*\): write close succeeded/\1/p' "$log" | awk '{sum += $1} END {print sum + 0}')
        storage_downloaded=$(sed -n 's/.*service=redis .* read=\([0-9][0-9]*\) size=[0-9][0-9]*: read finished/\1/p' "$log" | awk '{sum += $1} END {print sum + 0}')
        snapshot_record_bytes=$(sed -n 's/.*service=redis .*rust-incremental-v4.*\/objects\/[^ ]* written=\([0-9][0-9]*\): write close succeeded/\1/p' "$log" | awk '{sum += $1} END {print sum + 0}')
    fi
    if [[ "$cache" == 1 ]]; then
        local_cache_bytes=$(du -sb "$cache_dir" 2>/dev/null | awk '{print $1 + 0}' || echo 0)
    fi
    if [[ "$remote" == 1 ]]; then
        dataset=$(redis_dataset_bytes 2>"$results/$label.redis-measurement.err") || {
            echo "Redis dataset size measurement failed for $label; see $results/$label.redis-measurement.err" >&2
            dataset=0
        }
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$wall" "$rustc_time" "$restores" "$hardlinks" \
        "$raw_published" "$raw_restored" "$fetch_ms" "$unpack_ms" \
        "$storage_uploaded" "$storage_downloaded" "$snapshot_record_bytes" "$dataset" "$local_cache_bytes" "$exact_hits" >> "$summary"
    printf '%s: wall=%ss rustc_compile=%ss restores=%s hardlinked_files=%s exact_hits=%s\n' \
        "$label" "$wall" "$rustc_time" "$restores" "$hardlinks" "$exact_hits"
}

printf 'rustc version:\n' | tee "$results/toolchain.txt"
"$rustc_bin" -Vv | tee -a "$results/toolchain.txt"
printf 'platform: ' | tee -a "$results/toolchain.txt"
uname -a | tee -a "$results/toolchain.txt"
printf 'workspace packages: ' | tee -a "$results/toolchain.txt"
RUSTC_WRAPPER= "$cargo_bin" metadata --locked --no-deps --format-version 1 |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join(p["name"] for p in d["packages"]))' |
    tee -a "$results/toolchain.txt"

if [[ "${BENCH_REMOTE_ONLY:-0}" != 1 ]]; then
    copy_workspace "$repo" "$scratch/clean"
    run_build clean-incremental-disabled "$scratch/clean" "$results/target-clean" 0 0 "$results/cache-clean" 0 0

    copy_workspace "$repo" "$scratch/local-incremental"
    run_build local-incremental-seed "$scratch/local-incremental" "$results/target-local" 1 0 "$results/cache-local" 0 0
    small_edit "$scratch/local-incremental"
    run_build local-incremental-small-edit "$scratch/local-incremental" "$results/target-local" 1 0 "$results/cache-local" 0 1

    copy_workspace "$repo" "$scratch/exact"
    run_build exact-cache-seed "$scratch/exact" "$results/target-exact" 0 1 "$results/cache-exact" 0 0
    run_build exact-cache-hit "$scratch/exact" "$results/target-exact" 0 1 "$results/cache-exact" 0 0
    awk -F '\t' '$1 == "exact-cache-hit" && $15 > 0 { found=1 } END { exit !found }' "$summary" || {
        echo "sccache did not report an exact cache hit in the exact-cache case" >&2
        exit 1
    }
fi

docker run --rm -d --network host --name "$redis" redis:7-alpine \
    redis-server --bind 127.0.0.1 --port "$port" --save '' --appendonly no >/dev/null
for _ in $(seq 1 30); do
    if docker exec "$redis" redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
        break
    fi
    sleep 1
done
docker exec "$redis" redis-cli -p "$port" ping | grep -q PONG

copy_workspace "$repo" "$scratch/remote-a"
copy_workspace "$scratch/remote-a" "$scratch/remote-small"
small_edit "$scratch/remote-small"
copy_workspace "$scratch/remote-small" "$scratch/remote-moderate"
moderate_edit "$scratch/remote-moderate"
remote_target="$results/target-remote-a"
remote_small_target="$results/target-remote-small"
remote_moderate_target="$results/target-remote-moderate"
[[ "$scratch/remote-a" != "$scratch/remote-small" ]]
[[ "$scratch/remote-small" != "$scratch/remote-moderate" ]]
[[ "$remote_target" != "$remote_small_target" && "$remote_small_target" != "$remote_moderate_target" ]]
run_build remote-incremental-miss "$scratch/remote-a" "$remote_target" 1 1 "$results/cache-remote-a" 1 0
run_build remote-incremental-small-edit "$scratch/remote-small" "$remote_small_target" 1 1 "$results/cache-remote-small" 1 0
run_build remote-incremental-moderate-edit "$scratch/remote-moderate" "$remote_moderate_target" 1 1 "$results/cache-remote-moderate" 1 0

awk -F '\t' '$1 == "remote-incremental-miss" && $4 == 0 { seed=1 } END { exit !seed }' "$summary" || {
    echo "fresh remote seed unexpectedly restored a predecessor" >&2
    exit 1
}
for label in remote-incremental-small-edit remote-incremental-moderate-edit; do
    awk -F '\t' -v label="$label" \
        '$1 == label && $4 > 0 && $5 > 0 && $15 > 0 { found=1 } END { exit !found }' "$summary" || {
        echo "$label did not restore rustc work products and exact-cache dependencies into an empty target" >&2
        exit 1
    }
done

echo
echo "summary: $summary"
echo "logs and external targets: $results"
echo "Redis network byte deltas include RESP/cache metadata and the measurement probes."
echo "Snapshot record deltas are Redis STRLEN payload bytes; archive sizes are raw tar bytes."
cat "$summary"
