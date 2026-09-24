#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]] || ! command -v docker >/dev/null; then
    echo "This test requires Linux and Docker." >&2
    exit 2
fi

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rustc_toolchain=${RUSTC_TOOLCHAIN:-/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu}
sccache_bin=${SCCACHE_BIN:-/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache}
test -x "$rustc_toolchain/bin/rustc"
test -x "$sccache_bin"

tmpdir=$(mktemp -d /var/tmp/sccache-incremental-containers.XXXXXX)
image="sccache-rust-incremental-test:$$"
redis="sccache-rust-incremental-redis-$$"
port=$((18000 + RANDOM % 20000))
cleanup() {
    docker rm -f "$redis" >/dev/null 2>&1 || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

docker build --network host -t "$image" - < "$repo/tests/Dockerfile.rust-incremental"
docker run --rm -d --network host --name "$redis" redis:7-alpine \
    redis-server --bind 127.0.0.1 --port "$port" --save '' --appendonly no >/dev/null
for _ in $(seq 1 30); do
    if docker exec "$redis" redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; then
        break
    fi
    sleep 1
done
docker exec "$redis" redis-cli -p "$port" ping | grep -q PONG
redis_url="redis://127.0.0.1:$port"

docker run --rm --network host \
    -v "$rustc_toolchain:/toolchain:ro" \
    -v "$sccache_bin:/usr/local/bin/sccache:ro" \
    -v "$repo/tests/rust-incremental-sccache-poc.sh:/tmp/producer.sh:ro" \
    -e "SCCACHE_REDIS=$redis_url" -e SCCACHE_BIN=/usr/local/bin/sccache \
    -e RUSTC_BIN=/toolchain/bin/rustc \
    -e SCCACHE_TEST_ABSOLUTE_INPUT="${SCCACHE_TEST_ABSOLUTE_INPUT:-0}" \
    "$image" bash /tmp/producer.sh

consumer_restore=1
target_mode=0
if [[ -n ${SCCACHE_TEST_TARGET_TRIPLE:-} ]]; then
    target_mode=1
fi
if (( ${SCCACHE_TEST_CORRUPT_SNAPSHOTS:-0} + ${SCCACHE_TEST_EVICT_SNAPSHOTS:-0} + ${SCCACHE_TEST_RUSTC_VERSION_MISMATCH:-0} + ${SCCACHE_TEST_EXTRA_CFG:-0} + ${SCCACHE_TEST_EXTRA_RUSTFLAGS:-0} + ${SCCACHE_TEST_EXPLICIT_TARGET:-0} + target_mode > 1 )); then
    echo "Choose one fallback scenario for a test run." >&2
    exit 2
fi
consumer_toolchain=$rustc_toolchain
if [[ ${SCCACHE_TEST_EXTRA_CFG:-0} == 1 || ${SCCACHE_TEST_EXTRA_RUSTFLAGS:-0} == 1 || ${SCCACHE_TEST_EXPLICIT_TARGET:-0} == 1 ]]; then
    consumer_restore=0
fi
if [[ $target_mode == 1 ]]; then
    consumer_restore=0
fi
if [[ ${SCCACHE_TEST_RUSTC_VERSION_MISMATCH:-0} == 1 ]]; then
    consumer_toolchain=${SCCACHE_TEST_RUSTC_TOOLCHAIN:-/home/rebroad/.rustup/toolchains/1.93.0-x86_64-unknown-linux-gnu}
    test -x "$consumer_toolchain/bin/rustc"
    consumer_restore=0
fi
if [[ ${SCCACHE_TEST_CORRUPT_SNAPSHOTS:-0} == 1 || ${SCCACHE_TEST_EVICT_SNAPSHOTS:-0} == 1 ]]; then
    consumer_restore=0
    mapfile -t snapshot_keys < <(
        docker exec "$redis" redis-cli -p "$port" --scan | grep '/rust-incremental-v4/.*/objects/'
    )
    if [[ ${#snapshot_keys[@]} -eq 0 ]]; then
        echo "Redis contains no Rust incremental snapshot objects to corrupt." >&2
        exit 1
    fi
    if [[ ${SCCACHE_TEST_CORRUPT_SNAPSHOTS:-0} == 1 ]]; then
        for key in "${snapshot_keys[@]}"; do
            docker exec "$redis" sh -c \
                'redis-cli -p "$2" --raw GET "$1" | head -c 16 | redis-cli -p "$2" -x SET "$1" >/dev/null' \
                sh "$key" "$port"
        done
        echo "corrupted ${#snapshot_keys[@]} immutable Redis snapshot objects"
    else
        for key in "${snapshot_keys[@]}"; do
            docker exec "$redis" redis-cli -p "$port" DEL "$key" >/dev/null
        done
        echo "evicted ${#snapshot_keys[@]} immutable Redis snapshot objects while retaining the candidate index"
    fi
fi

docker run --rm --network host \
    -v "$consumer_toolchain:/toolchain:ro" \
    -v "$sccache_bin:/usr/local/bin/sccache:ro" \
    -v "$repo/tests/rust-incremental-container-consumer.sh:/tmp/consumer.sh:ro" \
    -e "SCCACHE_REDIS=$redis_url" \
    -e SCCACHE_TEST_ABSOLUTE_INPUT="${SCCACHE_TEST_ABSOLUTE_INPUT:-0}" \
    -e SCCACHE_TEST_EXPECT_RESTORE="$consumer_restore" \
    -e SCCACHE_TEST_EXTRA_CFG="${SCCACHE_TEST_EXTRA_CFG:-0}" \
    -e SCCACHE_TEST_EXTRA_RUSTFLAGS="${SCCACHE_TEST_EXTRA_RUSTFLAGS:-0}" \
    -e SCCACHE_TEST_EXPLICIT_TARGET="${SCCACHE_TEST_EXPLICIT_TARGET:-0}" \
    -e SCCACHE_TEST_TARGET_TRIPLE="${SCCACHE_TEST_TARGET_TRIPLE:-}" \
    "$image" bash /tmp/consumer.sh
