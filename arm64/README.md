# arm64/ — Nihil on macOS (Apple silicon), the runtime

- rt.c: the runtime, every routine of src/runtime.asm (the 47 of the jump table), in C for
  clang. Heap and conservative collector, texts, arrays, arithmetic, output and errors,
  input, files and tables (atomic writes with F_FULLFSYNC, positional reads with size and
  stamp), network (TCP server), JSON value end, record parsing (Clinger), and the prelude's
  kernel calls translated from Linux numbers and layouts to libSystem.
- fib.s: phase 0, what the compiler will emit for a small program (by hand).
- Tests (each prints "all passed"; build with -DGC_STRESS for a collection every 256 KiB):
    clang -O2 -arch arm64 -o T rt.c T.c globals_test.s && ./T
  for T in gc_test rt_test file_test net_test sys_test (out_test: output, input and errors,
  run as ./out_test < some_file). bench_rec.c: table reading speed (~650 MB/s on an M4).
