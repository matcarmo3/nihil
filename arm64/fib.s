// arm64/fib.s — phase 0: what the compiler will emit for this program, written by hand in the
// same stack-machine style it uses on x86 (x0 is the accumulator, a push takes 16 bytes because
// the ARM64 stack stays 16-byte aligned):
//
//   fib(n = 0) { n < 2 { : n; } : fib(n - 1) + fib(n - 2); }
//   i = 0;
//   * i <= 30 { >> fib(i); >> " "; i = i + 1; }
//   >> "\n";
//   >> fib(35); >> "\n";
    .text
    .p2align 2

// fib(n): the argument arrives in x0 and lives in the frame at [x29, #16]
_nh_m_fib:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [x29, #16]              // n
    // n < 2
    ldr x0, [x29, #16]
    str x0, [sp, #-16]!             // push
    mov x0, #2
    ldr x1, [sp], #16               // pop
    cmp x1, x0
    cset x0, lt
    cbz x0, 1f
    ldr x0, [x29, #16]              // : n;
    b 9f
1:  // fib(n - 1)
    ldr x0, [x29, #16]
    str x0, [sp, #-16]!
    mov x0, #1
    ldr x1, [sp], #16
    sub x0, x1, x0
    bl _nh_m_fib
    str x0, [sp, #-16]!             // push the left operand of +
    // fib(n - 2)
    ldr x0, [x29, #16]
    str x0, [sp, #-16]!
    mov x0, #2
    ldr x1, [sp], #16
    sub x0, x1, x0
    bl _nh_m_fib
    ldr x1, [sp], #16
    add x0, x1, x0                  // : fib(n - 1) + fib(n - 2);
9:  ldp x29, x30, [sp], #32
    ret

// the program's body; main is libSystem's entry, so the program starts here
    .globl _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    // i = 0;
    mov x0, #0
    adrp x9, g_i@PAGE
    str x0, [x9, g_i@PAGEOFF]
2:  // * i <= 30 {
    adrp x9, g_i@PAGE
    ldr x0, [x9, g_i@PAGEOFF]
    str x0, [sp, #-16]!
    mov x0, #30
    ldr x1, [sp], #16
    cmp x1, x0
    cset x0, le
    cbz x0, 3f
    //   >> fib(i);
    adrp x9, g_i@PAGE
    ldr x0, [x9, g_i@PAGEOFF]
    bl _nh_m_fib
    bl _nh_put_int
    //   >> " ";
    adrp x0, s_space@PAGE
    add x0, x0, s_space@PAGEOFF
    bl _nh_put_text
    //   i = i + 1;
    adrp x9, g_i@PAGE
    ldr x0, [x9, g_i@PAGEOFF]
    str x0, [sp, #-16]!
    mov x0, #1
    ldr x1, [sp], #16
    add x0, x1, x0
    adrp x9, g_i@PAGE
    str x0, [x9, g_i@PAGEOFF]
    b 2b
3:  // >> "\n";
    adrp x0, s_nl@PAGE
    add x0, x0, s_nl@PAGEOFF
    bl _nh_put_text
    // >> fib(35); >> "\n";
    mov x0, #35
    bl _nh_m_fib
    bl _nh_put_int
    adrp x0, s_nl@PAGE
    add x0, x0, s_nl@PAGEOFF
    bl _nh_put_text
    mov x0, #0
    bl _nh_exit

    .data
    .p2align 3
    .globl _nh_globals_start, _nh_globals_end
_nh_globals_start:                  // the globals, between the two symbols the collector scans
g_i: .quad 0
_nh_globals_end:
// texts: the length in the 8 bytes before the bytes
    .quad 1
s_space: .ascii " "
    .p2align 3
    .quad 1
s_nl: .ascii "\n"
