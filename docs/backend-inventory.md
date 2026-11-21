# The backend layer — an inventory of what the compiler emits (phase 2 of the macOS port)

Made from the source at commit c304594: every line of `src1/*.nihil` (not the prelude) that emits
bytes, its x86 instruction (the constant bytes of the line, assembled and disassembled with
`clang -target x86_64` and `objdump`), and the backend operation it becomes, with its ARM64 text.

## Numbers

- **416 lines emit bytes**: 195 with raw bytes (`eb(…)`, `emit(0x…)`), 99 that only add the
  operand of the line above (a displacement or an immediate: `emit_d`, `emit_q`), and the rest
  inside the helpers of `40_emit.nihil`.
- **Already semantic** (they become backend operations as they are): `emit_call_rt` (59 calls: a
  runtime routine through the jump table → `bl _nh_<routine>`), `emit_load_var` /
  `emit_store_var` / `emit_store_local` / `emit_store_global`, `emit_immediate`,
  `emit_jmp_to` / `emit_jump_if_false`, `emit_return`, `patch_here` / `register_fixup` (15 + 12:
  positions patched later → labels in the ARM64 text), the constants (`const_put_*`) and the
  ELF writer (`emit_header`, `close_elf` → the `.s` writer and `clang`).
- **Raw sites by file**: 47_records 86, 50_expressions 82, 60_commands 45, 48_library 27,
  49_maps 20, 80_main 5, 30_symbols 2, 45_optionals 1 (40_emit's own 25 are the helpers).

## The register map

| x86 | ARM64 | use |
|---|---|---|
| rax | x0 | the value of an expression |
| rdx | x1 | an optional's presence; a second result |
| rcx | x2 | the right operand, an index |
| rsi, rdi, r8–r11 | x3–x8 | scratch inside a sequence |
| rbp | x29 | the frame (locals at negative offsets) |
| rsp | sp | the expression stack: a push takes 16 bytes (sp stays 16-aligned) |
| rbx, r12–r15 (the optimizer's) | x19–x28 | variables kept in registers (`FLAG_REG`) |
| xmm0, xmm1 | d0, d1 | FLOAT operations (values travel in x0 as bits, `fmov`) |

Calls to the runtime follow the standard ARM64 convention (arguments in x0–x2, x19–x28 kept),
which is what `arm64/rt.c` expects. Methods keep the compiler's own convention (arguments on
the stack, as on x86), so the frame layout and the optimizer's decisions stay the same.

## Operations

| operation | lines | ARM64 |
|---|---|---|
| operand of the line above | 122 | — |
| push | 72 | `str x0, [sp, #-16]!` |
| immediate(reg, v) | 35 | `mov x0, #v / movz+movk for wide values` |
| other (see the line) | 26 | (by hand) |
| FLOAT operation | 22 | `fmov d0, x0; fadd|fsub|fmul|fdiv d0, d1, d0; fcmp; scvtf; fcvtzs; fneg` |
| move(dst, src) | 16 | `mov x2, x0 …` |
| call / jump (rel32, patched) | 13 | `bl _nh_m_NAME / b Lk / b.cond Lk  (labels: clang resolves them)` |
| frame | 12 | `mov sp, x29; ldp x29, x30, [sp], #16; ret / sub|add sp, sp, #n` |
| test for zero | 10 | `cbz / cbnz / tst` |
| address of a constant | 10 | `adrp x0, Lc@PAGE; add x0, x0, Lc@PAGEOFF` |
| integer operation | 10 | `add|sub|mul|and|orr|eor|lsl|asr x0, x2, x0; neg|mvn x0, x0` |
| local load/store | 9 | `ldur/stur x0, [x29, #-d]  (add for |d| > 255)` |
| element / length load | 9 | `ldr x0, [x0, x2, lsl #3]; ldrb w0, [x0, x2]; ldur x0, [x0, #-8]` |
| pop_into(reg) | 7 | `ldr x2, [sp], #16   (rcx → x2, rax → x0)` |
| increment in memory | 7 | `ldr x9, …; add x9, x9, #1; str x9, …` |
| push_presence | 6 | `str x1, [sp, #-16]!   (with push: stp x0, x1, [sp, #-16]!)` |
| condition to BOOL | 6 | `cset x0, eq|ne|vs|vc …; csel` |
| compare | 6 | `cmp x2, x0  (operand order kept)` |
| global load/store | 5 | `adrp x9, _nh_g@PAGE; ldr/str x0, [x9, _nh_g@PAGEOFF]` |
| element store | 5 | `str x0, [x2, x1, lsl #3] …` |
| frame / copy top | 4 | `stp x29, x30, [sp, #-16]! / ldr x9, [sp]; str x9, [sp, #-16]!` |
| immediate(rax, v) | 2 | `mov x0, #v / movz+movk` |
| bounds check | 2 | `ldur x9, [x0, #-8]; cmp x2, x9; b.hs Lindex_error` |

## Steps (phase 2), each one checked with `make compare fixedpoint test1 test1-O0 gcstress`

1. **A backend file** (`src1/41_backend.nihil`) with the operations above, their x86 bodies taken
   from the raw sites, one file of the compiler at a time (records, expressions, commands,
   library, maps). The x86 output must stay identical byte for byte at every step.
2. **Labels instead of patched positions**: `patch_here` / `register_fixup` / `move_code_back`
   work on byte positions; they become label numbers that the x86 backend still resolves to
   rel32 displacements (identical bytes) and the ARM64 backend writes as `Lk:`.
3. **The target switch** (`--target=macos-arm64`): each operation writes ARM64 text into a text
   buffer; constants and globals go to `.data` with `_nh_globals_start` / `_nh_globals_end`
   around the globals; the end writes `prog.s` and runs `clang -arch arm64 prog.s arm64/rt.c`.
4. **The test battery on the Mac**: the same `tests/` with their expected outputs, through the
   cross-compiler (phase 3), then the compiler compiled for the Mac (phase 4).

## Every line, by file


### 30_symbols.nihil

| line | x86 | operation |
|---|---|---|
| 126 | `call N` | call / jump (rel32, patched) |
| 128 | `int3` | operand of the line above |
| 130 | `add rsp, N` | frame |
| 131 | `int3` | operand of the line above |

### 40_emit.nihil

| line | x86 | operation |
|---|---|---|
| 13 | `(operand bytes / continuation)` | operand of the line above |
| 14 | `(operand bytes / continuation)` | operand of the line above |
| 15 | `(operand bytes / continuation)` | operand of the line above |
| 16 | `(operand bytes / continuation)` | operand of the line above |
| 17 | `(operand bytes / continuation)` | operand of the line above |
| 18 | `(operand bytes / continuation)` | operand of the line above |
| 19 | `(operand bytes / continuation)` | operand of the line above |
| 20 | `(operand bytes / continuation)` | operand of the line above |
| 21 | `(operand bytes / continuation)` | operand of the line above |
| 25 | `(operand bytes / continuation)` | operand of the line above |
| 26 | `(operand bytes / continuation)` | operand of the line above |
| 30 | `(operand bytes / continuation)` | operand of the line above |
| 31 | `(operand bytes / continuation)` | operand of the line above |
| 32 | `(operand bytes / continuation)` | operand of the line above |
| 33 | `(operand bytes / continuation)` | operand of the line above |
| 38 | `(operand bytes / continuation)` | operand of the line above |
| 56 | `mov eax, N` | immediate(reg, v) |
| 57 | `int3` | operand of the line above |
| 59 | `mov rax, N` | immediate(rax, v) |
| 60 | `int3` | operand of the line above |
| 62 | `movabs rax, N` | immediate(rax, v) |
| 63 | `int3` | operand of the line above |
| 68 | `mov qword ptr [rbp], rax` | local load/store |
| 69 | `int3` | operand of the line above |
| 73 | `mov qword ptr [N], rax` | global load/store |
| 74 | `int3` | operand of the line above |
| 83 | `mov rax, qword ptr [N]` | global load/store |
| 84 | `int3` | operand of the line above |
| 86 | `mov rdx, qword ptr [N]` | global load/store |
| 87 | `int3` | operand of the line above |
| 90 | `mov rax, qword ptr [rbp]` | local load/store |
| 91 | `int3` | operand of the line above |
| 93 | `mov rdx, qword ptr [rbp]` | local load/store |
| 94 | `int3` | operand of the line above |
| 107 | `mov qword ptr [N], rdx` | global load/store |
| 108 | `int3` | operand of the line above |
| 113 | `mov qword ptr [rbp], rdx` | local load/store |
| 114 | `int3` | operand of the line above |
| 120 | `jmp N` | call / jump (rel32, patched) |
| 121 | `int3` | operand of the line above |
| 125 | `call N` | call / jump (rel32, patched) |
| 126 | `int3` | operand of the line above |
| 131 | `cmp rcx, qword ptr [rax - N]` | bounds check |
| 132 | `int3` | operand of the line above |
| 146 | `(operand bytes / continuation)` | operand of the line above |
| 150 | `(operand bytes / continuation)` | operand of the line above |
| 156 | `leave` | frame |
| 159 | `lea rsp, [rbp]` | frame |
| 164 | `add byte ptr [r8], al` | other (see the line) |
| 166 | `pop rbp` | frame |
| 228 | `sldt word ptr [rax]` | other (see the line) |
| 230 | `int3` | operand of the line above |
| 233 | `test rax, rax` | test for zero |
| 235 | `int3` | operand of the line above |
| 280 | `int3` | operand of the line above |
| 301 | `jg N` | call / jump (rel32, patched) |
| 302 | `add ah, cl` | other (see the line) |
| 303 | `add byte ptr [rax], al` | other (see the line) |
| 304 | `add byte ptr [rax], al` | other (see the line) |
| 305 | `int3` | operand of the line above |
| 306 | `int3` | operand of the line above |
| 307 | `int3` | operand of the line above |
| 308 | `int3` | operand of the line above |
| 309 | `int3` | operand of the line above |
| 310 | `add byte ptr [rax], al` | other (see the line) |
| 311 | `add byte ptr [rax], al` | other (see the line) |
| 312 | `add byte ptr [rax], al` | other (see the line) |
| 313 | `add byte ptr [rax], al` | other (see the line) |
| 314 | `add byte ptr [rax], al` | other (see the line) |
| 315 | `add byte ptr [rax], al` | other (see the line) |
| 317 | `int3` | operand of the line above |
| 318 | `int3` | operand of the line above |
| 319 | `int3` | operand of the line above |
| 320 | `int3` | operand of the line above |
| 321 | `int3` | operand of the line above |
| 322 | `int3` | operand of the line above |
| 323 | `int3` | operand of the line above |
| 324 | `int3` | operand of the line above |
| 326 | `int3` | operand of the line above |
| 327 | `int3` | operand of the line above |
| 328 | `int3` | operand of the line above |
| 329 | `int3` | operand of the line above |
| 330 | `int3` | operand of the line above |
| 331 | `int3` | operand of the line above |
| 332 | `int3` | operand of the line above |
| 333 | `int3` | operand of the line above |

### 45_optionals.nihil

| line | x86 | operation |
|---|---|---|
| 22 | `mov edx, N` | immediate(reg, v) |

### 47_records.nihil

| line | x86 | operation |
|---|---|---|
| 277 | `mov rax, qword ptr [rax]` | element / length load |
| 283 | `mov rax, qword ptr [rax]` | element / length load |
| 284 | `int3` | operand of the line above |
| 357 | `push rax` | push |
| 372 | `pop rcx` | pop_into(reg) |
| 373 | `int3` | operand of the line above |
| 380 | `mov ecx, N` | immediate(reg, v) |
| 381 | `int3` | operand of the line above |
| 386 | `lea rcx, [rip]              ## N` | address of a constant |
| 388 | `int3` | operand of the line above |
| 389 | `mov qword ptr [rax], rcx` | element store |
| 390 | `int3` | operand of the line above |
| 431 | `push rax` | push |
| 445 | `pop rcx` | pop_into(reg) |
| 446 | `int3` | operand of the line above |
| 453 | `lea rax, [rip]              ## N` | address of a constant |
| 455 | `int3` | operand of the line above |
| 456 | `push rax` | push |
| 468 | `push rax` | push |
| 515 | `push rax` | push |
| 518 | `test rax, rax` | test for zero |
| 519 | `lea rax, [rip]              ## N` | address of a constant |
| 521 | `int3` | operand of the line above |
| 525 | `push rax` | push |
| 544 | `push rax` | push |
| 546 | `push rax` | push |
| 548 | `mov rcx, qword ptr [rsp + N]` | other (see the line) |
| 549 | `imul rcx, rcx, N` | other (see the line) |
| 550 | `int3` | operand of the line above |
| 551 | `mov edx, N` | immediate(reg, v) |
| 552 | `int3` | operand of the line above |
| 554 | `push rax` | push |
| 556 | `mov eax, N` | immediate(reg, v) |
| 557 | `push rax` | push |
| 560 | `xor edx, edx` | immediate(reg, v) |
| 570 | `push rax` | push |
| 571 | `xor ecx, ecx` | immediate(reg, v) |
| 573 | `push rdx` | push_presence |
| 596 | `push rax` | push |
| 601 | `push rax` | push |
| 602 | `push qword ptr [rsp + N]` | frame / copy top |
| 603 | `push qword ptr [rsp + N]` | frame / copy top |
| 610 | `push rax` | push |
| 612 | `mov eax, N` | immediate(reg, v) |
| 613 | `int3` | operand of the line above |
| 614 | `push rax` | push |
| 616 | `add rsp, N` | frame |
| 620 | `push rax` | push |
| 621 | `mov rax, qword ptr [rsp + N]` | other (see the line) |
| 622 | `xor ecx, ecx` | immediate(reg, v) |
| 624 | `push rdx` | push_presence |
| 627 | `mov rcx, rax` | move(dst, src) |
| 628 | `mov rdx, qword ptr [rsp + N]` | other (see the line) |
| 629 | `inc rdx` | other (see the line) |
| 630 | `imul rdx, rdx, N` | other (see the line) |
| 631 | `int3` | operand of the line above |
| 632 | `sub rdx, qword ptr [rcx - N]` | other (see the line) |
| 633 | `pop rax` | pop_into(reg) |
| 634 | `add rsp, N` | frame |
| 645 | `add rsp, N` | frame |
| 667 | `push rax` | push |
| 669 | `mov eax, N` | immediate(reg, v) |
| 670 | `int3` | operand of the line above |
| 671 | `push rax` | push |
| 672 | `mov eax, N` | immediate(reg, v) |
| 673 | `push rax` | push |
| 676 | `xor edx, edx` | immediate(reg, v) |
| 704 | `push rax` | push |
| 729 | `push rax` | push |
| 731 | `mov eax, N` | immediate(reg, v) |
| 732 | `int3` | operand of the line above |
| 733 | `push rax` | push |
| 734 | `mov eax, N` | immediate(reg, v) |
| 735 | `push rax` | push |
| 754 | `push rax` | push |
| 761 | `push rax` | push |
| 763 | `mov eax, N` | immediate(reg, v) |
| 764 | `int3` | operand of the line above |
| 765 | `push rax` | push |
| 775 | `add rsp, N` | frame |
| 790 | `xor ecx, ecx` | immediate(reg, v) |
| 792 | `mov rax, rdx` | move(dst, src) |
| 796 | `push rax` | push |
| 800 | `mov rdx, rax` | move(dst, src) |
| 806 | `push rax` | push |
| 810 | `mov rdx, rax` | move(dst, src) |
| 815 | `mov rcx, rax` | move(dst, src) |
| 836 | `push rax` | push |
| 839 | `mov rcx, rax` | move(dst, src) |
| 854 | `push rax` | push |
| 857 | `push rax` | push |
| 860 | `mov rdx, rax` | move(dst, src) |
| 876 | `push rax` | push |
| 879 | `mov rcx, rax` | move(dst, src) |
| 904 | `push rax` | push |
| 905 | `lea rcx, [rax + N]` | other (see the line) |
| 906 | `shr rcx, N` | other (see the line) |
| 908 | `pop rcx` | pop_into(reg) |
| 912 | `push rax` | push |
| 915 | `push rax` | push |
| 918 | `pop rcx` | pop_into(reg) |

### 48_library.nihil

| line | x86 | operation |
|---|---|---|
| 182 | `push rax` | push |
| 224 | `push rax` | push |
| 240 | `mov rax, qword ptr [rbp]` | local load/store |
| 241 | `mov rcx, qword ptr [rbp]` | local load/store |
| 242 | `mov rdx, qword ptr [rbp]` | local load/store |
| 243 | `int3` | operand of the line above |
| 247 | `mov qword ptr [rbp], rax` | local load/store |
| 248 | `int3` | operand of the line above |
| 252 | `mov qword ptr [rbp], N` | local load/store |
| 253 | `int3` | operand of the line above |
| 254 | `int3` | operand of the line above |
| 258 | `inc qword ptr [rbp]` | increment in memory |
| 259 | `int3` | operand of the line above |
| 268 | `mov rax, qword ptr [rax]` | element / length load |
| 269 | `int3` | operand of the line above |
| 318 | `mov rcx, qword ptr [rax - N]` | element / length load |
| 326 | `cmp rax, qword ptr [rcx - N]` | bounds check |
| 327 | `jge N` | call / jump (rel32, patched) |
| 329 | `int3` | operand of the line above |
| 330 | `mov rax, qword ptr [rcx + N*rax]` | element / length load |
| 341 | `test rax, rax` | test for zero |
| 343 | `int3` | operand of the line above |
| 348 | `mov qword ptr [rcx + N*rdx], rax` | element store |
| 356 | `jmp N` | call / jump (rel32, patched) |
| 358 | `int3` | operand of the line above |
| 367 | `mov qword ptr [rcx + N*rdx], rax` | element store |
| 372 | `movq xmm0, qword ptr [rbp]` | FLOAT operation |
| 373 | `int3` | operand of the line above |
| 374 | `movq xmm1, rax` | FLOAT operation |
| 375 | `addsd xmm0, xmm1` | FLOAT operation |
| 376 | `movq qword ptr [rbp], xmm0` | FLOAT operation |
| 377 | `int3` | operand of the line above |
| 379 | `add qword ptr [rbp], rax` | increment in memory |
| 380 | `int3` | operand of the line above |
| 393 | `mov qword ptr [rax - N], rcx` | element store |
| 403 | `push rax` | push |
| 405 | `push rax` | push |
| 406 | `mov eax, N` | immediate(reg, v) |
| 407 | `int3` | operand of the line above |
| 408 | `push rax` | push |

### 49_maps.nihil

| line | x86 | operation |
|---|---|---|
| 36 | `mov eax, N` | immediate(reg, v) |
| 37 | `int3` | operand of the line above |
| 38 | `push rax` | push |
| 43 | `xor eax, eax` | immediate(reg, v) |
| 72 | `push rax` | push |
| 83 | `push rax` | push |
| 99 | `push rax` | push |
| 102 | `add rsp, N` | frame |
| 107 | `xor eax, eax` | immediate(reg, v) |
| 111 | `push rax` | push |
| 120 | `push rax` | push |
| 125 | `push rax` | push |
| 127 | `push rax` | push |
| 153 | `push rax` | push |
| 159 | `push rax` | push |
| 168 | `push rax` | push |
| 174 | `push rax` | push |
| 186 | `push rax` | push |
| 197 | `push rax` | push |
| 202 | `push rax` | push |
| 209 | `push rax` | push |

### 50_expressions.nihil

| line | x86 | operation |
|---|---|---|
| 26 | `test rdx, rdx` | test for zero |
| 28 | `int3` | operand of the line above |
| 36 | `cmove rax, rcx` | condition to BOOL |
| 62 | `test rax, rax` | test for zero |
| 64 | `int3` | operand of the line above |
| 86 | `test rax, rax` | test for zero |
| 88 | `int3` | operand of the line above |
| 120 | `cmp rax, rcx` | compare |
| 121 | `cmp rax, rcx` | compare |
| 122 | `cmp rax, rcx` | compare |
| 123 | `cmp rax, rcx` | compare |
| 124 | `cmp rax, rcx` | compare |
| 125 | `cmp rax, rcx` | compare |
| 126 | `or rax, rcx` | integer operation |
| 127 | `xor rax, rcx` | integer operation |
| 128 | `and rax, rcx` | integer operation |
| 129 | `shl rax, cl` | integer operation |
| 130 | `sar rax, cl` | integer operation |
| 131 | `add rax, rcx` | integer operation |
| 132 | `sub rax, rcx` | integer operation |
| 133 | `imul rax, rcx` | integer operation |
| 143 | `movq xmm0, rax` | FLOAT operation |
| 144 | `movq xmm1, rcx` | FLOAT operation |
| 146 | `addsd xmm0, xmm1` | FLOAT operation |
| 147 | `subsd xmm0, xmm1` | FLOAT operation |
| 148 | `mulsd xmm0, xmm1` | FLOAT operation |
| 149 | `divsd xmm0, xmm1` | FLOAT operation |
| 150 | `movq rax, xmm0` | FLOAT operation |
| 155 | `ucomisd xmm0, xmm1` | FLOAT operation |
| 157 | `ucomisd xmm0, xmm1` | FLOAT operation |
| 159 | `ucomisd xmm1, xmm0` | FLOAT operation |
| 161 | `ucomisd xmm1, xmm0` | FLOAT operation |
| 163 | `ucomisd xmm0, xmm1` | FLOAT operation |
| 164 | `setnp cl` | condition to BOOL |
| 166 | `ucomisd xmm0, xmm1` | FLOAT operation |
| 167 | `setp cl` | condition to BOOL |
| 169 | `movzx eax, al` | condition to BOOL |
| 191 | `test rdx, rdx` | test for zero |
| 193 | `sete al` | condition to BOOL |
| 195 | `setne al` | condition to BOOL |
| 204 | `push rax` | push |
| 211 | `mov rcx, rax` | move(dst, src) |
| 235 | `xor eax, N` | immediate(reg, v) |
| 262 | `mov rax, qword ptr [rax]` | element / length load |
| 268 | `xor edx, edx` | immediate(reg, v) |
| 272 | `btc rax, N` | FLOAT operation |
| 277 | `cvtsi2sd xmm0, rax` | FLOAT operation |
| 278 | `movq rax, xmm0` | FLOAT operation |
| 282 | `movq xmm0, rax` | FLOAT operation |
| 283 | `cvttsd2si rax, xmm0` | FLOAT operation |
| 288 | `neg rax` | integer operation |
| 293 | `xor eax, N` | immediate(reg, v) |
| 298 | `not rax` | integer operation |
| 315 | `push rax` | push |
| 320 | `mov rdx, rax` | move(dst, src) |
| 321 | `lea rax, [rip]              ## N` | address of a constant |
| 323 | `int3` | operand of the line above |
| 324 | `lea rcx, [rip]              ## N` | address of a constant |
| 326 | `int3` | operand of the line above |
| 327 | `test rdx, rdx` | test for zero |
| 336 | `mov rax, qword ptr [rax - N]` | element / length load |
| 373 | `push rax` | push |
| 383 | `mov rcx, rax` | move(dst, src) |
| 386 | `movzx eax, byte ptr [rax + rcx]` | element / length load |
| 389 | `mov rax, qword ptr [rax + N*rcx]` | element / length load |
| 408 | `mov eax, N` | immediate(reg, v) |
| 413 | `xor eax, eax` | immediate(reg, v) |
| 418 | `lea rax, [rip]              ## N` | address of a constant |
| 420 | `int3` | operand of the line above |
| 432 | `xor eax, eax` | immediate(reg, v) |
| 558 | `push rax` | push |
| 571 | `push rax` | push |
| 575 | `mov rcx, rax` | move(dst, src) |
| 581 | `push rax` | push |
| 596 | `push rax` | push |
| 600 | `mov ecx, N` | immediate(reg, v) |
| 601 | `int3` | operand of the line above |
| 606 | `pop rcx` | pop_into(reg) |
| 607 | `int3` | operand of the line above |
| 672 | `push rdx` | push_presence |
| 673 | `push rax` | push |
| 687 | `mov ecx, N` | immediate(reg, v) |
| 689 | `push rax` | push |
| 691 | `mov rcx, qword ptr [rsp]` | other (see the line) |
| 696 | `mov edx, N` | immediate(reg, v) |
| 697 | `push rdx` | push_presence |
| 699 | `push rax` | push |
| 704 | `call N` | call / jump (rel32, patched) |
| 706 | `int3` | operand of the line above |
| 711 | `add rsp, N` | frame |
| 712 | `int3` | operand of the line above |
| 743 | `lea rax, [rip]              ## N` | address of a constant |
| 745 | `int3` | operand of the line above |

### 60_commands.nihil

| line | x86 | operation |
|---|---|---|
| 196 | `(operand bytes / continuation)` | operand of the line above |
| 197 | `jle N` | call / jump (rel32, patched) |
| 199 | `int3` | operand of the line above |
| 201 | `(operand bytes / continuation)` | operand of the line above |
| 211 | `cmp qword ptr [rbp], N` | other (see the line) |
| 212 | `int3` | operand of the line above |
| 213 | `add byte ptr [rdi], cl` | other (see the line) |
| 215 | `int3` | operand of the line above |
| 217 | `dec qword ptr [rbp]` | increment in memory |
| 218 | `int3` | operand of the line above |
| 243 | `jmp N` | call / jump (rel32, patched) |
| 246 | `int3` | operand of the line above |
| 315 | `jmp N` | call / jump (rel32, patched) |
| 317 | `int3` | operand of the line above |
| 321 | `push rbp` | frame / copy top |
| 325 | `add byte ptr [r8], al` | other (see the line) |
| 328 | `sub rsp, N` | frame |
| 330 | `int3` | operand of the line above |
| 405 | `lea rsi, [rip]              ## N` | address of a constant |
| 407 | `int3` | operand of the line above |
| 435 | `push rax` | push |
| 436 | `push rdx` | push_presence |
| 437 | `xor eax, eax` | immediate(reg, v) |
| 438 | `push rax` | push |
| 476 | `push rax` | push |
| 477 | `push rdx` | push_presence |
| 478 | `mov eax, N` | immediate(reg, v) |
| 479 | `push rax` | push |
| 533 | `push rax` | push |
| 541 | `mov rcx, rax` | move(dst, src) |
| 542 | `pop rax` | pop_into(reg) |
| 564 | `xor edi, edi` | immediate(reg, v) |
| 575 | `mov rdi, rax` | move(dst, src) |
| 640 | `test rdx, rdx` | test for zero |
| 642 | `jne N` | call / jump (rel32, patched) |
| 643 | `lea rax, [rip]              ## N` | address of a constant |
| 645 | `int3` | operand of the line above |
| 647 | `jne N` | call / jump (rel32, patched) |
| 648 | `xor eax, eax` | immediate(reg, v) |
| 669 | `xor edi, edi` | immediate(reg, v) |
| 680 | `mov rdi, rax` | move(dst, src) |
| 870 | `inc dword ptr [rax]` | increment in memory |
| 871 | `(operand bytes / continuation)` | operand of the line above |
| 873 | `(operand bytes / continuation)` | operand of the line above |
| 874 | `int3` | operand of the line above |
| 878 | `inc qword ptr [rax]` | increment in memory |
| 879 | `add al, N` | other (see the line) |
| 880 | `and eax, N` | other (see the line) |
| 881 | `int3` | operand of the line above |
| 883 | `add qword ptr [N], N` | global load/store |
| 884 | `int3` | operand of the line above |
| 885 | `int3` | operand of the line above |
| 889 | `inc qword ptr [rax]` | increment in memory |
| 890 | `test dword ptr [rbp], ecx` | test for zero |
| 891 | `int3` | operand of the line above |
| 893 | `add qword ptr [rbp], N` | increment in memory |
| 894 | `int3` | operand of the line above |
| 895 | `int3` | operand of the line above |
| 1086 | `push rax` | push |
| 1100 | `mov rdx, rax` | move(dst, src) |
| 1103 | `mov qword ptr [rax + N*rcx], rdx` | element store |

### 80_main.nihil

| line | x86 | operation |
|---|---|---|
| 49 | `(operand bytes / continuation)` | operand of the line above |
| 53 | `push rbp` | frame / copy top |
| 55 | `int3` | operand of the line above |
| 56 | `call N` | call / jump (rel32, patched) |
| 58 | `int3` | operand of the line above |
| 65 | `xor edi, edi` | immediate(reg, v) |
| 73 | `lea rax, [rip]              ## N` | address of a constant |
| 75 | `int3` | operand of the line above |
| 88 | `ret` | frame |
