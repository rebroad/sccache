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
repeats=${BENCH_REPEATS:-1}
comparison_only=${BENCH_COMPARISON_ONLY:-0}
if [[ ! "$repeats" =~ ^[1-9][0-9]*$ ]]; then
    echo "BENCH_REPEATS must be a positive integer." >&2
    exit 2
fi
if [[ "$comparison_only" != 0 && "$comparison_only" != 1 ]]; then
    echo "BENCH_COMPARISON_ONLY must be 0 or 1." >&2
    exit 2
fi

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
            export RUSTFLAGS+=" --remap-path-prefix=$source=/sccache-workspace"
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
printf 'sccache version: ' | tee -a "$results/toolchain.txt"
"$sccache_bin" --version | tee -a "$results/toolchain.txt"
printf 'source revision: ' | tee -a "$results/toolchain.txt"
git -C "$repo" rev-parse HEAD | tee -a "$results/toolchain.txt"
printf 'source worktree changes: ' | tee -a "$results/toolchain.txt"
if [[ -z $(git -C "$repo" status --porcelain) ]]; then
    echo clean | tee -a "$results/toolchain.txt"
else
    echo present-see-source-status.txt | tee -a "$results/toolchain.txt"
    git -C "$repo" status --short > "$results/source-status.txt"
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

for round in $(seq 1 "$repeats"); do
    round_tag=$(printf 'r%02d' "$round")
    round_root="$scratch/$round_tag"
    mkdir -p "$round_root"
    # Reset remote state between rounds while keeping every compiler input
    # identical across samples.
    docker exec "$redis" redis-cli -p "$port" FLUSHDB >/dev/null

    if [[ "${BENCH_REMOTE_ONLY:-0}" != 1 ]]; then
        if [[ "$comparison_only" != 1 ]]; then
            copy_workspace "$repo" "$round_root/clean"
            run_build "$round_tag-clean-incremental-disabled" "$round_root/clean" \
                "$results/target-$round_tag-clean" 0 0 "$results/cache-$round_tag-clean" 0 0
        fi

        copy_workspace "$repo" "$round_root/local"
        local_target="$results/target-$round_tag-local"
        run_build "$round_tag-local-incremental-seed" "$round_root/local" \
            "$local_target" 1 0 "$results/cache-$round_tag-local" 0 0
        small_edit "$round_root/local"
        run_build "$round_tag-local-incremental-small-edit" "$round_root/local" \
            "$local_target" 1 0 "$results/cache-$round_tag-local" 0 1
        moderate_edit "$round_root/local"
        run_build "$round_tag-local-incremental-moderate-edit" "$round_root/local" \
            "$local_target" 1 0 "$results/cache-$round_tag-local" 0 1

        if [[ "$comparison_only" != 1 ]]; then
            copy_workspace "$repo" "$round_root/exact"
            exact_target="$results/target-$round_tag-exact"
            exact_cache="$results/cache-$round_tag-exact"
            run_build "$round_tag-exact-cache-seed" "$round_root/exact" \
                "$exact_target" 0 1 "$exact_cache" 0 0
            run_build "$round_tag-exact-cache-hit" "$round_root/exact" \
                "$exact_target" 0 1 "$exact_cache" 0 0
            awk -F '\t' -v label="$round_tag-exact-cache-hit" \
                '$1 == label && $15 > 0 { found=1 } END { exit !found }' "$summary" || {
                echo "sccache did not report an exact cache hit in $round_tag" >&2
                exit 1
            }
        fi
    fi

    copy_workspace "$repo" "$round_root/remote-a"
    copy_workspace "$round_root/remote-a" "$round_root/remote-small"
    small_edit "$round_root/remote-small"
    copy_workspace "$round_root/remote-small" "$round_root/remote-moderate"
    moderate_edit "$round_root/remote-moderate"
    remote_target="$results/target-$round_tag-remote-a"
    remote_small_target="$results/target-$round_tag-remote-small"
    remote_moderate_target="$results/target-$round_tag-remote-moderate"
    [[ "$round_root/remote-a" != "$round_root/remote-small" ]]
    [[ "$round_root/remote-small" != "$round_root/remote-moderate" ]]
    [[ "$remote_target" != "$remote_small_target" && "$remote_small_target" != "$remote_moderate_target" ]]
    run_build "$round_tag-remote-incremental-miss" "$round_root/remote-a" \
        "$remote_target" 1 1 "$results/cache-$round_tag-remote-a" 1 0
    run_build "$round_tag-remote-incremental-small-edit" "$round_root/remote-small" \
        "$remote_small_target" 1 1 "$results/cache-$round_tag-remote-small" 1 0
    run_build "$round_tag-remote-incremental-moderate-edit" "$round_root/remote-moderate" \
        "$remote_moderate_target" 1 1 "$results/cache-$round_tag-remote-moderate" 1 0

    awk -F '\t' -v label="$round_tag-remote-incremental-miss" \
        '$1 == label && $4 == 0 { seed=1 } END { exit !seed }' "$summary" || {
        echo "$round_tag remote seed unexpectedly restored a predecessor" >&2
        exit 1
    }
    for edit_case in remote-incremental-small-edit remote-incremental-moderate-edit; do
        label="$round_tag-$edit_case"
        awk -F '\t' -v label="$label" \
            '$1 == label && $4 > 0 && $5 > 0 && $15 > 0 { found=1 } END { exit !found }' "$summary" || {
            echo "$label did not restore rustc work products and exact-cache dependencies into an empty target" >&2
            exit 1
        }
    done
    rm -rf "$results/target-$round_tag-"* "$results/cache-$round_tag-"*
