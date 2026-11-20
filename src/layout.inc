; =============================================================================
; layout.inc — addresses and offsets shared by the compiler (nihilc.asm)
; and the runtime embedded in the generated executables (runtime.asm). SPEC §12.3.
; =============================================================================

; ---- generated executable ------------------------------------------------------
%define BASE_CODE     0x400000
%define SIZE_HEADER   0xB0            ; ELF header (64) + 2 program headers (2 × 56)
%define BASE_DATA      0x40000000

; ---- data segment (in memory only, zeroed by the kernel) ------------------
%define OUTPUT_SIZE       (BASE_DATA + 0)        ; qword: bytes pending in the buffer
%define HEAP_POS        (BASE_DATA + 8)        ; next free byte of the heap
%define HEAP_END        (BASE_DATA + 16)       ; end of the current heap block
%define IN_POS         (BASE_DATA + 24)       ; next byte to hand out from the input buffer
%define IN_SIZE         (BASE_DATA + 32)       ; valid bytes in the input buffer
%define IN_END         (BASE_DATA + 40)       ; 1 = input has ended
%define OUTPUT_BUF       (BASE_DATA + 0x1000)   ; standard output buffer
%define OUTPUT_CAP       65536
%define IN_BUF         (BASE_DATA + 0x11000)  ; standard input buffer
%define IN_CAP         65536
%define GLOBALS         (BASE_DATA + 0x21000)  ; globals: 8 bytes each

; ---- runtime jump table --------------------------------------------
; The runtime starts at BASE_CODE + SIZE_HEADER (the program's entry) with
; a 5-byte "jmp program" that nihilc patches, followed by one "jmp near
; routine" entry (5 bytes) per routine. New routines ALWAYS go at the end.
%define RT_DIV          5       ; rax = rax / rcx        (error if rcx = 0)
%define RT_MOD          10      ; rax = rax % rcx        (error if rcx = 0)
%define RT_PRINT_INT  15      ; >> rax  (INT)
%define RT_PRINT_BOOL 20      ; >> rax  (BOOL)
%define RT_PRINT_STR  25      ; >> rax  (STRING: pointer, length in [rax-8])
%define RT_EXIT         30      ; flushes the output and exits with code rdi
%define RT_ERROR         35      ; runtime error: rsi = message (0-terminated), exits with 2
%define RT_ALLOC        40      ; rcx = n → rax = new array of n zeroed elements
%define RT_ARRAY_REP    45      ; rcx = n, rdx = value → rax = [value ; n]
%define RT_ERROR_INDEX  50      ; target of the "jae" when rcx >= length of rax
%define RT_WRITE_BYTE 55      ; >>> al
%define RT_READ_BYTE      60      ; rax = next input byte, or -1 at the end
%define RT_STR_EQUAL    65      ; rax = (STRING rax == STRING rcx)
%define RT_ERROR_INT     70      ; !>> rax (INT): flushes the output and writes to stderr
%define RT_ERROR_BOOL    75      ; !>> rax (BOOL)
%define RT_ERROR_STR     80      ; !>> rax (STRING)
%define RT_READ_FILE   85      ; rax = contents of the file at path rax (STRING)
%define RT_TEXT        90      ; rax = STRING with the bytes of the ARRAY of INT rax
%define RT_PRINT_INT_OPT  95  ; >> optional: rax = value, rdx = presence (0 → "_")
%define RT_PRINT_BOOL_OPT 100
%define RT_PRINT_STR_OPT  105
%define RT_ERROR_INT_OPT     110 ; !>> opcional
%define RT_ERROR_BOOL_OPT    115
%define RT_ERROR_STR_OPT     120
%define RT_READ_FILE_OPT   125 ; like RT_READ_FILE, but returns 0 if it does not open
%define RT_CONCAT           130 ; rax = STRING rax + STRING rcx
%define RT_SLEEP            135 ; ... rax: flushes the output and waits rax milliseconds
%define RT_WRITE_FILE       140 ; @>> rax, rcx: file at path rax (STRING) gets text rcx (STRING), atomically
%define RT_APPEND_FILE      145 ; @+>> rax, rcx: appends text rcx to the file at path rax
%define RT_READ_AT          150 ; rax = path, rcx = offset, rdx = bytes → rax = STRING read there (0: no file), rdx = file size, rcx = stamp (mtime + inode)
%define RT_WRITE_AT         155 ; rax = path, rcx = text, rdx = offset: writes the text there (pwrite + fsync)
%define RT_WRITE_AT_NS      160 ; the same, without the fsync
%define RT_TRUNCATE         165 ; rax = path, rdx = size: cuts the file (ftruncate + fsync)
%define RT_TRUNCATE_NS      170 ; the same, without the fsync
