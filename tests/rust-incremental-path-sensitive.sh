#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]] || ! command -v readelf >/dev/null; then
    echo "This regression currently requires Linux and readelf." >&2
    exit 2
fi

cargo_bin=${CARGO_BIN:-cargo}
rustc_bin=${RUSTC_BIN:-rustc}
sccache_bin=${SCCACHE_BIN:-sccache}
root=$(mktemp -d /var/tmp/sccache-path-sensitive.XXXXXX)
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        for log in "$root"/*.log; do
            if [[ -f "$log" ]]; then
                echo "--- $(basename "$log"): relevant diagnostics ---" >&2
                rg 'predecessor namespace=|restored Rust incremental|no Rust incremental|files hard-linked|asserted that|error:|Finished' "$log" >&2 || true
            fi
        done
        echo "kept path-sensitive reproduction at $root" >&2
        exit "$status"
    fi
    if [[ ${SCCACHE_TEST_KEEP_TMP:-0} == 1 ]]; then
        echo "kept path-sensitive reproduction at $root"
    else
        rm -rf "$root"
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$root/a/app/src" "$root/b/app/src" "$root/shared/site_macro/src" "$root/cache"
: > "$root/sccache.conf"

cat > "$root/shared/site_macro/Cargo.toml" <<'TOML'
[package]
name = "site_macro"
version = "0.1.0"
edition = "2021"

[lib]
proc-macro = true
TOML
cat > "$root/shared/site_macro/src/lib.rs" <<'RS'
use proc_macro::{Span, TokenStream};

#[proc_macro_attribute]
pub fn record_call_site(_: TokenStream, item: TokenStream) -> TokenStream {
    let item = item.to_string();
    let path = Span::call_site().file();
    format!("{item}\npub const PROC_MACRO_CALL_SITE: &str = {path:?};")
        .parse()
        .unwrap()
}
RS

for checkout in a b; do
    cat > "$root/$checkout/app/Cargo.toml" <<'TOML'
[package]
name = "path_sensitive_probe"
version = "0.1.0"
edition = "2021"

[dependencies]
site_macro = { path = "../../shared/site_macro" }

[profile.dev]
debug = 2
incremental = true
TOML
    cat > "$root/$checkout/app/src/lib.rs" <<'RS'
use site_macro::record_call_site;

#[record_call_site]
pub fn value() -> u32 { 10 }

pub fn rustc_call_site() -> &'static str { file!() }
RS
    cat > "$root/$checkout/app/src/main.rs" <<'RS'
fn main() {
    println!("{}|{}|{}", path_sensitive_probe::value(),
        path_sensitive_probe::PROC_MACRO_CALL_SITE,
        path_sensitive_probe::rustc_call_site());
}
RS
done
sed -i 's/value() -> u32 { 10 }/value() -> u32 { 11 }/' "$root/b/app/src/lib.rs"

cat > "$root/rustc-wrapper" <<'SH'
#!/bin/sh
compiler=$1
shift
if [ "${SCCACHE_ASSERT_INCR_STATE:-}" = loaded ]; then
    crate=
    next=0
    is_probe=0
    for arg in "$@"; do
        if [ "$next" = 1 ]; then crate=$arg; next=0; continue; fi
        if [ "$arg" = --crate-name ]; then next=1; continue; fi
        if [ "$crate" = path_sensitive_probe ] && [ "$arg" = src/lib.rs ]; then is_probe=1; fi
    done
    if [ "$is_probe" = 1 ]; then
        exec "$SCCACHE_BIN" "$compiler" "$@" -Z assert-incr-state=loaded
    fi
fi
exec "$SCCACHE_BIN" "$compiler" "$@"
SH
chmod +x "$root/rustc-wrapper"

printf 'rustc version:\n'
"$rustc_bin" -Vv
printf 'platform: '
uname -a

export SCCACHE_CONF="$root/sccache.conf"
export SCCACHE_DIR="$root/cache"
export SCCACHE_IN_PROCESS=1 SCCACHE_RUST_INCREMENTAL=1 SCCACHE_LOG=debug
export RUSTC_BOOTSTRAP=1 RUSTC="$rustc_bin" RUSTC_WRAPPER="$root/rustc-wrapper"
export SCCACHE_BIN="$sccache_bin"
export RUSTFLAGS='-Z remap-cwd-prefix=/sccache-path-sensitive -Z incremental-info'

(
    cd "$root/a/app"
    "$cargo_bin" build --target-dir "$root/target-a" -vv > "$root/a.log" 2>&1
)
test ! -e "$root/target-b"
(
    cd "$root/b/app"
    SCCACHE_ASSERT_INCR_STATE=loaded "$cargo_bin" build --target-dir "$root/target-b" -vv \
        > "$root/b.log" 2>&1
)
grep -F '[path_sensitive_probe]: restored Rust incremental snapshot' "$root/b.log" >/dev/null
grep -F '[incremental] session directory:' "$root/b.log" | grep -Eq '[1-9][0-9]* files hard-linked'
if grep -F '[path_sensitive_probe]: completely ignoring cache' "$root/b.log" >/dev/null; then
    echo "rustc rejected the restored path-sensitive snapshot" >&2
    exit 1
fi

"$root/target-b/debug/path_sensitive_probe" > "$root/restored.out"
(
    cd "$root/b/app"
    RUSTC_WRAPPER= "$cargo_bin" build --target-dir "$root/target-clean" -vv \
        > "$root/clean.log" 2>&1
)
"$root/target-clean/debug/path_sensitive_probe" > "$root/clean.out"
cmp "$root/restored.out" "$root/clean.out"
grep -q '^11|' "$root/restored.out"

readelf --debug-dump=decodedline "$root/target-b/debug/path_sensitive_probe" > "$root/debug-lines.txt"
grep -Eq 'src/(lib|main)\.rs' "$root/debug-lines.txt"
if grep -F "$root/a/" "$root/debug-lines.txt" >/dev/null; then
    echo "debug line information leaked Builder A's source path" >&2
    exit 1
fi
if grep -F "$root/b/" "$root/debug-lines.txt" >/dev/null; then
    echo "debug line information contains an unremapped Builder B source path" >&2
    exit 1
fi

printf 'restored/clean output (proc-macro and file! paths): '
cat "$root/restored.out"
printf 'rustc loaded the predecessor and reused work products: '
grep -E 'restored Rust incremental snapshot|session directory: [1-9][0-9]* files hard-linked' "$root/b.log" | tail -2 | tr '\n' ' '
printf '\nremapped debug line entries:\n'
grep -E 'src/(lib|main)\.rs' "$root/debug-lines.txt" | sort -u
