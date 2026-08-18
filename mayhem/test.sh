#!/usr/bin/env bash
#
# wazero/mayhem/test.sh — RUN the project's own Go test suite (which includes
# the vendored WebAssembly spec-test suite) and a known-answer probe, and emit
# a CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `go test ./...` — upstream's suite is a genuine conformance suite: it
#     decodes/instantiates/runs the OFFICIAL WebAssembly spec-test binaries
#     under internal/integration_test/spectest/{v1,v2,exception-handling,
#     extended-const,tail-call,threads,typed-function-references}/ and asserts
#     exact results/traps per assertion, plus hundreds of unit tests
#     hand-asserting decoded/instantiated/executed behaviour throughout the
#     repo (config_test.go, runtime_test.go, etc.). This is BEHAVIOUR, not
#     "exits 0" — thousands of real conformance cases.
#
#  2) The KAT probe /mayhem/kat — because `go test` links a STATIC binary, the
#     verify-repo sabotage check (LD_PRELOAD a shim whose constructor _exit(0)s every
#     non-system executable) CANNOT neuter it. A `go test`-only oracle therefore
#     survives sabotage while proving nothing, which is exactly the reward-hackable
#     case the spec forbids. /mayhem/kat is built with cgo => DYNAMICALLY linked, so
#     the shim does neuter it; it then prints nothing and the exact-match assertions
#     below fail. The probe compiles+instantiates+calls a small hand-assembled Wasm
#     module THROUGH WAZERO ITSELF and asserts the exact computed results of two
#     distinct calls plus two module-introspection facts (see mayhem/kat/main.go for
#     the exact byte encoding) — a patch that stubs the decoder/engine to dodge a
#     crash cannot reproduce these values.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own Go suite (incl. the vendored Wasm spec-test suite) ──────
if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
mkdir -p "$SRC/mayhem-build"
JSON="$SRC/mayhem-build/gotest.json"
# The suite is large (spec-test conformance + unit tests across the whole
# runtime); give it real parallelism but stay honest — no -short shortcuts,
# this IS the oracle.
#
# ONE case is excluded, and only when the container is memory-capped:
# TestEngineInterpreter/huge_binary (internal/integration_test/engine,
# testHugeBinary) assembles a 40,000-function module and compiles it with the
# INTERPRETER engine. Measured peak RSS is 8168 MiB of LIVE heap — gctrace shows
# 5501->5585->5585 MB, i.e. the whole set survives every GC and is still climbing
# when the cgroup OOM killer takes it. The gate runs every container at
# --memory=8g (gate-common.sh DOCKER_MEM_ARGS), so this case can never complete
# here; it was also still killed at --memory=9g. GOGC, GOMEMLIMIT, GOMAXPROCS,
# -p 1 and -parallel 1 were all measured and none of them help: it is live heap,
# not garbage.
#
# This is not a shortcut around a failing assertion. Upstream excludes the same
# case from its own CI — testHugeBinary opens with `if testing.Short() { t.Skip }`
# (adhoc_test.go:2422) and .github/workflows/commit.yaml runs
# `-timeout 20m -race -short`, so wazero itself never runs it. The identical
# 40,000-function module is still asserted here by TestEngineCompiler/huge_binary
# (peak 1510 MiB), which stays in. We do NOT pass -short, so every other
# Short()-guarded case — TestMemoryLeak and friends — still runs.
#
# The exclusion is conditional on an actual cgroup cap and is reported as a
# SKIP in the CTRF summary, never silently dropped: on an unconstrained host the
# full suite runs, including huge_binary.
GOTEST_SKIP=()
HUGE_BINARY_SKIPPED=0
_mem_limit_bytes() {
  local v
  v=$(cat /sys/fs/cgroup/memory.max 2>/dev/null) || v=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null) || v=max
  [ "$v" = "max" ] && { echo 0; return; }
  echo "$v"
}
_LIM=$(_mem_limit_bytes)
if [ "$_LIM" -gt 0 ] && [ "$_LIM" -lt $((16 * 1024 * 1024 * 1024)) ]; then
  echo "note: cgroup memory cap $((_LIM / 1024 / 1024)) MiB < 16 GiB — excluding TestEngineInterpreter/huge_binary (needs >9 GiB of live heap); TestEngineCompiler/huge_binary still asserts the same module"
  GOTEST_SKIP=(-skip '^TestEngineInterpreter$/^huge_binary$')
  HUGE_BINARY_SKIPPED=1
fi
go test -json -p "${MAYHEM_JOBS:-$(nproc)}" "${GOTEST_SKIP[@]}" ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
tail -30 "$SRC/mayhem-build/gotest.err" 2>/dev/null || true

# Count test-level events only (lines carrying a non-empty "Test" field); package-level
# pass/fail lines have no "Test" field. Subtests count — they are real asserted cases.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"
# -skip makes go omit the case entirely rather than emitting a skip event, so
# account for it explicitly — the CTRF summary must show it as skipped, not vanish.
if [ "$HUGE_BINARY_SKIPPED" = 1 ]; then SKIPPED=$(( SKIPPED + 1 )); fi

echo "go test: passed=$PASSED failed=$FAILED skipped=$SKIPPED (go exit $rc)"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test events parsed — the suite did not run (go exit $rc)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
# Sanity-check the suite actually ran a plausible number of cases (SPEC intel:
# wazero vendors the official Wasm spec-test suite and should report
# thousands — if it reports a handful, the build context is missing files).
if [ "$(( PASSED + FAILED + SKIPPED ))" -lt 1000 ]; then
  echo "FAIL: only $(( PASSED + FAILED + SKIPPED )) test cases ran — wazero's spec-test" >&2
  echo "      suite alone is thousands of cases; the build context is likely missing" >&2
  echo "      files (check for a stripped .dockerignore)." >&2
  FAILED=$(( FAILED + 1 ))
fi
# A non-zero go exit with zero counted failures means a build/vet error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. The
# probe needs no input fixture — it assembles its own known Wasm module.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts computed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or the runtime is broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "sole export count"        'KAT_EXPORT_COUNT=1'
kat_expect "sole export name"         'KAT_EXPORT_NAME=add'
kat_expect "add(7,35) == 42"          'KAT_ADD_1=42'
kat_expect "add(100,23) == 123"       'KAT_ADD_2=123'

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