done

echo
echo "summary: $summary"
echo "logs and measurements: $results"
echo "successful-round target and cache directories were removed after metrics were recorded."
echo "Redis network byte deltas include RESP/cache metadata and the measurement probes."
echo "Snapshot record deltas are Redis STRLEN payload bytes; archive sizes are raw tar bytes."
cat "$summary"
python3 - "$summary" "$results/repeated-summary.tsv" <<'PY'
import csv
import statistics
import sys

summary_path, output_path = sys.argv[1:]
with open(summary_path, newline="") as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))

cases = (
    "local-incremental-small-edit",
    "local-incremental-moderate-edit",
    "remote-incremental-small-edit",
    "remote-incremental-moderate-edit",
)
samples = {}
for case in cases:
    selected = [row for row in rows if row["case"].endswith(case)]
    if selected:
        samples[case] = {
            "wall": [float(row["wall_s"]) for row in selected],
            "rustc": [float(row["rustc_compile_s"]) for row in selected],
        }

with open(output_path, "w", newline="") as stream:
    writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
    writer.writerow(("case", "samples", "wall_median_s", "wall_min_s", "wall_max_s", "rustc_compile_median_s", "remote_vs_local_wall_ratio_median"))
    for case, values in samples.items():
        paired = case.startswith("remote-")
        local_case = case.replace("remote-", "local-", 1)
        ratios = []
        if paired and local_case in samples:
            local_by_round = {}
            remote_by_round = {}
            for row in rows:
                if row["case"].endswith(local_case):
                    local_by_round[row["case"].split("-", 1)[0]] = float(row["wall_s"])
                if row["case"].endswith(case):
                    remote_by_round[row["case"].split("-", 1)[0]] = float(row["wall_s"])
            ratios = [remote_by_round[tag] / local_by_round[tag] for tag in local_by_round.keys() & remote_by_round.keys()]
        wall = values["wall"]
        writer.writerow((
            case,
            len(wall),
            f"{statistics.median(wall):.3f}",
            f"{min(wall):.3f}",
            f"{max(wall):.3f}",
            f"{statistics.median(values['rustc']):.3f}",
            f"{statistics.median(ratios):.3f}" if ratios else "",
        ))
print(f"repeated summary: {output_path}")
PY
cat "$results/repeated-summary.tsv"
