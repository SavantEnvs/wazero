// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so the verify-repo sabotage check (which
// LD_PRELOADs a shim whose constructor calls _exit(0) for non-system executables)
// cannot neuter it — a suite that only runs `go test` is therefore immune to the
// sabotage check and does NOT prove the oracle is behavioral. This probe is built
// with cgo (see cgo_dynamic.go) so it is DYNAMICALLY linked: the shim reaches it,
// the process becomes an instant no-op, it prints nothing, and test.sh's exact
// string assertions below fail. That is what makes the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it compiles+instantiates+calls a
// small, hand-assembled WebAssembly module through wazero's PUBLIC API — the
// exact byte encoding is documented below — and asserts the EXACT computed
// results of two calls plus two module-introspection facts. A patch that stubs
// the decoder/engine to dodge a crash cannot reproduce these values.
//
// The module (18 + ... bytes, no wat2wasm/toolchain dependency — assembled by
// hand so the probe has zero build-time dependencies beyond wazero itself)
// declares one function type (i32,i32)->i32, one function using it (locals:
// none; body: local.get 0; local.get 1; i32.add; end), and exports it as "add":
//
//	00 61 73 6D 01 00 00 00              ; \0asm, version 1
//	01 07 01 60 02 7F 7F 01 7F           ; type section: (i32,i32)->i32
//	03 02 01 00                          ; function section: fn 0 uses type 0
//	07 07 01 03 61 64 64 00 00           ; export section: "add" -> func 0
//	0A 09 01 07 00 20 00 20 01 6A 0B     ; code section: local.get 0; local.get 1; i32.add; end
//
// Prints four lines, which test.sh matches EXACTLY:
//
//	KAT_EXPORT_COUNT=<number of exported functions>
//	KAT_EXPORT_NAME=<the sole export's name>
//	KAT_ADD_1=<add(7,35)>
//	KAT_ADD_2=<add(100,23)>
//
// Two distinct calls (not just one) guard against a "stubbed" add that always
// returns a fixed constant regardless of input.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/tetratelabs/wazero"
)

// addWasm is the hand-assembled module described above.
var addWasm = []byte{
	0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
	0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F,
	0x03, 0x02, 0x01, 0x00,
	0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
	0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B,
}

func main() {
	ctx := context.Background()
	r := wazero.NewRuntime(ctx)
	defer r.Close(ctx)

	compiled, err := r.CompileModule(ctx, addWasm)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: CompileModule: %v\n", err)
		os.Exit(1)
	}

	exports := compiled.ExportedFunctions()
	fmt.Printf("KAT_EXPORT_COUNT=%d\n", len(exports))
	for name := range exports {
		fmt.Printf("KAT_EXPORT_NAME=%s\n", name)
	}

	mod, err := r.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithStartFunctions())
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: InstantiateModule: %v\n", err)
		os.Exit(1)
	}
	defer mod.Close(ctx)

	add := mod.ExportedFunction("add")
	if add == nil {
		fmt.Fprintln(os.Stderr, "kat: export \"add\" not found")
		os.Exit(1)
	}

	res1, err := add.Call(ctx, 7, 35)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: add(7,35): %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_ADD_1=%d\n", int32(res1[0]))

	res2, err := add.Call(ctx, 100, 23)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: add(100,23): %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_ADD_2=%d\n", int32(res2[0]))
}
