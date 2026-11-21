// the globals of a test program: 1024 slots between the two symbols the runtime scans
    .data
    .p2align 4
    .globl _nh_globals_start, _nh_globals_end
_nh_globals_start:
    .space 8 * 1024
_nh_globals_end:
