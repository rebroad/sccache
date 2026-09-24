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
    -e RUSTC_BIN=/toolchain/bin/rustc "$image" bash /tmp/producer.sh

docker run --rm --network host \
    -v "$rustc_toolchain:/toolchain:ro" \
    -v "$sccache_bin:/usr/local/bin/sccache:ro" \
    -v "$repo/tests/rust-incremental-container-consumer.sh:/tmp/consumer.sh:ro" \
    -e "SCCACHE_REDIS=$redis_url" "$image" bash /tmp/consumer.sh
