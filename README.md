<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <img src="assets/logo.png" width="320" alt="Nihil">
  </picture>
</p>

# Nihil

A minimalist language with **no keywords**, compiled straight to x86_64 ELF64
machine code: no libc, no linker, no VM. The name is Latin for
*nothing*: there are no keywords at all, only symbols, and `_` is the value that
is not there.

The full specification is in [SPEC.md](SPEC.md).

```text
fib(n = 0) {
    n < 2 { : n; }                 // a BOOL before "{" is an if; ":" returns
    : fib(n - 1) + fib(n - 2);
}

find(v = [0], x = 0) {
    i = 0;
    * i < #v {                     // "*" is a while loop
        v[i] == x { : i; }
        i = i + 1;
    }
    : _;                           // "_" is "no value": find returns INT?
}

>> fib(30); >> "\n";               // 832040
pos = find([5, 8, 13], 8) || -1;   // "||" takes the value, or the fallback
3 { >> pos; }                      // an INT before "{" repeats the block
>> "\n";
>> 0.1 + 0.2; >> "\n";             // 0.30000000000000004
```

## Building and testing

Requires Linux on x86_64, `nasm` and `ld`.

```sh
make                 # build/nihilc (stage 0, assembly) and build/nihilc1 (stage 1, Nihil)
make test            # the test suite with nihilc
make test1           # the suite plus the stage 1 tests, with nihilc1
make test1-O0        # the same, without optimizations
make compare         # nihilc and nihilc1 -O0 produce identical bytes for every test program
make fixedpoint      # nihilc1 compiles itself to a fixed point
make floatcheck      # FLOAT ⇄ text conversions checked against Python

./build/nihilc program.nihil program && ./program
./nihilc1.sh program.nihil program && ./program
```

## Status

All 9 milestones of the original plan are done:

1. Infrastructure and the ELF writer.
2. Lexer and expressions.
3. Control flow.
4. Methods and recursion.
5. Arrays, strings and raw bytes.
6. **Self-hosting**: the compiler written in Nihil (`src1/`) compiles itself, and
   without optimizations produces exactly the same bytes as the assembly
   compiler. Then `::`, `!>>`, file reading (`@`), `$` and inclusion
   (`@ "file.nihil";`).
7. Optionals (`x? = 1`, `_`, `x || default`, `x == _`).
8. FLOAT (exact literals, shortest round-trip printing, `.n` and `#f`), `<<`
   input and STRING `+`.
9. Optimizations: registers, `inc`, fused compare-and-branch, `cmov`
   (`NIHIL_O0=1` turns them off).

After the plan: `... ms;` (sleep), `@>> path, text;` and `@+>> path, text;`
(write and append files, crash-safe), data models and records that map to
fixed-width table files (`PRODUCT = @[code: INT(6); name: STRING(30)];`), read whole
(`PRODUCT @ path`) or one record at a time (`PRODUCT @[i] path`, `PRODUCT @# path`),
one record changed in place (`@[i]>> path, r;`), keys with an index on disk
(`@[#code: INT(6); …]`, `PRODUCT @{42} path`, `@{}>> path, p;`, `PRODUCT @{42} path = _;`), and `examples/doom_fire.nihil`, the PSX Doom
fire effect on a 24-bit color terminal (`./nihilc1.sh examples/doom_fire.nihil fire && ./fire`).

## IDE

`ide/` is a small web IDE (Python standard library, nothing to install):

```sh
python3 ide/server.py            # then open http://<this machine>:8730
```

Editor with Nihil highlighting, a color terminal for the program's output and
input, compile errors marked in the code (also in included files), an
optimization switch and the generated machine code. Files are saved in
`ide/workspace/` and `examples/`. **It runs any code it receives: use it only on
a trusted network** (`--host 127.0.0.1` keeps it local).

Since M7 the assembly compiler is frozen and only bootstraps; new features go
into the compiler written in Nihil (SPEC §17).

## Layout

| Path | Contents |
|---|---|
| `src/nihilc.asm`, `src/commands.inc` | stage 0 compiler (assembly): lexer, expressions, symbols, emission; commands and methods |
| `src/runtime.asm`, `src/layout.inc` | routines embedded in every executable; shared addresses |
| `src1/` | stage 1 compiler, written in Nihil (`nihilc1.nihil` lists the parts) |
| `src1/bigint.nihil`, `float_text.nihil`, `prelude.nihil` | the prelude: big integers, FLOAT ⇄ text, `<<` |
| `nihilc1.sh` | stage 1 command line (same as `nihilc`) |
| `tests/` | test suite (`tests/stage1/` for stage-1-only features) |
| `examples/` | example programs (the Doom fire) |
| `ide/` | the web IDE (`server.py`, `static/index.html`, `workspace/`) |
| `assets/` | the logo: `logo.png` (light backgrounds), `logo-dark.png` (dark), `logo-source.png` (original) |

## License

MIT: see [LICENSE](LICENSE). Use it for anything, keeping the copyright notice.
