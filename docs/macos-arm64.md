# Nihil on macOS (Apple silicon, ARM64) — the port

## The target

- The compiler writes **ARM64 assembly text** (`.s`); `clang -arch arm64` assembles it, links
  it with libSystem and signs it (ad-hoc), which macOS requires. No Mach-O writer, no code
  signing and no ARM64 encoder of our own at first; direct emission can come later.
- The kernel is reached through **libSystem** (`write`, `read`, `mmap`, `open`, `socket`,
  `posix_spawn`, `exit` …): macOS does not keep its system call numbers stable.
- Code is position independent (`adrp`/`add` for globals and texts): macOS does not load
  programs at a fixed address, so the x86 absolute addressing (`[disp32]`) has no equivalent.
- Registers: x86 `rax` → `x0` (the value), `rdx` → `x1` (an optional's presence), `rbp` →
  `x29` (the frame). The stack stays 16-byte aligned, so a push takes 16 bytes
  (`str x0, [sp, #-16]!`). The optimizer's registers (`FLAG_REG`) go to x19–x28.
- Texts and arrays keep their layout: the length in the 8 bytes before the data.

## Phases

0. **Done: the path works.** `arm64/runtime.s` (output buffer, numbers, texts, exit) and
   `arm64/fib.s` (what the compiler will emit for a small program, by hand, in its
   stack-machine style). `clang -arch arm64 -o fib runtime.s fib.s` gives a signed Mach-O that
   prints the right numbers; fib(35) and the first 31 in 0.12 s on an M4.
1. **The runtime in ARM64** (on the Mac, now): every routine of `src/runtime.asm` (2,600 lines)
   — the heap and arrays (`mmap`), the conservative garbage collector (stack and registers),
   texts, input (`<<`, `<<<`), files and tables (`open`, `pread`, `pwrite`, `fstat`), runtime
   errors, the native helpers (record parsing, JSON value end, copies), time, network
   (`socket`, `bind`, `accept` …) and processes (`posix_spawn`, `waitpid`, `kill`). Tested
   with hand-written callers, as phase 0.
2. **A backend layer in the compiler** (needs Linux x86_64 to build): the 410 places that emit
   x86 bytes (`40_emit`, `47_records`, `48_library`, `49_maps`, `50_expressions`,
   `60_commands`, `80_main` …) go through named operations (load a local, push, pop, compare,
   call a runtime routine …). The x86 output must stay byte for byte the same: `make compare`
   and `make fixedpoint` prove it at every step. Then an ARM64 implementation of the same
   operations that writes text.
3. **Cross-compiling**: `nihilc1 --target=macos-arm64 prog.nihil` on Linux writes `prog.s`;
   on the Mac, `clang` and the test battery (`tests/`, the same expected outputs).
4. **Self-hosting**: `nihilc1` compiled for macOS, compiling on the Mac (it calls `clang`), and
   the fixed point there (the Mac compiler compiles itself to the same text).
5. **The optimizer** on ARM64 (registers x19–x28; `-O` and `-O0` give the same results).
6. **The tools**: `make` targets for the Mac, the IDE server and the MCP server on the Mac.

Stage 0 (`src/nihilc.asm`, NASM) stays as it is: it only builds stage 1 on Linux, and the
first macOS compiler comes from stage 1 (phase 3).
