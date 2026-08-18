# Known finding: unbounded allocation from a Wasm name length (OOM)

**Reproducer:** `oom-export-name-size.bin` (38 bytes). It makes `fuzz_decode`, `fuzz_instantiate`
and `fuzz_run` abort with `libFuzzer: out-of-memory (used: ~2.5 GB; limit: 2048 MB)`.
It is deliberately outside `testsuite/`, because seeds are replayed every run.

**Cause (upstream, wazero):** `decodeUTF8` in `internal/wasm/binary/value.go` reads a LEB128 `uint32`
name length and runs `make([]byte, size)` *before* checking that `size` bytes remain in the section.
A module whose export name claims up to 4 GiB allocates that much, then fails with `unexpected EOF`.
Several such exports in one section multiply the cost (about 6-26 GB allocated per input).

**Why the stack has no wazero frame:** the allocation is made by the Go runtime, which ASan does not
see. libFuzzer's RSS watchdog catches it, so the defect reports only libFuzzer driver frames.

**Scope:** all 19 crashers of `fuzz-run` run 10 replay to this cause. Each failed with an export-section
error in `CompileModule`, with 6-26 GB allocated. `WithMemoryLimitPages(16)` does not apply because
decoding happens before any memory exists, and wazero has no public option that bounds decoder allocations.

**Fix (one line, upstream):** reject `size > r.Len()` before allocating in `decodeUTF8`
(and in the other length-prefixed readers).

The harnesses leave it unguarded: a filter or a lowered `-rss_limit_mb` would only hide a real DoS.
