#!/usr/bin/env bash
#
# wazero/mayhem/build.sh — build three sanitized libFuzzer binaries over the
# WebAssembly binary decoder, the instantiation path, and an execution engine,
# plus the project's KAT probe.
#
# Targets produced (one Mayhemfile each):
#   /mayhem/fuzz_decode      — wazero.Runtime.CompileModule (binary-format
#                              decoder + validator: sections, LEB128 varints,
#                              per-instruction type-checking).
#   /mayhem/fuzz_instantiate — CompileModule + InstantiateModule with a bare
#                              runtime (no host imports, no WASI): adds
#                              memory/table/global/element/data-segment init.
#   /mayhem/fuzz_run         — instantiate then Call one exported numeric
#                              function with fixed (zero) arguments: drives
#                              wazero's interpreter execution engine.
#   /mayhem/kat              — dynamically-linked known-answer probe used by
#                              mayhem/test.sh.
#
# Upstream is NOT an OSS-Fuzz project. It ships a cargo-fuzz differential
# fuzzer at internal/integration_test/fuzz/ that drives Go via CGO from Rust —
# a different toolchain, not portable here (see docs/netnew-worker-prompt.md's
# repo-specific intel). These three harnesses are new, written directly
# against wazero's public API with go-118-fuzz-build.
#
# STAGING DIRS (see docs/netnew-worker-prompt.md §6): wazero's repo root mixes
# `package wazero` and `package wazero_test` files (runtime.go vs
# example_test.go, etc.), which go-118-fuzz-build's package loader rejects
# ("found packages wazero and wazero_test"). Each harness only needs wazero's
# PUBLIC API, so each is copied into its own FRESH, single-file package
# directory under `_mayhem_harness/` (leading underscore: every Go tool
# ignores it for wildcard patterns) and go-118-fuzz-build is pointed at that
# directory explicitly rather than at the repo root.
#
# BOUNDING (SPEC intel / §6b): all three harnesses run an untrusted,
# fuzzer-supplied Wasm module. fuzz_instantiate and fuzz_run configure
# RuntimeConfig.WithMemoryLimitPages(16) (1 MiB cap) and
# WithCloseOnContextDone(true), and wrap InstantiateModule/Call in a
# context.WithTimeout — verified empirically (see harness_run_test.go.src)
# to force-terminate a hand-crafted `loop; br 0; end` in ~300ms instead of
# hanging. See the harness .go.src files for the full rationale.
#
# Go path is ASan-only for the libFuzzer link (as OSS-Fuzz's Go path is): the .a
# archive carries the Go fuzz code instrumented by go-118-fuzz-build, then clang++
# links it against the libFuzzer engine.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 with no
# downgrade knob. The C/CGO shims clang compiles (the LLVMFuzzerTestOneInput
# wrapper, the CGO bridge) default to DWARF5 under clang-19, so we force them —
# and the final link — to DWARF3 via $GO_DEBUG_FLAGS. verify-repo reads the FIRST
# CU's DWARF version, which is the C shim at DWARF3, satisfying the < 4 gate.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script OFFLINE.
# This first (online) build populates $GOMODCACHE under /opt/toolchains; the cache
# doubles as a file proxy, which GOPROXY prefers, so the offline re-run resolves
# from it. Re-running on an already-built tree must succeed (idempotent).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# ASan-only for the Go libFuzzer link. An explicit empty --build-arg SANITIZER_FLAGS=
# yields a no-sanitizer (natural-crash) build, so default with `=` not `:=`.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# DWARF3 for every clang-compiled shim + the final link (see header).
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Offline-first module resolution. $(go env GOMODCACHE) reads the pinned ENV from
# the Dockerfile, so this path is right under ANY $HOME (CI or the PATCH re-run).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-118-fuzz-build rewrites the stdlib `testing` import to its own shim, which must
# be on the module graph. Order matters: tidy FIRST, then `go get` the shim — a
# trailing tidy would prune it again (nothing imports it until the builder generates
# the entrypoint). Both resolve from the module cache when offline.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# The three harnesses ship as .go.src so they are never compiled as ordinary
# root-package files; copy each into its OWN fresh, single-file package
# directory under `_mayhem_harness/` (idempotent: rm -rf then mkdir). See the
# header comment for why the repo root itself cannot be used.
rm -rf "$SRC/_mayhem_harness"
mkdir -p "$SRC/_mayhem_harness/decode" "$SRC/_mayhem_harness/instantiate" "$SRC/_mayhem_harness/run"
cp -f "$SRC/mayhem/harness_decode_test.go.src"      "$SRC/_mayhem_harness/decode/harness_test.go"
cp -f "$SRC/mayhem/harness_instantiate_test.go.src" "$SRC/_mayhem_harness/instantiate/harness_test.go"
cp -f "$SRC/mayhem/harness_run_test.go.src"         "$SRC/_mayhem_harness/run/harness_test.go"

# build_target <output-name> <fuzz-func> <package-dir>
build_target() {
  local target="$1" func="$2" pkgdir="$3"
  echo "=== building $target ($func in $pkgdir, go-118-fuzz-build) ==="
  go-118-fuzz-build -o "$SRC/mayhem-build/$target.a" -func "$func" "$pkgdir"
  # shellcheck disable=SC2086  # word-splitting of the flag lists is intended
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
      "$SRC/mayhem-build/$target.a" -o "/mayhem/$target"
  echo "built /mayhem/$target"
}

build_target fuzz_decode      FuzzMayhemDecode      "$SRC/_mayhem_harness/decode"
build_target fuzz_instantiate FuzzMayhemInstantiate "$SRC/_mayhem_harness/instantiate"
build_target fuzz_run         FuzzMayhemRun         "$SRC/_mayhem_harness/run"

# ── Per-target dictionaries (Wasm section IDs + magic; docs/seed-corpus.md) ──
# Referenced by each Mayhemfile as /mayhem/<target>.dict — copy from the
# tracked per-target location into that top-level image path, or libFuzzer
# exits 1 at 0 edges on a referenced-but-absent dict.
for t in fuzz_decode fuzz_instantiate fuzz_run; do
  cp -f "$SRC/mayhem/$t/$t.dict" "/mayhem/$t.dict"
done

# ── The KAT probe used by mayhem/test.sh (NORMAL flags — it is a functional oracle,
#    not a triage artifact, so no sanitizer/fuzz instrumentation here). ───────────
# CGO_ENABLED=1 + the `import "C"` file force EXTERNAL linking so the probe is
# DYNAMICALLY linked and therefore reachable by verify-repo's LD_PRELOAD sabotage
# shim (SPEC §6.3). Assert that, so a toolchain change can't silently turn the
# probe static and weaken the oracle to a `go test`-only pass.
echo "=== building /mayhem/kat (KAT probe, cgo => dynamically linked) ==="
CGO_ENABLED=1 CGO_CFLAGS="$GO_DEBUG_FLAGS" go build -o /mayhem/kat ./mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# Go's `go test` compiles on demand, so there is no separate test-suite build step;
# mayhem/test.sh runs `go test ./...` with the project's normal flags (this
# includes the vendored WebAssembly spec-test suite under
# internal/integration_test/spectest/ — a genuine conformance KAT).

echo "build.sh complete:"
ls -la /mayhem/fuzz_decode /mayhem/fuzz_instantiate /mayhem/fuzz_run /mayhem/kat \
       /mayhem/fuzz_decode.dict /mayhem/fuzz_instantiate.dict /mayhem/fuzz_run.dict
