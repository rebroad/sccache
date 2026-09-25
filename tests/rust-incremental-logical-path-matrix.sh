#!/usr/bin/env bash
set -euo pipefail
repo=/mnt/kingston/@home/rebroad/src/sccache
build=/mnt/kingston/builds/rebroad/src/sccache.build
toolchain=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu
sccache=${SCCACHE_BIN:-/home/rebroad/bin/sccache-incremental-prototype/sccache}
result=$build/logical-path-matrix-$(date -u +%Y%m%dT%H%M%SZ)
scratch=/var/tmp/sccache-logical-path-matrix-$$
image=sccache-path-matrix:$$
redis=sccache-path-matrix-redis-$$
port=$((18000 + RANDOM % 20000))
mkdir -p "$result" "$scratch"
cleanup() { docker rm -f "$redis" >/dev/null 2>&1 || true; docker image rm "$image" >/dev/null 2>&1 || true; }
trap cleanup EXIT
printf 'FROM debian:trixie\nRUN apt-get update && apt-get install -y --no-install-recommends build-essential clang cmake perl pkg-config python3 && rm -rf /var/lib/apt/lists/*\n' > "$result/Dockerfile"
docker build --network host -t "$image" -f "$result/Dockerfile" "$result" > "$result/docker-build.log" 2>&1
docker run --rm -d --network host --name "$redis" redis:7-alpine redis-server --bind 127.0.0.1 --port "$port" --save '' --appendonly no >/dev/null
for _ in $(seq 1 30); do docker exec "$redis" redis-cli -p "$port" ping 2>/dev/null | grep -q PONG && break; sleep 1; done
docker exec "$redis" redis-cli -p "$port" ping | grep -q PONG
cat > "$result/rustc-wrapper" <<'EOF'
#!/bin/bash
rustc=$1; shift
crate=
crate_type=
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ ${args[i]} == --crate-name && $((i+1)) -lt ${#args[@]} ]]; then crate=${args[i+1]}; break; fi
done
for ((i=0; i<${#args[@]}; i++)); do
  if [[ ${args[i]} == --crate-type && $((i+1)) -lt ${#args[@]} ]]; then crate_type=${args[i+1]}; break; fi
done
if [[ $crate == sccache && $crate_type == lib && -n ${SCCACHE_ASSERT_STATE:-} ]]; then args+=("-Z" "assert-incr-state=$SCCACHE_ASSERT_STATE"); fi
exec /usr/local/bin/sccache "$rustc" "${args[@]}"
EOF
chmod +x "$result/rustc-wrapper"
printf 'case\twall_s\trustc_s\texact_hits\tpred_restores\treused_work_products\traw_archive_bytes\tfiles\tsession_dirs\tincremental_bytes\n' > "$result/summary.tsv"
run_build() {
  local phase=$1 logical_source=$2 logical_target=$3 host_source=$4 host_target=$5 assert=$6 logfile=$7
  local started ended
  mkdir -p "$host_target"
  started=$(date +%s%N)
  docker run --rm --network host --workdir "$logical_source" \
    -v "$host_source:$logical_source" -v "$host_target:$logical_target" \
    -v "$toolchain:/toolchain:ro" -v "$sccache:/usr/local/bin/sccache:ro" \
    -v "$result/rustc-wrapper:/usr/local/bin/rustc-wrapper:ro" \
    -v /home/rebroad/.cargo/registry:/cargo/registry:ro \
    -e TMPDIR=/var/tmp \
    -e PATH=/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -e CARGO_HOME=/cargo -e CARGO_TARGET_DIR="$logical_target" -e CARGO_NET_OFFLINE=true \
    -e RUSTC=/toolchain/bin/rustc -e RUSTC_WRAPPER=/usr/local/bin/rustc-wrapper \
    -e RUSTC_BOOTSTRAP=1 -e CARGO_INCREMENTAL=1 \
    -e RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info -Z time-passes' \
    -e SCCACHE_CONF=/dev/null -e SCCACHE_REDIS="redis://127.0.0.1:$port" \
    -e SCCACHE_IN_PROCESS=1 -e SCCACHE_RUST_INCREMENTAL=1 -e SCCACHE_LOG=debug \
    -e SCCACHE_ASSERT_STATE="$assert" "$image" cargo build --workspace --locked -vv > "$logfile" 2>&1 || { tail -40 "$logfile" >&2; return 1; }
  ended=$(date +%s%N)
  awk -v s="$started" -v e="$ended" 'BEGIN {printf "%.3f", (e-s)/1e9}'
}
copy_source() {
  local src=$1 dst=${2:-}
  if [[ -z $dst ]]; then dst=$src; src=$repo; fi
  mkdir -p "$dst"
  tar -C "$src" --exclude=.git --exclude=target -cf - . | tar -C "$dst" -xf -
}
for scenario in ${MATRIX_CASES:-same-paths target-diff source-diff both-diff}; do
  base="$scratch/$scenario"
  source_a="$base/source-a"; source_b="$base/source-b"
  target_a="$base/target-a"; target_b="$base/target-b"
  copy_source "$source_a"; copy_source "$source_a" "$source_b"
  case $scenario in
    same-paths) edit_value=9 ;;
    target-diff) edit_value=10 ;;
    source-diff) edit_value=11 ;;
    both-diff) edit_value=12 ;;
  esac
  sed -i "s/const MAX_CANDIDATES: usize = 8;/const MAX_CANDIDATES: usize = $edit_value;/" "$source_b/src/compiler/rust_incremental.rs"
  producer_log="$result/$scenario-producer.log"
  t=$(run_build producer /workspace /target "$source_a" "$target_a" not-loaded "$producer_log")
  printf '%s producer wall=%ss\n' "$scenario" "$t"
  case $scenario in
    same-paths) bsrc=/workspace; btgt=/target ;;
    source-diff) bsrc=/workspace-b; btgt=/target ;;
    target-diff) bsrc=/workspace; btgt=/target-b ;;
    both-diff) bsrc=/workspace-b; btgt=/target-b ;;
  esac
  consumer_log="$result/$scenario-consumer.log"
  t=$(run_build consumer "$bsrc" "$btgt" "$source_b" "$target_b" loaded "$consumer_log")
  hits=$(grep -c 'Cache hit in' "$consumer_log" || true)
  restores=$(grep -c 'restored Rust incremental snapshot:' "$consumer_log" || true)
  reused=$(sed -n 's/.*session directory: \([0-9][0-9]*\) files hard-linked.*/\1/p' "$consumer_log" | awk '{s+=$1} END{print s+0}')
  raw=$(sed -n 's/.*restored Rust incremental snapshot: archive_bytes=\([0-9]*\).*/\1/p' "$consumer_log" | awk '{s+=$1} END{print s+0}')
  files=$(find "$target_b/debug/incremental" -type f 2>/dev/null | wc -l)
  sessions=$(find "$target_b/debug/incremental" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  bytes=$(du -sb "$target_b/debug/incremental" 2>/dev/null | awk '{print $1+0}')
  rustc_s=$(sed -n 's/.*Compiled in \([0-9.]*\) s.*/\1/p' "$consumer_log" | awk '{s+=$1} END{printf "%.3f",s}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$scenario" "$t" "$rustc_s" "$hits" "$restores" "$reused" "$raw" "$files" "$sessions" "$bytes" >> "$result/summary.tsv"
  echo "$scenario consumer wall=${t}s rustc=${rustc_s}s hits=$hits restores=$restores reused_work_products=$reused raw_archive_bytes=$raw files=$files sessions=$sessions incremental_bytes=$bytes"
  # Keep complete target trees for per-session inventory and compare their snapshots.
  for target in "$target_a" "$target_b"; do
    tag=$(basename "$target")
    find "$target/debug/incremental" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | while IFS= read -r -d '' session; do
      printf '%s\t' "${session##*/}" >> "$result/$scenario-$tag-sessions.tsv"
      du -sb "$session" | awk '{print $1}' >> "$result/$scenario-$tag-sessions.tsv"
    done
  done
done
printf 'repo=%s\nrustc=' "$repo" > "$result/environment.txt"
"$toolchain/bin/rustc" -Vv >> "$result/environment.txt"
printf 'host=' >> "$result/environment.txt"; uname -a >> "$result/environment.txt"
printf 'result=%s\n' "$result"
printf 'scratch=%s\n' "$scratch"
