; =============================================================================
; nihilc — compiler for the Nihil language, stage 0 (x86_64 assembly, NASM)
;
; Milestone 2: full lexer, INT/BOOL/STRING expressions, globals, `>>`,
; `: expr;` at the top level. See SPEC.md §12 and §14.
;
; Usage: nihilc input.nihil [output]          (default output: a.out)
;
; Internal convention: every function may destroy rax, rcx, rdx, rsi, rdi,
; r8–r11 and preserves rbx, rbp, r12–r15. Compile errors do not return.
; =============================================================================

bits 64
default rel
%include "layout.inc"

; ---- syscalls ---------------------------------------------------------------
%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_CLOSE   3
%define SYS_MMAP    9
%define SYS_EXIT    60
%define SYS_CHMOD   90
%define SYS_OPENAT  257

%define AT_FDCWD        -100
%define the_RDONLY        0
%define the_WRITE_NEW  0x241           ; O_WRONLY | O_CREAT | O_TRUNC
%define PROT_RW         3
%define MAP_ANON_PRIV   0x4022          ; MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
%define MODE_EXEC       0o755

; ---- arenas (SPEC §12.1) ----------------------------------------------------
%define SIZE_SOURCE   (16 << 20)
%define SIZE_SYM    (4 << 20)
%define SIZE_CODE  (16 << 20)
%define SIZE_FIX    (4 << 20)
%define SIZE_CONST   (16 << 20)
%define SIZE_PARAM   (1 << 20)
%define SIZE_RAW   (16 << 20)              ; files as read, before inclusions are expanded
%define SIZE_NAMES   (1 << 20)               ; file paths (0-terminated)
%define SIZE_ARENAS  (SIZE_SOURCE + SIZE_SYM + SIZE_CODE + SIZE_FIX + SIZE_CONST + SIZE_PARAM + SIZE_RAW + SIZE_NAMES)
%define MAX_NAMES   4096
%define MAX_SEG     4096
%define MAX_DEPTH_INCLUDE 64

%define OFS_FILESZ_CODE  (64 + 32)       ; p_filesz of the 1st program header
%define OFS_MEMSZ_CODE   (64 + 40)       ; p_memsz  of the 1st program header
%define OFS_MEMSZ_DATA   (120 + 40)      ; p_memsz  of the 2nd program header

; ---- tokens -----------------------------------------------------------------
; One-character tokens use their own ASCII code (';', '+', '(' ...).
%define T_END           0
%define T_IDENT         256
%define T_INT           257             ; integer or character ('a')
%define T_STR           258
%define T_TRUE          259
%define T_FALSE         260
%define T_UNDERSCORE          261             ; _
%define T_EQ         262             ; ==
%define T_NE           263             ; !=
%define T_LE      264             ; <=
%define T_GE      265             ; >=
%define T_SHL           266             ; <<
%define T_SHR           267             ; >>
%define T_BYTE_IN  268             ; <<<
%define T_BYTE_OUT    269             ; >>>
%define T_AND             270             ; &&
%define T_OR            271             ; ||
%define T_EXIT          272             ; ::
%define T_ERROR_OUT    273             ; !>>

; ---- tipos ------------------------------------------------------------------
%define TYPE_INT    1
%define TYPE_BOOL   2
%define TYPE_STR    3
%define TYPE_NONE   4       ; result of a method without ': value'
%define TYPE_UNKNOWN   5       ; provisional: type not known yet (only outside the final pass)
%define TYPE_ARR    0x10    ; ARRAY of T = TYPE_ARR | T  (T = INT, BOOL or STRING)

; ---- symbols (32 bytes, SPEC §12.1) ----------------------------------------
%define S_NAME_OFS  0       ; dd  position of the name in the source arena
%define S_NAME_LEN  4       ; dw
%define S_TYPE      6       ; db
%define S_FLAGS     7       ; db
%define S_LEVEL     8       ; dw
%define S_NPARAM    12      ; dd  methods: number of parameters
%define S_ADDRESS  16      ; dq  global: address; local/parameter: rbp+x; method: code position
%define S_EXTRA     24      ; dq  global: line of creation; method: 1st index in the parameter arena
%define SIZE_SYMBOL 32
%define FLAG_GLOBAL 1
%define FLAG_METHOD 2
%define FLAG_CREATED 4       ; the global already got a value (in this pass, in the top-level text)
%define FLAG_PARAM  8
%define SIZE_PARAMETER 16    ; parameter arena: dq type, dq default (value or string offset)

; ---- binary operators (tables in .rodata) -------------------------------
%define MODE_INT    1       ; INT × INT → INT, code bytes
%define MODE_EQUAL  2       ; same type (INT or BOOL) → BOOL
%define MODE_ORDER  3       ; INT × INT → BOOL
%define MODE_RT     4       ; INT × INT → INT, calls a runtime routine
%define N_LEVELS    7
%define LEVEL_COMP  0

; =============================================================================
; Macros
; =============================================================================

; EMIT b1, b2, ... — appends fixed bytes to the generated code
%macro EMIT 1+
    [section .rodata]
    %%b: db %1
    %%f:
    __?SECT?__
    lea rsi, [%%b]
    mov ecx, %%f - %%b
    call emit_bytes
%endmacro

; ERROR "message" — compile error at the position of the current token
%macro ERROR 1
    [section .rodata]
    %%m: db %1, 0
    __?SECT?__
    lea rdi, [%%m]
    jmp error_simple
%endmacro

; AP "text" — appends text to the error message being built
%macro PUT 1
    [section .rodata]
    %%m: db %1, 0
    __?SECT?__
    lea rdi, [%%m]
    call put_cstr
%endmacro

; EXPECT tok, "description" — consumes the token or fails with "expected ..."
%macro EXPECT 2
    [section .rodata]
    %%d: db %2, 0
    __?SECT?__
    mov edi, %1
    lea rsi, [%%d]
    call expect
%endmacro

; CONST_PUT "text" — appends text to the constant being built (const_init/close)
%macro CONST_PUT 1
    [section .rodata]
    %%t: db %1
    %%f:
    __?SECT?__
    lea rdi, [%%t]
    mov esi, %%f - %%t
    call const_put
%endmacro

; CALL_RT RT_X — emits a call to a runtime routine
%macro CALL_RT 1
    mov edi, %1
    call emit_call_rt
%endmacro

; SAVE_POS — pushes the current token (4 qwords). Layout from rsp:
; [0] tok_lini, [8] tok_lin, [16] tok_len, [24] tok_ini
%macro SAVE_POS 0
    push qword [tok_start]
    push qword [tok_len]
    push qword [tok_line]
    push qword [tok_lstart]
%endmacro

; =============================================================================
section .rodata

template_elf:
    ; --- ELF64 header (64 bytes) ---
    db 0x7F, "ELF", 2, 1, 1, 0          ; magic, 64 bits, LE, version, System V
    times 8 db 0
    dw 2                                ; e_type    = ET_EXEC
    dw 0x3E                             ; e_machine = EM_X86_64
    dd 1                                ; e_version
    dq BASE_CODE + SIZE_HEADER      ; e_entry   = start of the runtime
    dq 64                               ; e_phoff
    dq 0                                ; e_shoff   (no sections)
    dd 0                                ; e_flags
    dw 64, 56, 2                        ; e_ehsize, e_phentsize, e_phnum
    dw 64, 0, 0                         ; e_shentsize, e_shnum, e_shstrndx
    ; --- PT_LOAD code (R+X) ---
    dd 1, 5                             ; PT_LOAD, PF_R | PF_X
    dq 0, BASE_CODE, BASE_CODE      ; offset, vaddr, paddr
    dq 0, 0                             ; filesz, memsz (fecha_elf)
    dq 0x1000
    ; --- PT_LOAD data (R+W, in memory only) ---
    dd 1, 6                             ; PT_LOAD, PF_R | PF_W
    dq 0, BASE_DATA, BASE_DATA
    dq 0, 0                             ; filesz = 0, memsz (fecha_elf)
    dq 0x1000
end_template_elf:

%if end_template_elf - template_elf != SIZE_HEADER
    %error "the ELF template is not SIZE_HEADER bytes long"
%endif

runtime_bin:    incbin "runtime.bin"
runtime_len     equ $ - runtime_bin

simple:        db ";,(){}[]?:#~+-*/%^@$", 0

; ---- binary operators: dd token ; db mode, n_bytes, 0, 0 ; dq code ----
; (in MODE_RT the code field is the offset of the runtime routine)
n_comp:
    dd T_EQ
    db MODE_EQUAL, 9, 0, 0
    dq c_eq
    dd T_NE
    db MODE_EQUAL, 9, 0, 0
    dq c_ne
    dd '<'
    db MODE_ORDER, 9, 0, 0
    dq c_lt
    dd '>'
    db MODE_ORDER, 9, 0, 0
    dq c_gt
    dd T_LE
    db MODE_ORDER, 9, 0, 0
    dq c_read
    dd T_GE
    db MODE_ORDER, 9, 0, 0
    dq c_ge
    dd 0
n_bor:
    dd '|'
    db MODE_INT, 3, 0, 0
    dq c_or
    dd 0
n_bxor:
    dd '^'
    db MODE_INT, 3, 0, 0
    dq c_xor
    dd 0
n_band:
    dd '&'
    db MODE_INT, 3, 0, 0
    dq c_and
    dd 0
n_shift:
    dd T_SHL
    db MODE_INT, 3, 0, 0
    dq c_shl
    dd T_SHR
    db MODE_INT, 3, 0, 0
    dq c_sar
    dd 0
n_sum:
    dd '+'
    db MODE_INT, 3, 0, 0
    dq c_add
    dd '-'
    db MODE_INT, 3, 0, 0
    dq c_sub
    dd 0
n_prod:
    dd '*'
    db MODE_INT, 4, 0, 0
    dq c_mul
    dd '/'
    db MODE_RT, 0, 0, 0
    dq RT_DIV
    dd '%'
    db MODE_RT, 0, 0, 0
    dq RT_MOD
    dd 0

; from lowest to highest precedence (below || and &&)
table_levels:  dq n_comp, n_bor, n_bxor, n_band, n_shift, n_sum, n_prod

; left operand in rax, right in rcx
c_eq:   db 0x48, 0x39, 0xC8, 0x0F, 0x94, 0xC0, 0x0F, 0xB6, 0xC0   ; cmp rax,rcx ; sete al ; movzx eax,al
c_ne:   db 0x48, 0x39, 0xC8, 0x0F, 0x95, 0xC0, 0x0F, 0xB6, 0xC0
c_lt:   db 0x48, 0x39, 0xC8, 0x0F, 0x9C, 0xC0, 0x0F, 0xB6, 0xC0
c_gt:   db 0x48, 0x39, 0xC8, 0x0F, 0x9F, 0xC0, 0x0F, 0xB6, 0xC0
c_read:   db 0x48, 0x39, 0xC8, 0x0F, 0x9E, 0xC0, 0x0F, 0xB6, 0xC0
c_ge:   db 0x48, 0x39, 0xC8, 0x0F, 0x9D, 0xC0, 0x0F, 0xB6, 0xC0
c_or:   db 0x48, 0x09, 0xC8         ; or  rax, rcx
c_xor:  db 0x48, 0x31, 0xC8         ; xor rax, rcx
c_and:  db 0x48, 0x21, 0xC8         ; and rax, rcx
c_shl:  db 0x48, 0xD3, 0xE0         ; shl rax, cl
c_sar:  db 0x48, 0xD3, 0xF8         ; sar rax, cl
c_add:  db 0x48, 0x01, 0xC8         ; add rax, rcx
c_sub:  db 0x48, 0x29, 0xC8         ; sub rax, rcx
c_mul:  db 0x48, 0x0F, 0xAF, 0xC1   ; imul rax, rcx

; ---- unary operators: dd token ; db type_in, type_out, n_bytes, rt ; dq code
; (rt = 1: the code field is the offset of a runtime routine)
tab_unary:
    dd '-'
    db TYPE_INT, TYPE_INT, 3, 0
    dq c_neg
    dd '!'
    db TYPE_BOOL, TYPE_BOOL, 3, 0
    dq c_not
    dd '~'
    db TYPE_INT, TYPE_INT, 3, 0
    dq c_inv
    dd '#'
    db TYPE_STR, TYPE_INT, 4, 0
    dq c_size
    dd '@'                              ; @ path → contents of the file
    db TYPE_STR, TYPE_STR, 0, 1
    dq RT_READ_FILE
    dd '$'                              ; $ bytes → STRING
    db TYPE_ARR | TYPE_INT, TYPE_STR, 0, 1
    dq RT_TEXT
    dd 0
c_neg:  db 0x48, 0xF7, 0xD8         ; neg rax
c_not:  db 0x83, 0xF0, 0x01         ; xor eax, 1
c_inv:  db 0x48, 0xF7, 0xD0         ; not rax
c_size:  db 0x48, 0x8B, 0x40, 0xF8   ; mov rax, [rax-8]

; ---- type names ----
tab_types:      dq s_type_0, s_type_int, s_type_bool, s_type_str, s_type_none, s_type_0
s_type_0:       db "?", 0
s_type_none:    db "nothing (call to a method with no value)", 0
s_type_int:     db "INT", 0
s_type_bool:    db "BOOL", 0
s_type_str:     db "STRING", 0

; ---- messages without a position (files, memory) ----
output_default:   db "a.out", 0
prefix:        db "nihilc: "
prefix_len     equ $ - prefix
new_line:     db 10
msg_usage:        db "usage: nihilc <input.nihil> [output]"
msg_usage_len     equ $ - msg_usage
msg_mmap:       db "could not reserve memory (mmap)"
msg_mmap_len    equ $ - msg_mmap
msg_open:      db "could not open "
msg_open_len   equ $ - msg_open
msg_read:        db "read error in "
msg_read_len     equ $ - msg_read
msg_large:     db "source file too large (limit 16 MiB): "
msg_large_len  equ $ - msg_large
msg_code:     db "generated program too large (limit 16 MiB)"
msg_code_len  equ $ - msg_code
msg_create:      db "could not create "
msg_create_len   equ $ - msg_create
msg_write:     db "write error in "
msg_write_len  equ $ - msg_write
msg_chmod:      db "could not make executable: "
msg_chmod_len   equ $ - msg_chmod

; =============================================================================
section .bss

path_input: resq 1
path_output:   resq 1
base_source:      resq 1
size_source:       resq 1
base_sym:       resq 1
n_sym:          resq 1
n_globals:       resq 1
base_code:     resq 1
size_code:      resq 1             ; bytes emitted, including the header and the runtime
base_fix:       resq 1
n_fix:          resq 1
base_const:      resq 1
size_const:       resq 1
const_head:       resq 1             ; header of the constant being built
base_param:      resq 1
n_param:         resq 1

; inclusions (SPEC §16): raw files, names and segments of the expanded source
base_raw:      resq 1
size_raw:       resq 1
base_names:      resq 1
size_names:       resq 1
n_names:         resq 1
tab_names:       resq MAX_NAMES         ; pointer to each path already included
n_seg:           resq 1
seg_start:         resq MAX_SEG           ; offset in the expanded source
seg_name:        resq MAX_SEG           ; path of the file
seg_bline:        resq MAX_SEG           ; line of the expanded source where the segment starts
seg_fline:        resq MAX_SEG           ; matching line in the file
lines_buf:      resq 1                 ; line breaks already copied into the source
expanding:      resq 1                 ; 1 = lendo arquivos brutos (erros: nome_atual)
name_current:      resq 1
error_name:       resq 1                 ; file of the error message being built

; passadas (SPEC §9.2)
final_pass:   resq 1             ; 1 = strict checking
unknowns:   resq 1             ; provisional types used in this pass
discovered:           resq 1             ; some type was discovered in this pass
n_passes:      resq 1
const_base:      resq 1             ; size_const after the prescan
n_sym_base:     resq 1             ; n_sym after the prescan
const_empty:     resq 1             ; offset of this pass's "" string
pos_init:        resq 1             ; rel32 of the "call inicializa_globals"

; method being compiled
method_current:    resq 1             ; symbol, or 0 at the top level
saw_value:       resq 1             ; there was an ": expr;" in the body
saw_empty:       resq 1             ; there was an ":;" in the body
call_end:     resq 1             ; size_code right after the last call emitted

; scopes and stack frame
level:           resq 1             ; block depth (0 = top level)
slots:           resq 1             ; 8-byte slots in use in the current frame
max_slots:       resq 1             ; largest value of `slots` (frame size)
pos_frame:      resq 1             ; position of the imm32 of the top level's "sub rsp, N"

; prescan: previous token
pv_type:         resq 1
pv_start:          resq 1
pv_len:          resq 1
pv_line:          resq 1

; lexer — lx_pos through tok_lstart are 11 contiguous qwords, copied together
; by peek_type (do not reorder)
%define QWORDS_LEXER 11
lx_pos:          resq 1             ; next byte to read
lx_end:          resq 1             ; end of the source
lx_line:          resq 1             ; current line (1…)
lx_lstart:         resq 1             ; start of the current line
lx_backslash:        resq 1             ; position of the '\' of the escape being parsed

; current token
tok_type:        resq 1
tok_start:         resq 1
tok_len:         resq 1
tok_value:       resq 1             ; T_INT: value; T_STR: offset in the constant arena
tok_line:         resq 1
tok_lstart:        resq 1
copy_lexer:    resq QWORDS_LEXER

; error message being built
%define CAP_MSG 1024
msg_buf:         resb CAP_MSG
msg_len:         resq 1

; =============================================================================
section .text
global _start

_start:
    mov rax, [rsp]                  ; argc
    cmp rax, 2
    jl error_usage
    mov rbx, [rsp + 16]             ; argv[1]
    mov [path_input], rbx
    lea rbx, [output_default]
    cmp rax, 3
    jl .without_output
    mov rbx, [rsp + 24]             ; argv[2]
.without_output:
    mov [path_output], rbx

    call reserve_arenas
    call load_program
    call compile
    call save_output

    mov eax, SYS_EXIT
    xor edi, edi
    syscall

; =============================================================================
; Programa
; =============================================================================

compile:
    call prescan
    mov rax, [size_const]
    mov [const_base], rax
    mov rax, [n_sym]
    mov [n_sym_base], rax
.pass:
    inc qword [n_passes]
    cmp qword [n_passes], 1000
    ja .unstable
    call one_pass
    cmp qword [final_pass], 0
    jne .finish
    cmp qword [unknowns], 0    ; nothing provisional: this one already counts as final
    je .finish
    cmp qword [discovered], 0
    jne .pass
    mov qword [final_pass], 1    ; nothing left to discover: the next one is strict
    jmp .pass
.finish:
    ret
.unstable:
    ERROR "types did not settle after 1000 passes"

; one_pass: compiles the whole program from scratch (code, constants and
; fixups are redone; types discovered for methods and globals persist)
one_pass:
    xor eax, eax
    mov [size_code], rax
    mov [n_fix], rax
    mov [slots], rax
    mov [max_slots], rax
    mov [level], rax
    mov [method_current], rax
    mov [unknowns], rax
    mov [discovered], rax
    mov rax, [const_base]
    mov [size_const], rax
    mov rax, [n_sym_base]
    mov [n_sym], rax
    ; no global has been created yet in this pass
    mov rcx, [n_sym]
    mov rdx, [base_sym]
.clear:
    test rcx, rcx
    jz .cleared
    and byte [rdx + S_FLAGS], ~FLAG_CREATED
    add rdx, SIZE_SYMBOL
    dec rcx
    jmp .clear
.cleared:
    call const_init               ; "" to initialize STRING globals
    call const_close
    mov [const_empty], rax

    ; ELF header + runtime
    lea rsi, [template_elf]
    mov ecx, SIZE_HEADER
    call emit_bytes
    lea rsi, [runtime_bin]
    mov ecx, runtime_len
    call emit_bytes
    ; the "jmp program" at the start of the runtime jumps here
    mov rax, [size_code]
    sub rax, SIZE_HEADER + 5
    mov rdi, [base_code]
    mov [rdi + SIZE_HEADER + 1], eax

    ; top-level frame: push rbp ; mov rbp, rsp ; sub rsp, imm32 (patched at the end)
    EMIT 0x55, 0x48, 0x89, 0xE5, 0x48, 0x81, 0xEC
    mov rax, [size_code]
    mov [pos_frame], rax
    xor edi, edi
    call emit_dword
    mov edi, 0xE8                   ; call inicializa_globais
    call emit_byte
    mov rax, [size_code]
    mov [pos_init], rax
    xor edi, edi
    call emit_dword

    call init_lexer
    call next_token
.repeat:
    cmp qword [tok_type], T_END
    je .finish
    call command
    jmp .repeat
.finish:
    mov rax, [max_slots]            ; frame: slots × 8, aligned to 16
    shl rax, 3
    add rax, 15
    and rax, -16
    mov rcx, [base_code]
    add rcx, [pos_frame]
    mov [rcx], eax
    EMIT 0x31, 0xFF                ; xor edi, edi
    CALL_RT RT_EXIT

    ; inicializa_globals: every STRING or ARRAY global starts empty
    mov rdi, [pos_init]
    call patch_here
    push rbx
    push r12
    mov rbx, [base_sym]
    mov r12, [n_sym_base]
.init:
    test r12, r12
    jz .init_end
    test byte [rbx + S_FLAGS], FLAG_GLOBAL
    jz .init_nxt
    movzx eax, byte [rbx + S_TYPE]
    cmp eax, TYPE_STR
    je .init_empty
    test eax, TYPE_ARR
    jz .init_nxt
.init_empty:
    EMIT 0x48, 0x8D, 0x05          ; lea rax, [rip + ""] (size 0: works as "" and as an empty array)
    mov rdi, [size_code]
    mov rsi, [const_empty]
    call register_fixup
    xor edi, edi
    call emit_dword
    mov edi, [rbx + S_ADDRESS]
    call emit_store_global
.init_nxt:
    add rbx, SIZE_SYMBOL
    dec r12
    jmp .init
.init_end:
    pop r12
    pop rbx
    EMIT 0xC3                      ; ret
    call emit_constantes
    jmp close_elf

%include "commands.inc"

; =============================================================================
; Expressions — each function leaves the code of the value in rax (at
; run time) and returns the TYPE in eax (at compile time).
; =============================================================================

expression:
    jmp expr_or

; or ::= and ( "||" and )*      — BOOL, short-circuit
expr_or:
    push rbx
    push r12
    call expr_and
    mov ebx, eax
.repeat:
    cmp qword [tok_type], T_OR
    jne .finish
    SAVE_POS
    mov eax, ebx
    call is_bool
    jne .err_left
    call next_token
    EMIT 0x48, 0x85, 0xC0, 0x0F, 0x85      ; test rax, rax ; jnz end
    mov r12, [size_code]
    xor edi, edi
    call emit_dword
    call expr_and
    call is_bool
    jne .err_dir
    mov ebx, TYPE_BOOL
    mov rdi, r12
    call patch_here
    add rsp, 32
    jmp .repeat
.finish:
    mov eax, ebx
    pop r12
    pop rbx
    ret
.err_left:
    xor eax, eax
.err_dir:
    mov edx, eax
    mov esi, ebx
    mov rdi, rsp
    jmp error_op_types

; and ::= comp ( "&&" comp )*  — BOOL, short-circuit
expr_and:
    push rbx
    push r12
    xor edi, edi
    call binary
    mov ebx, eax
.repeat:
    cmp qword [tok_type], T_AND
    jne .finish
    SAVE_POS
    mov eax, ebx
    call is_bool
    jne .err_left
    call next_token
    EMIT 0x48, 0x85, 0xC0, 0x0F, 0x84      ; test rax, rax ; jz end
    mov r12, [size_code]
    xor edi, edi
    call emit_dword
    xor edi, edi
    call binary
    call is_bool
    jne .err_dir
    mov ebx, TYPE_BOOL
    mov rdi, r12
    call patch_here
    add rsp, 32
    jmp .repeat
.finish:
    mov eax, ebx
    pop r12
    pop rbx
    ret
.err_left:
    xor eax, eax
.err_dir:
    mov edx, eax
    mov esi, ebx
    mov rdi, rsp
    jmp error_op_types

; is_element: eax = type → ZF=1 if it can be an array element (or provisional)
is_element:
    cmp eax, TYPE_INT
    je .sim_
    cmp eax, TYPE_BOOL
    je .sim_
    cmp eax, TYPE_STR
    je .sim_
    cmp eax, TYPE_UNKNOWN
.sim_:
    ret

; is_bool: eax = type → ZF=1 if it is BOOL or provisional
is_bool:
    cmp eax, TYPE_BOOL
    je .sim_
    cmp eax, TYPE_UNKNOWN
.sim_:
    ret

; binary: edi = level (0 … N_LEVELS-1); from N_LEVELS on it becomes unary.
; The left operand goes to the stack, the right one to rcx, the result to rax.
binary:
    cmp edi, N_LEVELS
    jae unary
    push rbx                        ; left type / result
    push r12                        ; level
    push r13                        ; table entry
    push r14                        ; right type
    push r15                        ; type of the result
    mov r12d, edi
    lea edi, [r12 + 1]
    call binary
    mov ebx, eax
.repeat:
    lea rax, [table_levels]
    mov r13, [rax + r12 * 8]
    call find_operator
    test r13, r13
    jz .finish
    SAVE_POS
    call next_token
    EMIT 0x50                      ; push rax
    lea edi, [r12 + 1]
    call binary
    mov r14d, eax
    EMIT 0x48, 0x89, 0xC1, 0x58    ; mov rcx, rax ; pop rax

    movzx eax, byte [r13 + 4]
    cmp ebx, TYPE_NONE
    je .err
    cmp r14d, TYPE_NONE
    je .err
    cmp ebx, TYPE_UNKNOWN
    je .provisional
    cmp r14d, TYPE_UNKNOWN
    je .provisional
    cmp eax, MODE_EQUAL
    je .m_equal
    cmp ebx, TYPE_INT
    jne .err
    cmp r14d, TYPE_INT
    jne .err
    mov r15d, TYPE_INT
    cmp eax, MODE_ORDER
    jne .emit
    mov r15d, TYPE_BOOL
    jmp .emit
.provisional:
    ; one side has no type yet: the result depends only on the operator
    mov r15d, TYPE_BOOL
    cmp eax, MODE_EQUAL
    je .emit
    cmp eax, MODE_ORDER
    je .emit
    mov r15d, TYPE_INT
    jmp .emit
.m_equal:
    cmp ebx, r14d
    jne .err
    test ebx, TYPE_ARR
    jnz .err
    mov r15d, TYPE_BOOL
    cmp ebx, TYPE_STR
    jne .emit
    CALL_RT RT_STR_EQUAL           ; STRING: compares the contents
    cmp dword [r13], T_NE
    jne .done
    EMIT 0x83, 0xF0, 0x01          ; xor eax, 1
    jmp .done
.emit:
    cmp byte [r13 + 4], MODE_RT
    jne .bytes
    mov edi, [r13 + 8]
    call emit_call_rt
    jmp .done
.bytes:
    mov rsi, [r13 + 8]
    movzx ecx, byte [r13 + 5]
    call emit_bytes
.done:
    add rsp, 32
    mov ebx, r15d
    cmp r12d, LEVEL_COMP
    jne .repeat
    ; comparisons are not associative
    lea r13, [n_comp]
    call find_operator
    test r13, r13
    jz .finish
    ERROR "comparisons cannot be chained (use '&&')"
.finish:
    mov eax, ebx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.err:
    mov edx, r14d
    mov esi, ebx
    mov rdi, rsp
    jmp error_op_types

; find_operator: r13 = table; returns r13 = entry of the current token, or 0
find_operator:
    mov rax, [tok_type]
.repeat:
    mov ecx, [r13]
    test ecx, ecx
    jz .nao_
    cmp rcx, rax
    je .sim_
    add r13, 16
    jmp .repeat
.nao_:
    xor r13d, r13d
.sim_:
    ret

; unario ::= ( "-" | "!" | "~" | "#" ) unario | posfixo
unary:
    push rbx
    lea rbx, [tab_unary]
    mov rax, [tok_type]
.lookup:
    mov ecx, [rbx]
    test ecx, ecx
    jz .not_unary
    cmp rcx, rax
    je .found
    add rbx, 16
    jmp .lookup
.not_unary:
    pop rbx
    jmp postfix
.found:
    SAVE_POS
    call next_token
    call unary
    cmp eax, TYPE_UNKNOWN
    je .emit
    cmp dword [rbx], '#'            ; '#' also measures arrays
    jne .compare
    test eax, TYPE_ARR
    jnz .emit
.compare:
    movzx ecx, byte [rbx + 4]
    cmp eax, ecx
    jne .err
.emit:
    cmp byte [rbx + 7], 0
    jne .routine
    mov rsi, [rbx + 8]
    movzx ecx, byte [rbx + 6]
    call emit_bytes
    jmp .type
.routine:
    mov edi, [rbx + 8]
    call emit_call_rt
.type:
    movzx eax, byte [rbx + 5]
    add rsp, 32
    pop rbx
    ret
.err:
    mov esi, eax
    xor edx, edx
    mov rdi, rsp
    jmp error_op_types

; posfixo ::= primario ( "[" expressao "]" )*
postfix:
    call primary
.repeat:
    cmp qword [tok_type], '['
    je .index
    ret
.index:
    push rbx
    mov ebx, eax                    ; type of the indexed value
    SAVE_POS
    cmp ebx, TYPE_STR
    je .target_ok
    cmp ebx, TYPE_UNKNOWN
    je .target_ok
    test ebx, TYPE_ARR
    jz .target_bad
.target_ok:
    EMIT 0x50                      ; push rax
    call next_token
    call expression
    cmp eax, TYPE_INT
    je .index_ok
    cmp eax, TYPE_UNKNOWN
    jne .index_bad
.index_ok:
    EXPECT ']', "']'"
    EMIT 0x48, 0x89, 0xC1, 0x58    ; mov rcx, rax ; pop rax
    call emit_check_limit
    cmp ebx, TYPE_STR
    je .byte
    EMIT 0x48, 0x8B, 0x04, 0xC8    ; mov rax, [rax + rcx*8]
    mov eax, ebx
    and eax, 0x0F                   ; element type (provisional stays provisional)
    jmp .finish
.byte:
    EMIT 0x0F, 0xB6, 0x04, 0x08    ; movzx eax, byte [rax + rcx]
    mov eax, TYPE_INT
.finish:
    add rsp, 32
    pop rbx
    jmp .repeat
.target_bad:
    call error_start
    PUT "only ARRAY and STRING can be indexed, but the expression is "
    mov edi, ebx
    call put_type
    jmp error_end
.index_bad:
    mov ebx, eax
    call error_start
    PUT "the index must be INT, but it is "
    mov edi, ebx
    call put_type
    jmp error_end

; emit_check_limit: rax = array/STRING, rcx = index (at run time)
;   cmp rcx, [rax-8] ; jae error_index   (unsigned: negative fails too)
emit_check_limit:
    EMIT 0x48, 0x3B, 0x48, 0xF8, 0x0F, 0x83
    mov edi, RT_ERROR_INDEX + SIZE_HEADER
    sub rdi, [size_code]
    sub rdi, 4
    jmp emit_dword

primary:
    mov rax, [tok_type]
    cmp rax, T_INT
    je .int
    cmp rax, T_TRUE
    je .true
    cmp rax, T_FALSE
    je .false
    cmp rax, T_STR
    je .str
    cmp rax, T_IDENT
    je .ident
    cmp rax, '('
    je .parens
    cmp rax, T_UNDERSCORE
    je .none
    cmp rax, '['
    je .array
    lea rdi, [.d_expression]
    jmp error_expected
[section .rodata]
.d_expression: db "an expression", 0
__?SECT?__

.int:
    mov rdi, [tok_value]
    call emit_immediate
    call next_token
    mov eax, TYPE_INT
    ret
.true:
    EMIT 0xB8, 1, 0, 0, 0          ; mov eax, 1
    call next_token
    mov eax, TYPE_BOOL
    ret
.false:
    EMIT 0x31, 0xC0                ; xor eax, eax
    call next_token
    mov eax, TYPE_BOOL
    ret
.str:
    EMIT 0x48, 0x8D, 0x05          ; lea rax, [rip + rel32]
    mov rdi, [size_code]
    mov rsi, [tok_value]
    call register_fixup
    xor edi, edi
    call emit_dword
    call next_token
    mov eax, TYPE_STR
    ret
.ident:
    push rbx
    SAVE_POS
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call lookup_symbol
    mov rbx, rax
    call peek_type
    cmp rax, '('
    je .call_method
    test rbx, rbx
    jz .not_exists
    test byte [rbx + S_FLAGS], FLAG_METHOD
    jnz .method_without_parens
    call next_token
    test byte [rbx + S_FLAGS], FLAG_GLOBAL
    jz .le
    cmp qword [method_current], 0
    jne .global_in_method
    test byte [rbx + S_FLAGS], FLAG_CREATED  ; top level: only after the creation in the text
    jz .yet_not
.le:
    mov rdi, rbx
    call emit_load_var
    movzx eax, byte [rbx + S_TYPE]
    test eax, eax
    jnz .end_var
    mov eax, TYPE_UNKNOWN              ; created with a provisional value
.end_var:
    add rsp, 32
    pop rbx
    ret
.global_in_method:
    cmp byte [rbx + S_TYPE], 0
    jne .le
    mov rdi, rbx
    call emit_load_var
    call global_unknown
    add rsp, 32
    pop rbx
    ret
.call_method:
    add rsp, 32
    mov rdi, rbx
    pop rbx
    call call_method
    cmp eax, TYPE_NONE
    je .call_none
    ret
.call_none:
    ; accepted here; whoever consumes the value rejects it (the command "f();" is valid)
    ret
.method_without_parens:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "'"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' is a method; call it as '"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "(…)'"
    jmp error_end
.yet_not:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "variable '"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' does not exist here yet (it is created on line "
    mov rdi, [rbx + S_EXTRA]
    call put_line
    PUT ")"
    jmp error_end
.not_exists:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "variable '"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' does not exist"
    jmp error_end
.parens:
    call next_token
    call expression
    push rax
    EXPECT ')', "')'"
    pop rax
    ret
.none:
    ERROR "'_' (no value) is not supported by stage 0"
.array:
    push rbx                        ; element type
    push r12                        ; how many
    push r13
    call next_token
    cmp qword [tok_type], ']'
    je .array_empty
    SAVE_POS
    call expression
    mov ebx, eax
    call is_element
    jne .element_bad
    add rsp, 32
    cmp qword [tok_type], ';'
    je .repetition
    ; [a, b, c]: pushes the values, allocates, pops from the last to the first
    EMIT 0x50
    mov r12d, 1
.list:
    cmp qword [tok_type], ','
    jne .end_list
    call next_token
    SAVE_POS
    call expression
    cmp eax, ebx
    je .same_type
    cmp eax, TYPE_UNKNOWN
    je .same_type
    cmp ebx, TYPE_UNKNOWN
    jne .element_different
.same_type:
    add rsp, 32
    EMIT 0x50
    inc r12
    jmp .list
.end_list:
    EXPECT ']', "']'"
    mov edi, 0xB9                   ; mov ecx, n
    call emit_byte
    mov edi, r12d
    call emit_dword
    CALL_RT RT_ALLOC
    mov r13, r12
.unstack:
    dec r13
    js .array_ready
    EMIT 0x59, 0x48, 0x89, 0x88    ; pop rcx ; mov [rax + disp32], rcx
    mov edi, r13d
    shl edi, 3
    call emit_dword
    jmp .unstack
.repetition:                         ; [value ; n]
    EMIT 0x50
    call next_token
    SAVE_POS
    call expression
    cmp eax, TYPE_INT
    je .n_ok
    cmp eax, TYPE_UNKNOWN
    jne .n_bad
.n_ok:
    add rsp, 32
    EMIT 0x48, 0x89, 0xC1, 0x5A    ; mov rcx, rax ; pop rdx
    CALL_RT RT_ARRAY_REP
    EXPECT ']', "']' (in [value ; size])"
.array_ready:
    mov eax, ebx
    cmp eax, TYPE_UNKNOWN
    je .array_end
    or eax, TYPE_ARR
.array_end:
    pop r13
    pop r12
    pop rbx
    ret
.array_empty:
    ERROR "'[]' has no type; for an empty array use [0 ; 0]"
.element_bad:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "array elements must be INT, BOOL, STRING or FLOAT (arrays of arrays are not supported yet), but this one is "
    mov edi, ebx
    call put_type
    jmp error_end
.element_different:
    mov r13d, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "all array elements must be "
    mov edi, ebx
    call put_type
    PUT ", but this one is "
    mov edi, r13d
    call put_type
    jmp error_end
.n_bad:
    mov r13d, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "the size in [value ; size] must be INT, but it is "
    mov edi, r13d
    call put_type
    jmp error_end

; -----------------------------------------------------------------------------
; call_method: rdi = symbol of the name (or 0), tok = name, followed by "(".
; Pushes the arguments from left to right (the omitted ones get their
; default), calls and removes the arguments. Returns eax = return type.
call_method:
    push rbx                        ; method
    push r12                        ; n parameters
    push r13                        ; arguments already pushed
    push r14
    SAVE_POS                       ; position of the name
    mov rbx, rdi
    test rbx, rbx
    jz .not_exists
    test byte [rbx + S_FLAGS], FLAG_METHOD
    jz .not_method
    call next_token              ; name → "("
    call next_token
    mov r12d, [rbx + S_NPARAM]
    xor r13d, r13d
.arg:
    cmp qword [tok_type], ')'
    je .end_args
    cmp r13, r12
    jae .toomany
    SAVE_POS
    call expression
    mov rcx, [rbx + S_EXTRA]
    add rcx, r13
    shl rcx, 4
    add rcx, [base_param]
    mov rcx, [rcx]                  ; type of the parameter
    cmp eax, ecx
    je .arg_ok
    cmp eax, TYPE_UNKNOWN
    jne .arg_type
.arg_ok:
    add rsp, 32
    EMIT 0x50                      ; push rax
    inc r13
    cmp qword [tok_type], ','
    jne .without_comma
    call next_token
    cmp qword [tok_type], ')'       ; "f(1,)"
    jne .arg
    lea rdi, [.d_expression]
    jmp error_expected
.without_comma:
    cmp qword [tok_type], ')'
    je .end_args
    lea rdi, [.d_separator]
    jmp error_expected
.end_args:
    cmp r13, r12                    ; defaults of the omitted ones
    jae .do_call
    mov r14, [rbx + S_EXTRA]
    add r14, r13
    shl r14, 4
    add r14, [base_param]           ; r14 = entry (dq type, dq default)
    test qword [r14], TYPE_ARR
    jz .default_scalar
    ; ARRAY: a new one-element array on every call
    EMIT 0xB9, 1, 0, 0, 0          ; mov ecx, 1
    CALL_RT RT_ALLOC
    EMIT 0x50                      ; push rax
    call .emit_default
    EMIT 0x48, 0x8B, 0x0C, 0x24, 0x48, 0x89, 0x01, 0x58   ; mov rcx,[rsp] ; mov [rcx],rax ; pop rax
    jmp .default_push
.default_scalar:
    call .emit_default
.default_push:
    EMIT 0x50                      ; push rax
    inc r13
    jmp .end_args
.do_call:
    call next_token              ; consome ")"
    mov edi, 0xE8                   ; call method (patched at the end of the pass)
    call emit_byte
    mov rdi, [size_code]
    bts rdi, 63
    mov rsi, rbx
    call register_fixup
    xor edi, edi
    call emit_dword
    test r12, r12
    jz .without_stack
    EMIT 0x48, 0x81, 0xC4          ; add rsp, 8·n
    mov edi, r12d
    shl edi, 3
    call emit_dword
.without_stack:
    mov rax, [size_code]
    mov [call_end], rax
    movzx eax, byte [rbx + S_TYPE]
    test eax, eax
    jnz .finish
    ; return type not known yet (body not seen, or dependent)
    cmp qword [final_pass], 0
    jne .undetermined
    inc qword [unknowns]
    mov eax, TYPE_UNKNOWN
.finish:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.not_exists:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "method '"
    call .put_name
    PUT "' does not exist"
    cmp qword [level], 0
    jne error_end
    PUT " (to declare one, every parameter needs a default value: "
    call .put_name
    PUT "(x = 0) { … })"
    jmp error_end
.not_method:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "'"
    call .put_name
    PUT "' is not a method"
    jmp error_end
.toomany:
    call error_start
    PUT "'"
    call .put_name_method
    PUT "' takes "
    mov rdi, r12
    call put_num
    PUT " parameter(s), but the call passes more"
    jmp error_end
.arg_type:
    mov r14d, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "argument "
    lea rdi, [r13 + 1]
    call put_num
    PUT " of '"
    call .put_name_method
    PUT "' must be "
    mov rcx, [rbx + S_EXTRA]
    add rcx, r13
    shl rcx, 4
    add rcx, [base_param]
    mov rdi, [rcx]
    call put_type
    PUT ", but it is "
    mov edi, r14d
    call put_type
    jmp error_end
.undetermined:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "could not find out what '"
    call .put_name_method
    PUT "' returns: every ':' in it depends on calls that have no type yet"
    jmp error_end
.emit_default:                      ; value of [r14] in rax
    mov rax, [r14]
    and eax, 0x0F
    cmp eax, TYPE_STR
    je .default_str
    mov rdi, [r14 + 8]
    jmp emit_immediate
.default_str:
    EMIT 0x48, 0x8D, 0x05          ; lea rax, [rip + string]
    mov rdi, [size_code]
    mov rsi, [r14 + 8]
    call register_fixup
    xor edi, edi
    jmp emit_dword
.put_name:                           ; name saved by SAVE_POS (right above the return address)
    mov rdi, [rsp + 8 + 24]
    mov rsi, [rsp + 8 + 16]
    jmp put_mem
.put_name_method:
    mov edi, [rbx + S_NAME_OFS]
    add rdi, [base_source]
    movzx esi, word [rbx + S_NAME_LEN]
    jmp put_mem
[section .rodata]
.d_separator: db "',' or ')'", 0
.d_expression: db "an expression", 0
__?SECT?__

; =============================================================================
; Symbol table
; =============================================================================

; lookup_symbol: rdi = name, rsi = length → rax = entry or 0.
; Searches from the end to the start (inner scopes first, since M3).
lookup_symbol:
    push rbx
    mov rbx, [n_sym]
.repeat:
    test rbx, rbx
    jz .nao_
    dec rbx
    mov rax, rbx
    shl rax, 5
    add rax, [base_sym]
    movzx ecx, word [rax + S_NAME_LEN]
    cmp rcx, rsi
    jne .repeat
    mov r8d, [rax + S_NAME_OFS]
    add r8, [base_source]
    xor ecx, ecx
.compare:
    cmp rcx, rsi
    je .found
    mov dl, [r8 + rcx]
    cmp dl, [rdi + rcx]
    jne .repeat
    inc rcx
    jmp .compare
.nao_:
    xor eax, eax
.found:
    pop rbx
    ret

; new_symbol: rdi = name, rsi = length, edx = type → rax = zeroed entry
; with name, type and level filled in (flags = 0)
new_symbol:
    mov rax, [n_sym]
    cmp rax, SIZE_SYM / SIZE_SYMBOL
    jae .many
    cmp rsi, 0xFFFF
    ja .name_large
    shl rax, 5
    add rax, [base_sym]
    sub rdi, [base_source]
    mov [rax + S_NAME_OFS], edi
    mov [rax + S_NAME_LEN], si
    mov [rax + S_TYPE], dl
    mov byte [rax + S_FLAGS], 0
    mov rcx, [level]
    mov [rax + S_LEVEL], cx
    mov word [rax + 10], 0
    mov dword [rax + S_NPARAM], 0
    mov qword [rax + S_ADDRESS], 0
    mov qword [rax + S_EXTRA], 0
    inc qword [n_sym]
    ret
.many:
    ERROR "too many symbols"
.name_large:
    ERROR "name too long"

; create_global: rdi = name, rsi = length, edx = type → rax = entry
create_global:
    call new_symbol
    mov byte [rax + S_FLAGS], FLAG_GLOBAL
    mov rcx, [n_globals]
    lea rcx, [GLOBALS + rcx * 8]
    mov [rax + S_ADDRESS], rcx
    inc qword [n_globals]
    ret

; create_local: rdi = name, rsi = length, edx = type → rax = entry
; Takes a new frame slot: address = rbp - 8 × slot.
create_local:
    push rdi
    push rsi
    push rdx
    call new_slot
    movsxd r8, eax
    pop rdx
    pop rsi
    pop rdi
    push r8
    call new_symbol
    pop qword [rax + S_ADDRESS]
    ret

; create_param: rdi = name, rsi = length, edx = type, rcx = offset (rbp+)
create_param:
    push rcx
    call new_symbol
    pop qword [rax + S_ADDRESS]
    mov byte [rax + S_FLAGS], FLAG_PARAM
    ret

; new_slot: reserves a frame slot → eax = offset from rbp
new_slot:
    mov rax, [slots]
    inc rax
    mov [slots], rax
    cmp rax, [max_slots]
    jbe .ok
    mov [max_slots], rax
.ok:
    cmp rax, 0x0FFFFFFF
    ja .toomany
    shl rax, 3
    neg rax
    ret
.toomany:
    ERROR "too many local variables"

; =============================================================================
; Prescan (reads tokens only, emits no code):
;  • every name assigned at the top level, outside { } ( ) [ ], becomes a
;    global with no type yet (S_EXTRA = line of the first assignment);
;  • every "name( … ) {" at the top level becomes a method, with the types and
;    defaults of its parameters in the parameter arena.
; The strings decoded here stay in the constant arena (STRING defaults point
; to them).
; =============================================================================
prescan:
    push rbx                        ; depth of { }
    push r12                        ; depth of ( ) and [ ]
    call init_lexer
    call next_token
    xor ebx, ebx
    xor r12d, r12d
    mov qword [pv_type], T_END
.repeat:
    mov rax, [tok_type]
    cmp rax, T_END
    je .finish
    cmp rax, T_IDENT
    jne .n0
    test rbx, rbx
    jnz .n0
    test r12, r12
    jnz .n0
    call peek_type
    cmp rax, '('
    jne .n0_back
    call try_method
.n0_back:
    mov rax, [tok_type]
.n0:
    cmp rax, '{'
    jne .n1
    inc rbx
.n1:
    cmp rax, '}'
    jne .n2
    dec rbx
.n2:
    cmp rax, '('
    je .open
    cmp rax, '['
    jne .n3
.open:
    inc r12
.n3:
    cmp rax, ')'
    je .close
    cmp rax, ']'
    jne .n4
.close:
    dec r12
.n4:
    cmp rax, '='
    jne .next
    test rbx, rbx
    jnz .next
    test r12, r12
    jnz .next
    cmp qword [pv_type], T_IDENT
    jne .next
    mov rdi, [pv_start]
    mov rsi, [pv_len]
    call lookup_symbol
    test rax, rax
    jz .new_global
    test byte [rax + S_FLAGS], FLAG_METHOD
    jnz .is_method
    jmp .next
.new_global:
    mov rdi, [pv_start]
    mov rsi, [pv_len]
    xor edx, edx                    ; type 0 = no value yet
    call create_global
    mov rcx, [pv_line]
    mov [rax + S_EXTRA], rcx
.next:
    mov rax, [tok_type]
    mov [pv_type], rax
    mov rax, [tok_start]
    mov [pv_start], rax
    mov rax, [tok_len]
    mov [pv_len], rax
    mov rax, [tok_line]
    mov [pv_line], rax
    call next_token
    jmp .repeat
.finish:
    pop r12
    pop rbx
    ret
.is_method:
    mov rax, [pv_start]               ; the error points to the name
    mov [tok_start], rax
    ERROR "this name already belongs to a method and cannot receive a value"

; try_method: tok = name followed by "(". If the matching ")" is followed
; by "{", it is a declaration: registers the method. The lexer goes back to the name.
try_method:
    push rbx
    sub rsp, 8 * (QWORDS_LEXER + 1)
    lea rsi, [lx_pos]
    mov rdi, rsp
    mov ecx, QWORDS_LEXER
    rep movsq
    mov rax, [size_const]
    mov [rsp + 8 * QWORDS_LEXER], rax
    call next_token              ; name → "("
    call peek_type                 ; "f()" or "f(name = …" or "f(name? …"
    cmp rax, ')'
    je .form_ok
    cmp rax, T_IDENT
    jne .nao_
    call next_token              ; "(" → name
    call peek_type
    cmp rax, '='
    je .form_ok_name
    cmp rax, '?'
    jne .nao_
.form_ok_name:
    mov ebx, 1                      ; already inside the "("
    jmp .search_nxt
.form_ok:
    xor ebx, ebx
.search:
    mov rax, [tok_type]
    cmp rax, T_END
    je .nao_
    cmp rax, '('
    jne .p1
    inc rbx
.p1:
    cmp rax, ')'
    jne .p2
    dec rbx
    jnz .p2
    call next_token
    cmp qword [tok_type], '{'
    je .sim_
    jmp .nao_
.p2:
.search_nxt:
    call next_token
    jmp .search
.sim_:
    call .back
    call register_method
.nao_:
    call .back
    add rsp, 8 * (QWORDS_LEXER + 1)
    pop rbx
    ret
.back:                             ; restores the saved lexer (above the return address)
    lea rsi, [rsp + 8]
    lea rdi, [lx_pos]
    mov ecx, QWORDS_LEXER
    rep movsq
    mov rax, [rsp + 8 + 8 * QWORDS_LEXER]
    mov [size_const], rax
    ret

; register_method: tok = name of the declaration
register_method:
    push rbx
    push r12
    push r13
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call lookup_symbol
    test rax, rax
    jnz .already_exists
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    xor edx, edx                    ; return type not known yet
    call new_symbol
    mov rbx, rax
    mov byte [rbx + S_FLAGS], FLAG_METHOD
    mov rax, [n_param]
    mov [rbx + S_EXTRA], rax
    mov rax, [tok_line]
    mov [rbx + S_ADDRESS], rax     ; (line, only until the first pass)
    call next_token              ; name → "("
    call next_token
.param:
    cmp qword [tok_type], ')'
    je .finish
    cmp qword [tok_type], T_IDENT
    jne .expected_param
    SAVE_POS
    call next_token
    cmp qword [tok_type], '?'
    je .optional
    cmp qword [tok_type], '='
    jne .without_default
    call next_token              ; "=" → default
    cmp qword [tok_type], '['
    je .default_array
    call .read_literal
    jmp .save
.default_array:
    call next_token
    call .read_literal
    push rax
    push rdx
    call next_token
    cmp qword [tok_type], ']'
    jne .array_bad
    pop rdx
    pop rax
    or edx, TYPE_ARR
.save:
    mov r12, rax
    mov rcx, [n_param]
    cmp rcx, SIZE_PARAM / SIZE_PARAMETER
    jae .toomany
    shl rcx, 4
    add rcx, [base_param]
    mov [rcx], rdx
    mov [rcx + 8], r12
    inc qword [n_param]
    inc dword [rbx + S_NPARAM]
    add rsp, 32
    call next_token
    cmp qword [tok_type], ','
    jne .without_comma
    call next_token
    cmp qword [tok_type], ')'       ; "f(a = 0,)"
    je .expected_param
    jmp .param
.without_comma:
    cmp qword [tok_type], ')'
    je .finish
    lea rdi, [.d_separator]
    jmp error_expected
.finish:
    pop r13
    pop r12
    pop rbx
    ret
.already_exists:
    mov rbx, rax
    call error_start
    PUT "'"
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call put_mem
    test byte [rbx + S_FLAGS], FLAG_METHOD
    jnz .method_repeated
    PUT "' is already a global variable and cannot be a method"
    jmp error_end
.method_repeated:
    PUT "' was already declared on line "
    mov rdi, [rbx + S_ADDRESS]
    call put_line
    jmp error_end
.expected_param:
    lea rdi, [.d_param]
    jmp error_expected
.optional:
    ERROR "optional parameters ('?') are not supported by stage 0"
.array_bad:
    ERROR 'the default of an ARRAY parameter is a one-element literal: [0], [""] or [false]'
; .read_literal: tok = start of the literal → edx = type, rax = value (or offset of
; the string); the lexer stays on the last token of the literal
.read_literal:
    xor r13d, r13d
    cmp qword [tok_type], '-'
    jne .ll
    mov r13d, 1
    call next_token
    cmp qword [tok_type], T_INT
    jne .default_bad
.ll:
    mov rax, [tok_value]
    mov rcx, [tok_type]
    mov edx, TYPE_INT
    cmp rcx, T_INT
    jne .ll_str
    test r13d, r13d
    jz .ll_end
    neg rax
.ll_end:
    ret
.ll_str:
    mov edx, TYPE_STR
    cmp rcx, T_STR
    je .ll_end
    mov edx, TYPE_BOOL
    mov eax, 1
    cmp rcx, T_TRUE
    je .ll_end
    xor eax, eax
    cmp rcx, T_FALSE
    je .ll_end
.default_bad:
    ERROR 'the default value must be a literal: 0, -1, 0xFF, a, "text", true or false'
.toomany:
    ERROR "too many parameters in the program"
.without_default:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "parameter '"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT `' needs a default value, which also sets its type: x = 0, x = "" or x = false`
    jmp error_end
[section .rodata]
.d_param: db "a parameter (name = default value)", 0
.d_separator: db "',' or ')'", 0
__?SECT?__

init_lexer:
    mov rax, [base_source]
    mov [lx_pos], rax
    mov [lx_lstart], rax
    add rax, [size_source]
    mov [lx_end], rax
    mov qword [lx_line], 1
    ret

; peek_type: returns in rax the type of the token AFTER the current one, consuming nothing
peek_type:
    lea rsi, [lx_pos]
    lea rdi, [copy_lexer]
    mov ecx, QWORDS_LEXER
    rep movsq
    push qword [size_const]
    call next_token
    mov rdx, [tok_type]
    pop qword [size_const]
    lea rsi, [copy_lexer]
    lea rdi, [lx_pos]
    mov ecx, QWORDS_LEXER
    rep movsq
    mov rax, rdx
    ret

; =============================================================================
; Code emission
; =============================================================================

; emite_bytes: rsi = origem, rcx = quantidade
emit_bytes:
    mov rdx, [size_code]
    lea rax, [rdx + rcx]
    cmp rax, SIZE_CODE
    ja error_code_large
    mov rdi, [base_code]
    add rdi, rdx
    mov [size_code], rax
    rep movsb
    ret

; emite_byte: dil
emit_byte:
    mov rdx, [size_code]
    cmp rdx, SIZE_CODE
    jae error_code_large
    mov rcx, [base_code]
    mov [rcx + rdx], dil
    inc rdx
    mov [size_code], rdx
    ret

; emite_dword: edi
emit_dword:
    mov rdx, [size_code]
    lea rax, [rdx + 4]
    cmp rax, SIZE_CODE
    ja error_code_large
    mov rcx, [base_code]
    mov [rcx + rdx], edi
    mov [size_code], rax
    ret

; emite_qword: rdi
emit_qword:
    mov rdx, [size_code]
    lea rax, [rdx + 8]
    cmp rax, SIZE_CODE
    ja error_code_large
    mov rcx, [base_code]
    mov [rcx + rdx], rdi
    mov [size_code], rax
    ret

; emit_immediate: rdi = value → code that puts the value in rax (shortest form)
emit_immediate:
    push rbx
    mov rbx, rdi
    mov rax, rdi
    shr rax, 32
    jnz .with_sign
    mov edi, 0xB8                   ; mov eax, imm32 (clears the upper half)
    call emit_byte
    mov edi, ebx
    call emit_dword
    jmp .finish
.with_sign:
    movsxd rax, ebx
    cmp rax, rbx
    jne .long
    EMIT 0x48, 0xC7, 0xC0          ; mov rax, simm32
    mov edi, ebx
    call emit_dword
    jmp .finish
.long:
    EMIT 0x48, 0xB8                ; mov rax, imm64
    mov rdi, rbx
    call emit_qword
.finish:
    pop rbx
    ret

; emit_load_global / emit_store_global: edi = absolute address
emit_load_global:
    push rdi
    EMIT 0x48, 0x8B, 0x04, 0x25    ; mov rax, [disp32]
    pop rdi
    jmp emit_dword

emit_store_global:
    push rdi
    EMIT 0x48, 0x89, 0x04, 0x25    ; mov [disp32], rax
    pop rdi
    jmp emit_dword

; emit_load_local / emit_store_local: edi = offset from rbp
emit_load_local:
    push rdi
    EMIT 0x48, 0x8B, 0x85          ; mov rax, [rbp + disp32]
    pop rdi
    jmp emit_dword

emit_store_local:
    push rdi
    EMIT 0x48, 0x89, 0x85          ; mov [rbp + disp32], rax
    pop rdi
    jmp emit_dword

; emit_load_var / emit_store_var: rdi = symbol table entry
emit_load_var:
    test byte [rdi + S_FLAGS], FLAG_GLOBAL
    mov edi, [rdi + S_ADDRESS]
    jnz emit_load_global
    jmp emit_load_local

emit_store_var:
    test byte [rdi + S_FLAGS], FLAG_GLOBAL
    mov edi, [rdi + S_ADDRESS]
    jnz emit_store_global
    jmp emit_store_local

; emit_jmp_to: rdi = target position (backwards) → jmp rel32
emit_jmp_to:
    push rdi
    mov edi, 0xE9
    call emit_byte
    pop rdi
    sub rdi, [size_code]
    sub rdi, 4
    jmp emit_dword

; emit_call_rt: edi = offset of the routine in the runtime table
emit_call_rt:
    push rdi
    mov edi, 0xE8
    call emit_byte
    pop rdi
    add rdi, SIZE_HEADER
    sub rdi, [size_code]
    sub rdi, 4
    jmp emit_dword

; patch_here: rdi = position of a rel32 → points it to the current position
patch_here:
    mov rax, [size_code]
    lea rcx, [rdi + 4]
    sub rax, rcx
    mov rcx, [base_code]
    mov [rcx + rdi], eax
    ret

; register_fixup: rdi = position of the rel32, rsi = offset in the constant arena
; (or rdi with bit 63 set and rsi = symbol of the called method)
register_fixup:
    mov rax, [n_fix]
    mov rcx, rax
    shl rcx, 4
    cmp rcx, SIZE_FIX - 16
    jae error_code_large
    add rcx, [base_fix]
    mov [rcx], rdi
    mov [rcx + 8], rsi
    inc rax
    mov [n_fix], rax
    ret

; Constants built by the compiler (runtime error messages, "").
; const_init ; const_put… ; const_close → rax = offset of the bytes
const_init:
    mov rax, [size_const]
    add rax, 7
    and rax, -8
    mov [const_head], rax
    add rax, 8
    mov [size_const], rax
    ret

; const_put: rdi = ptr, rsi = length
const_put:
    mov rdx, [size_const]
    lea rax, [rdx + rsi]
    cmp rax, SIZE_CONST - 16
    jae .large
    mov rcx, rsi
    mov rsi, rdi
    mov rdi, [base_const]
    add rdi, rdx
    mov [size_const], rax
    rep movsb
    ret
.large:
    ERROR "too many constants (limit 16 MiB)"

const_close:
    mov rdi, [base_const]
    mov rax, [size_const]
    mov byte [rdi + rax], 0         ; terminador
    mov rcx, [const_head]
    mov rdx, rax
    sub rdx, rcx
    sub rdx, 8
    mov [rdi + rcx], rdx            ; length
    inc rax
    mov [size_const], rax
    lea rax, [rcx + 8]
    ret

; emit_constantes: appends the strings after the code (aligned to 8) and
; resolves the rip-relative leas that point to them
emit_constantes:
    push rbx
    push r12
    push r13
.align:
    test qword [size_code], 7
    jz .aligned
    mov edi, 0xCC                   ; int3
    call emit_byte
    jmp .align
.aligned:
    mov rbx, [size_code]           ; offset of the constants in the file
    mov rsi, [base_const]
    mov rcx, [size_const]
    call emit_bytes
    mov r12, [base_fix]
    mov r13, [n_fix]
.repeat:
    test r13, r13
    jz .finish
    mov rax, [r12]                  ; position of the rel32 (bit 63: method call)
    mov rdx, [r12 + 8]              ; offset of the constant, or symbol of the method
    lea rcx, [rbx + rdx]
    btr rax, 63
    jnc .target
    mov rcx, [rdx + S_ADDRESS]
.target:
    lea r8, [rax + 4]
    sub rcx, r8
    mov rdi, [base_code]
    mov [rdi + rax], ecx
    add r12, 16
    dec r13
    jmp .repeat
.finish:
    pop r13
    pop r12
    pop rbx
    ret

; close_elf: fills in the segment sizes in the header
close_elf:
    mov rdi, [base_code]
    mov rax, [size_code]
    mov [rdi + OFS_FILESZ_CODE], rax
    mov [rdi + OFS_MEMSZ_CODE], rax
    mov rax, [n_globals]
    shl rax, 3
    add rax, GLOBALS - BASE_DATA
    mov [rdi + OFS_MEMSZ_DATA], rax
    ret

; =============================================================================
; Lexer
; =============================================================================

; next_token: reads the next token into tok_*
next_token:
    mov rsi, [lx_pos]
.space:
    movzx eax, byte [rsi]
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    cmp al, 13
    je .skip
    cmp al, 10
    je .line
    cmp al, '/'
    jne .start
    movzx ecx, byte [rsi + 1]
    cmp cl, '/'
    je .comment_line
    cmp cl, '*'
    je .comment_block
    jmp .start
.skip:
    inc rsi
    jmp .space
.line:
    inc rsi
    inc qword [lx_line]
    mov [lx_lstart], rsi
    jmp .space
.comment_line:
    add rsi, 2
.cl:
    movzx eax, byte [rsi]
    cmp al, 10
    je .space
    test al, al
    jz .space
    inc rsi
    jmp .cl
.comment_block:
    call .mark_token               ; the error points to the "/*"
    add rsi, 2
.cb:
    movzx eax, byte [rsi]
    test al, al
    jnz .cb_byte
    cmp rsi, [lx_end]
    jae .cb_without_end
    inc rsi
    jmp .cb
.cb_byte:
    cmp al, 10
    jne .cb_star
    inc rsi
    inc qword [lx_line]
    mov [lx_lstart], rsi
    jmp .cb
.cb_star:
    cmp al, '*'
    jne .cb_nxt
    cmp byte [rsi + 1], '/'
    jne .cb_nxt
    add rsi, 2
    jmp .space
.cb_nxt:
    inc rsi
    jmp .cb
.cb_without_end:
    ERROR "unterminated comment '/*'"

.mark_token:                       ; tok_start/line/lstart = current position (rsi)
    mov [tok_start], rsi
    mov rcx, [lx_line]
    mov [tok_line], rcx
    mov rcx, [lx_lstart]
    mov [tok_lstart], rcx
    ret

.start:
    call .mark_token
    mov qword [tok_value], 0
    test al, al
    jnz .has_byte
    cmp rsi, [lx_end]
    jae .end_file
    ERROR "null byte in the source code"
.end_file:
    mov qword [tok_type], T_END
    mov qword [tok_len], 0
    mov [lx_pos], rsi
    ret
.has_byte:
    mov ecx, eax
    or ecx, 0x20
    cmp ecx, 'a'
    jb .not_letter
    cmp ecx, 'z'
    jbe .ident
.not_letter:
    cmp al, '_'
    je .ident
    cmp al, '0'
    jb .not_digit
    cmp al, '9'
    jbe .number
.not_digit:
    cmp al, '"'
    je .string
    cmp al, "'"
    je .char
    jmp .operator

; ---- identifiers and named literals ----
.ident:
    lea rdi, [rsi + 1]
.id_loop:
    movzx eax, byte [rdi]
    call is_char_ident
    jnz .id_end
    inc rdi
    jmp .id_loop
.id_end:
    mov rcx, rdi
    sub rcx, rsi
    mov [tok_len], rcx
    mov [lx_pos], rdi
    mov qword [tok_type], T_IDENT
    cmp rcx, 1
    jne .id_true
    cmp byte [rsi], '_'
    jne .id_ret
    mov qword [tok_type], T_UNDERSCORE
    ret
.id_true:
    cmp rcx, 4
    jne .id_false
    cmp dword [rsi], 'true'
    jne .id_ret
    mov qword [tok_type], T_TRUE
    ret
.id_false:
    cmp rcx, 5
    jne .id_ret
    cmp dword [rsi], 'fals'
    jne .id_ret
    cmp byte [rsi + 4], 'e'
    jne .id_ret
    mov qword [tok_type], T_FALSE
.id_ret:
    ret

; ---- numbers ----
.number:
    xor r9d, r9d                    ; value
    cmp al, '0'
    jne .decimal
    movzx ecx, byte [rsi + 1]
    or ecx, 0x20
    cmp ecx, 'x'
    jne .decimal
    lea rdi, [rsi + 2]
    xor r10d, r10d                  ; digits
.hex:
    movzx eax, byte [rdi]
    call value_hex
    test eax, eax
    js .hex_end
    inc r10
    cmp r10, 16
    ja .large
    shl r9, 4
    or r9, rax
    inc rdi
    jmp .hex
.hex_end:
    test r10, r10
    jz .malformed
    jmp .num_end
.decimal:
    mov rdi, rsi
.dec:
    movzx r8d, byte [rdi]
    sub r8d, '0'
    cmp r8d, 9
    ja .dec_end
    mov rax, r9
    mov ecx, 10
    mul rcx
    jc .large
    add rax, r8
    jc .large
    mov r9, rax
    inc rdi
    jmp .dec
.dec_end:
    bt r9, 63
    jc .large
    cmp byte [rdi], '.'
    jne .num_end
    movzx eax, byte [rdi + 1]
    sub eax, '0'
    cmp eax, 9
    ja .num_end
    ERROR "FLOAT numbers are not supported by stage 0"
.num_end:
    movzx eax, byte [rdi]
    call is_char_ident
    jz .malformed
    mov [tok_value], r9
    mov qword [tok_type], T_INT
    mov rcx, rdi
    sub rcx, rsi
    mov [tok_len], rcx
    mov [lx_pos], rdi
    ret
.large:
    ERROR "integer too large (maximum 9223372036854775807, or 16 hex digits)"
.malformed:
    ERROR "malformed number"

; ---- strings: decoded straight into the constant arena ----
; layout: [length: 8 bytes][bytes...], aligned to 8; tok_value = offset of the bytes
.string:
    mov r8, [size_const]
    add r8, 7
    and r8, -8                      ; offset of the header
    lea r9, [r8 + 8]                ; next byte to write
    mov r10, [base_const]
    lea rdi, [rsi + 1]
.s_loop:
    cmp r9, SIZE_CONST - 16
    jae .s_large
    movzx eax, byte [rdi]
    cmp al, '"'
    je .s_end
    test al, al
    jz .s_null
    cmp al, 10
    je .s_break
    cmp al, '\'
    jne .s_normal
    mov [lx_backslash], rdi
    inc rdi
    call read_escape
    jmp .s_save
.s_normal:
    inc rdi
.s_save:
    mov [r10 + r9], al
    inc r9
    jmp .s_loop
.s_end:
    inc rdi
    mov rax, r9
    sub rax, r8
    sub rax, 8
    mov [r10 + r8], rax             ; length
    mov byte [r10 + r9], 0          ; terminator (for rt_error)
    inc r9
    mov [size_const], r9
    add r8, 8
    mov [tok_value], r8
    mov qword [tok_type], T_STR
    mov rcx, rdi
    sub rcx, rsi
    mov [tok_len], rcx
    mov [lx_pos], rdi
    ret
.s_null:
    cmp rdi, [lx_end]
    jb .null
    ERROR 'unterminated string (missing ")'
.null:
    ERROR "null byte in the source code"
.s_break:
    ERROR "line break inside a string (use \n)"
.s_large:
    ERROR "too many string literals (limit 16 MiB)"

; ---- characters: 'a' is an INT ----
.char:
    lea rdi, [rsi + 1]
    movzx eax, byte [rdi]
    cmp al, "'"
    je .c_empty
    cmp al, 10
    je .c_bad
    test al, al
    jz .c_bad
    cmp al, '\'
    jne .c_simple
    mov [lx_backslash], rdi
    inc rdi
    call read_escape
    jmp .c_close
.c_simple:
    cmp al, 0x80
    jae .c_utf8
    inc rdi
.c_close:
    cmp byte [rdi], "'"
    jne .c_bad
    inc rdi
    mov [tok_value], rax
    mov qword [tok_type], T_INT
    mov rcx, rdi
    sub rcx, rsi
    mov [tok_len], rcx
    mov [lx_pos], rdi
    ret
.c_empty:
    ERROR "empty character literal ('')"
.c_utf8:
    ERROR "a character literal must be a single ASCII byte"
.c_bad:
    ERROR "malformed character literal (missing the closing ')"

; ---- operators and punctuation ----
.operator:
    movzx ecx, byte [rsi + 1]
    mov edx, 1                      ; length
    mov r8d, eax                    ; type: the character itself
    cmp al, '='
    je .op_equal
    cmp al, '!'
    je .op_bang
    cmp al, '<'
    je .op_less
    cmp al, '>'
    je .op_bigger
    cmp al, '&'
    je .op_and
    cmp al, '|'
    je .op_or
    cmp al, ':'
    je .op_colon
    lea rdi, [simple]
.op_simple:
    movzx ecx, byte [rdi]
    test ecx, ecx
    jz .op_invalid
    cmp ecx, eax
    je .op_end
    inc rdi
    jmp .op_simple
.op_equal:
    cmp cl, '='
    jne .op_end
    mov r8d, T_EQ
    mov edx, 2
    jmp .op_end
.op_bang:
    cmp cl, '>'
    je .op_bang_gt
    cmp cl, '='
    jne .op_end
    mov r8d, T_NE
    mov edx, 2
    jmp .op_end
.op_bang_gt:
    cmp byte [rsi + 2], '>'
    jne .op_end
    mov r8d, T_ERROR_OUT
    mov edx, 3
    jmp .op_end
.op_colon:
    cmp cl, ':'
    jne .op_end
    mov r8d, T_EXIT
    mov edx, 2
    jmp .op_end
.op_less:
    cmp cl, '='
    jne .om_shl
    mov r8d, T_LE
    mov edx, 2
    jmp .op_end
.om_shl:
    cmp cl, '<'
    jne .op_end
    mov r8d, T_SHL
    mov edx, 2
    cmp byte [rsi + 2], '<'
    jne .op_end
    mov r8d, T_BYTE_IN
    mov edx, 3
    jmp .op_end
.op_bigger:
    cmp cl, '='
    jne .oM_shr
    mov r8d, T_GE
    mov edx, 2
    jmp .op_end
.oM_shr:
    cmp cl, '>'
    jne .op_end
    mov r8d, T_SHR
    mov edx, 2
    cmp byte [rsi + 2], '>'
    jne .op_end
    mov r8d, T_BYTE_OUT
    mov edx, 3
    jmp .op_end
.op_and:
    cmp cl, '&'
    jne .op_end
    mov r8d, T_AND
    mov edx, 2
    jmp .op_end
.op_or:
    cmp cl, '|'
    jne .op_end
    mov r8d, T_OR
    mov edx, 2
.op_end:
    mov [tok_type], r8
    mov [tok_len], rdx
    add rsi, rdx
    mov [lx_pos], rsi
    ret
.op_invalid:
    ERROR "invalid character"

; is_char_ident: eax = byte → ZF=1 if it is [A-Za-z0-9_]
is_char_ident:
    cmp eax, '_'
    je .sim_
    cmp eax, '0'
    jb .nao_
    cmp eax, '9'
    jbe .sim_
    mov ecx, eax
    or ecx, 0x20
    cmp ecx, 'a'
    jb .nao_
    cmp ecx, 'z'
    ja .nao_
.sim_:
    cmp eax, eax                    ; ZF = 1
    ret
.nao_:
    test esp, esp                   ; ZF = 0 (rsp is never 0)
    ret

; value_hex: eax = byte → eax = 0…15, or -1
value_hex:
    cmp eax, '0'
    jb .nao_
    cmp eax, '9'
    jbe .digit
    or eax, 0x20
    cmp eax, 'a'
    jb .nao_
    cmp eax, 'f'
    ja .nao_
    sub eax, 'a' - 10
    ret
.digit:
    sub eax, '0'
    ret
.nao_:
    mov eax, -1
    ret

; read_escape: rdi = byte after the '\' → eax = decoded byte, rdi advanced.
; Preserves rsi and r8–r10.
read_escape:
    movzx eax, byte [rdi]
    inc rdi
    cmp al, 'n'
    jne .t
    mov eax, 10
    ret
.t:
    cmp al, 't'
    jne .r
    mov eax, 9
    ret
.r:
    cmp al, 'r'
    jne .zero
    mov eax, 13
    ret
.zero:
    cmp al, '0'
    jne .literal
    xor eax, eax
    ret
.literal:
    cmp al, '\'
    je .ok
    cmp al, "'"
    je .ok
    cmp al, '"'
    je .ok
    cmp al, 'x'
    jne .bad
    movzx eax, byte [rdi]
    call value_hex
    test eax, eax
    js .bad
    mov ecx, eax
    shl ecx, 4
    movzx eax, byte [rdi + 1]
    call value_hex
    test eax, eax
    js .bad
    or eax, ecx
    add rdi, 2
.ok:
    ret
.bad:
    mov rax, [lx_backslash]
    mov [tok_start], rax
    ERROR "invalid escape sequence (use \n \t \r \0 \\ \' \x22 or \xHH)"

; =============================================================================
; Compile errors — "nihilc: file:line:column: message"
; =============================================================================

; expect: edi = token, rsi = description
expect:
    cmp [tok_type], rdi
    jne .err
    jmp next_token
.err:
    mov rdi, rsi
    ; falls through to error_expected

; error_expected: rdi = description of what was expected
error_expected:
    push rdi
    call error_start
    PUT "expected "
    pop rdi
    call put_cstr
    PUT ", found "
    cmp qword [tok_type], T_END
    jne .token
    PUT "the end of the file"
    jmp error_end
.token:
    PUT "'"
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    cmp rsi, 40
    jbe .brief
    mov esi, 40
.brief:
    call put_mem
    PUT "'"
    jmp error_end

; error_op_types: rdi = saved position of the operator (SAVE_POS), esi = left
; (or only) type, edx = right type (0 if there is none)
error_op_types:
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    call restore_pos
    call error_start
    PUT "operator '"
    mov rdi, [rbx + 24]
    mov rsi, [rbx + 16]
    call put_mem
    PUT "' does not accept "
    mov edi, r12d
    call put_type
    test r13d, r13d
    jz error_end
    PUT " and "
    mov edi, r13d
    call put_type
    jmp error_end

; restore_pos: rdi = block saved by SAVE_POS → puts tok_* back there
restore_pos:
    mov rax, [rdi]
    mov [tok_lstart], rax
    mov rax, [rdi + 8]
    mov [tok_line], rax
    mov rax, [rdi + 16]
    mov [tok_len], rax
    mov rax, [rdi + 24]
    mov [tok_start], rax
    ret

; erro_simples: rdi = mensagem
error_simple:
    push rdi
    call error_start
    pop rdi
    call put_cstr
    ; falls through to error_end

error_end:
    PUT 10
    mov edi, 2
    lea rsi, [msg_buf]
    mov rdx, [msg_len]
    call write_all
    mov eax, SYS_EXIT
    mov edi, 1
    syscall

; error_start: starts the message with "nihilc: file:line:column: "
error_start:
    mov qword [msg_len], 0
    PUT "nihilc: "
    cmp qword [expanding], 0
    je .mapped
    mov rdi, [name_current]           ; reading a raw file: its own lines
    mov [error_name], rdi
    call put_cstr
    PUT ":"
    mov rdi, [tok_line]
    call put_num
    jmp .column_start
.mapped:
    mov rax, [tok_start]
    sub rax, [base_source]
    call find_segment
    push rcx
    lea rdx, [seg_name]
    mov rdi, [rdx + rcx * 8]
    mov [error_name], rdi
    call put_cstr
    PUT ":"
    pop rcx
    mov rdi, [tok_line]
    lea rdx, [seg_bline]
    sub rdi, [rdx + rcx * 8]
    lea rdx, [seg_fline]
    add rdi, [rdx + rcx * 8]
    call put_num
.column_start:
    PUT ":"
    ; column in characters (UTF-8 continuation bytes do not count)
    mov rsi, [tok_lstart]
    mov rdx, [tok_start]
    xor eax, eax
.column:
    cmp rsi, rdx
    jae .end_column
    movzx ecx, byte [rsi]
    and ecx, 0xC0
    cmp ecx, 0x80
    je .continuation
    inc rax
.continuation:
    inc rsi
    jmp .column
.end_column:
    lea rdi, [rax + 1]
    call put_num
    PUT ": "
    ret

; put_mem: rdi = ptr, rsi = length (truncated at the buffer limit)
put_mem:
    mov rcx, [msg_len]
    mov rax, CAP_MSG
    sub rax, rcx
    cmp rsi, rax
    jbe .fits
    mov rsi, rax
.fits:
    lea rdx, [msg_buf]
    add rdx, rcx
    add [msg_len], rsi
    mov rcx, rsi
    mov rsi, rdi
    mov rdi, rdx
    rep movsb
    ret

; put_cstr: rdi = 0-terminated string
put_cstr:
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    jmp put_mem

; put_num: rdi = unsigned number
put_num:
    sub rsp, 32
    lea r8, [rsp + 32]
    mov rax, rdi
    mov ecx, 10
.digit:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz .digit
    mov rdi, r8
    lea rsi, [rsp + 32]
    sub rsi, r8
    call put_mem
    add rsp, 32
    ret

; put_type: edi = type
put_type:
    test edi, TYPE_ARR
    jz .simple
    push rdi
    PUT "ARRAY of "
    pop rdi
    and edi, 0x0F
.simple:
    lea rax, [tab_types]
    mov rdi, [rax + rdi * 8]
    jmp put_cstr

; =============================================================================
; Files and memory
; =============================================================================

; reserve_arenas: a single mmap split into source | symbols | code |
; fixups | constants
reserve_arenas:
    mov eax, SYS_MMAP
    xor edi, edi
    mov esi, SIZE_ARENAS
    mov edx, PROT_RW
    mov r10d, MAP_ANON_PRIV
    mov r8, -1
    xor r9d, r9d
    syscall
    test rax, rax
    js error_mmap
    mov [base_source], rax
    add rax, SIZE_SOURCE
    mov [base_sym], rax
    add rax, SIZE_SYM
    mov [base_code], rax
    add rax, SIZE_CODE
    mov [base_fix], rax
    add rax, SIZE_FIX
    mov [base_const], rax
    add rax, SIZE_CONST
    mov [base_param], rax
    add rax, SIZE_PARAM
    mov [base_raw], rax
    add rax, SIZE_RAW
    mov [base_names], rax
    ret


; =============================================================================
; Loading the program and inclusions (SPEC §16)
;
; Each file is read whole into the raw arena and copied into the expanded source.
; A line "@ "file";" at the top level is replaced by the contents of the file
; (once per path). The segments remember which file and line each stretch came
; from, for the error messages.
; =============================================================================

load_program:
    mov rdi, [path_input]
    call store_name
    mov qword [expanding], 1
    mov rdi, rax
    xor esi, esi
    call expand
    test rax, rax
    jz .not_opened
    mov qword [expanding], 0
    mov qword [size_const], 0        ; strings decoded during expansion do not count
    ret
.not_opened:
    lea rsi, [msg_open]
    mov edx, msg_open_len
    mov rdi, [path_input]
    jmp fail

; store_name: rdi = path (0-terminated) → rax = copy in the name table
store_name:
    mov rsi, [base_names]
    add rsi, [size_names]
    mov r8, rsi
.copy:
    mov rax, rsi
    sub rax, [base_names]
    cmp rax, SIZE_NAMES - 1
    jae .toomany
    mov al, [rdi]
    mov [rsi], al
    inc rdi
    inc rsi
    test al, al
    jnz .copy
    sub rsi, [base_names]
    mov [size_names], rsi
    mov rax, [n_names]
    cmp rax, MAX_NAMES
    jae .toomany
    lea rcx, [tab_names]
    mov [rcx + rax * 8], r8
    inc qword [n_names]
    mov rax, r8
    ret
.toomany:
    ERROR "too many included files"

; expand: rdi = path (in the name table), esi = depth.
; → rax = 1, or 0 if the file did not open
expand:
    push rbx                        ; path
    push r12                        ; profundidade
    push r13                        ; next raw byte to copy
    push r14                        ; depth of { }
    push r15                        ; token anterior
    push qword [name_current]
    mov rbx, rdi
    mov r12d, esi
    mov [name_current], rbx
    mov rdi, rbx
    call read_raw
    test rax, rax
    jz .not_opened
    mov [lx_pos], rax
    mov [lx_lstart], rax
    add rdx, rax
    mov [lx_end], rdx
    mov qword [lx_line], 1
    mov r13, rax
    mov rdi, rbx
    mov esi, 1
    call new_segment
    call next_token
    xor r14d, r14d
    mov r15d, T_END
.repeat:
    mov rax, [tok_type]
    cmp rax, T_END
    je .finish
    cmp rax, '@'
    jne .common
    test r14, r14
    jnz .common
    cmp r15, T_END                  ; only between commands
    je .directive
    cmp r15, ';'
    je .directive
    cmp r15, '}'
    je .directive
.common:
    cmp rax, '{'
    jne .c1
    inc r14
.c1:
    cmp rax, '}'
    jne .c2
    dec r14
.c2:
    mov r15, rax
    call next_token
    jmp .repeat

.directive:
    SAVE_POS                       ; [rsp]: position of the "@"
    mov rsi, [tok_lstart]             ; before the "@" on the line: only spaces
.before:
    cmp rsi, [tok_start]
    jae .before_ok
    mov al, [rsi]
    cmp al, ' '
    je .before_nxt
    cmp al, 9
    jne .not_alone
.before_nxt:
    inc rsi
    jmp .before
.before_ok:
    call next_token
    cmp qword [tok_type], T_STR
    jne .without_name
    push qword [tok_value]          ; [rsp]: path; [rsp + 8 …]: position of the "@"
    call next_token
    cmp qword [tok_type], ';'
    jne .without_point_comma
    mov rsi, [lx_pos]               ; after the ";": only spaces (or // …) up to the end of the line
.after:
    movzx eax, byte [rsi]
    cmp al, ' '
    je .after_nxt
    cmp al, 9
    je .after_nxt
    cmp al, 13
    je .after_nxt
    cmp al, 10
    je .end_line
    test al, al
    jnz .comment
    cmp rsi, [lx_end]
    jae .end_file
    jmp .not_alone_after
.comment:
    cmp al, '/'
    jne .not_alone_after
    cmp byte [rsi + 1], '/'
    jne .not_alone_after
.no_comment:
    movzx eax, byte [rsi]
    cmp al, 10
    je .end_line
    test al, al
    jz .end_file
    inc rsi
    jmp .no_comment
.after_nxt:
    inc rsi
    jmp .after
.end_line:
    inc rsi
.end_file:
    mov r14, rsi                    ; end of the directive's line (r14 = 0 for { } here)
    mov rdi, r13                    ; copies what comes before the directive's line
    mov rsi, [rsp + 8]              ; tok_lstart of the "@"
    call copy_source
    mov r13, r14
    mov rdi, rbx
    mov rsi, [rsp]
    call resolve_path
    test rdx, rdx
    jz .already_included
    cmp r12d, MAX_DEPTH_INCLUDE
    jae .deep_toomany
    mov r15, rax                    ; included path
    push qword [lx_end]
    mov rdi, rax
    lea esi, [r12 + 1]
    call expand
    pop qword [lx_end]
    test rax, rax
    jz .not_opened_included
.already_included:
    mov rdi, rbx                    ; this file continues from the next line
    mov rsi, [rsp + 16]             ; tok_line of the "@"
    inc rsi
    push rsi
    call new_segment
    pop rax
    mov [lx_line], rax
    mov [lx_pos], r13
    mov [lx_lstart], r13
    add rsp, 40
    xor r14d, r14d
    mov r15d, ';'
    call next_token
    jmp .repeat

.finish:
    mov rdi, r13
    mov rsi, [lx_end]
    call copy_source
    call source_ends_line
    mov eax, 1
.leave:
    pop qword [name_current]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.not_opened:
    xor eax, eax
    jmp .leave
.not_alone_after:
    lea rdi, [rsp + 8]              ; (the path is pushed on top)
    jmp .not_alone_pos
.not_alone:
    mov rdi, rsp
.not_alone_pos:
    call restore_pos
    ERROR `the inclusion @ "file"; must be alone on its line`
.without_name:
    lea rdi, [.d_name]
    jmp error_expected
.without_point_comma:
    EXPECT ';', "';'"
.deep_toomany:
    lea rdi, [rsp + 8]
    call restore_pos
    ERROR "inclusions nested too deeply (limit 64)"
.not_opened_included:
    lea rdi, [rsp + 8]
    call restore_pos
    call error_start
    PUT "could not read '"
    mov rdi, r15
    call put_cstr
    PUT "'"
    jmp error_end
[section .rodata]
.d_name: db "a quoted file name after '@'", 0
__?SECT?__

; resolve_path: rdi = including file, rsi = offset of the included path
; in the constant arena → rax = path in the name table; rdx = 1 if it is new,
; 0 if it was included before. A relative path = directory of the including file.
resolve_path:
    push rbx
    mov rbx, [base_names]
    add rbx, [size_names]            ; the new path is assembled here
    mov r8, rbx
    mov r9, [base_const]
    add r9, rsi                     ; bytes of the included path
    mov r10, [r9 - 8]               ; length
    lea rax, [r10 + 4096]
    add rax, [size_names]
    cmp rax, SIZE_NAMES
    jae store_name.toomany
    cmp byte [r9], '/'
    je .absolute
    mov rsi, rdi                    ; finds the last '/' of the including file
    xor r11d, r11d
.search:
    mov al, [rsi]
    test al, al
    jz .copy_dir
    cmp al, '/'
    jne .p_nxt
    lea r11, [rsi + 1]
.p_nxt:
    inc rsi
    jmp .search
.copy_dir:
    test r11, r11
    jz .absolute
.dir:
    cmp rdi, r11
    jae .absolute
    mov al, [rdi]
    mov [r8], al
    inc rdi
    inc r8
    jmp .dir
.absolute:
    xor ecx, ecx
.name:
    cmp rcx, r10
    jae .end_name
    mov al, [r9 + rcx]
    mov [r8], al
    inc r8
    inc rcx
    jmp .name
.end_name:
    mov byte [r8], 0
    ; already included?
    xor ecx, ecx
.seen:
    cmp rcx, [n_names]
    jae .new
    lea rax, [tab_names]
    mov rdi, [rax + rcx * 8]
    mov rsi, rbx
.compare:
    mov al, [rdi]
    cmp al, [rsi]
    jne .other
    test al, al
    jz .equal
    inc rdi
    inc rsi
    jmp .compare
.other:
    inc rcx
    jmp .seen
.equal:
    lea rax, [tab_names]
    mov rax, [rax + rcx * 8]
    xor edx, edx
    pop rbx
    ret
.new:
    mov rdi, rbx
    call store_name                ; (copies onto itself and registers it)
    mov edx, 1
    pop rbx
    ret

; read_raw: rdi = path → rax = start of the bytes (with a 0 after them), rdx = size;
; rax = 0 if it did not open
read_raw:
    push rbx
    push r12
    push r13
    push r14
    mov r14, rdi
    mov eax, SYS_OPENAT
    mov rdi, AT_FDCWD
    mov rsi, r14
    mov edx, the_RDONLY
    syscall
    test rax, rax
    js .nao_
    mov rbx, rax                    ; fd
    mov r12, [base_raw]
    add r12, [size_raw]            ; destino
    xor r13d, r13d                  ; lidos
.repeat:
    mov rdx, SIZE_RAW - 1
    sub rdx, [size_raw]
    sub rdx, r13
    jbe .large
    mov eax, SYS_READ
    mov rdi, rbx
    lea rsi, [r12 + r13]
    syscall
    test rax, rax
    js .err_read
    jz .finish
    add r13, rax
    jmp .repeat
.finish:
    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    mov byte [r12 + r13], 0
    lea rax, [r13 + 1]
    add [size_raw], rax
    mov rax, r12
    mov rdx, r13
    jmp .leave
.nao_:
    xor eax, eax
.leave:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.large:
    lea rsi, [msg_large]
    mov edx, msg_large_len
    mov rdi, r14
    jmp fail
.err_read:
    lea rsi, [msg_read]
    mov edx, msg_read_len
    mov rdi, r14
    jmp fail

; copy_source: copies the raw bytes [rdi, rsi) to the end of the expanded source
copy_source:
    mov rcx, rsi
    sub rcx, rdi
    jbe .finish
    mov rdx, [size_source]
    lea rax, [rdx + rcx]
    cmp rax, SIZE_SOURCE - 1
    jae .large
    mov [size_source], rax
    mov r8, [base_source]
    add r8, rdx
.repeat:
    mov al, [rdi]
    mov [r8], al
    cmp al, 10
    jne .nxt
    inc qword [lines_buf]
.nxt:
    inc rdi
    inc r8
    dec rcx
    jnz .repeat
.finish:
    ret
.large:
    lea rsi, [msg_large]
    mov edx, msg_large_len
    mov rdi, [path_input]
    jmp fail

; source_ends_line: makes sure the expanded source ends with "\n"
source_ends_line:
    mov rax, [size_source]
    test rax, rax
    jz .finish
    mov rdx, [base_source]
    cmp byte [rdx + rax - 1], 10
    je .finish
    cmp rax, SIZE_SOURCE - 1
    jae copy_source.large
    mov byte [rdx + rax], 10
    inc qword [size_source]
    inc qword [lines_buf]
.finish:
    ret

; new_segment: rdi = path, rsi = line of the file; starts at the end of the source
new_segment:
    mov rax, [n_seg]
    cmp rax, MAX_SEG
    jae .toomany
    lea rcx, [seg_start]
    mov rdx, [size_source]
    mov [rcx + rax * 8], rdx
    lea rcx, [seg_name]
    mov [rcx + rax * 8], rdi
    lea rcx, [seg_bline]
    mov rdx, [lines_buf]
    inc rdx
    mov [rcx + rax * 8], rdx
    lea rcx, [seg_fline]
    mov [rcx + rax * 8], rsi
    inc qword [n_seg]
    ret
.toomany:
    ERROR "too many inclusions"

; find_segment: rax = offset in the expanded source → rcx = segment
find_segment:
    mov rcx, [n_seg]
    lea rdx, [seg_start]
.repeat:
    dec rcx
    jz .finish
    cmp [rdx + rcx * 8], rax
    ja .repeat
.finish:
    ret

; put_line: rdi = line of the expanded source → "N" or "N in file"
put_line:
    push rbx
    push r12
    mov rbx, rdi
    mov rcx, [n_seg]
    lea rdx, [seg_bline]
.repeat:
    dec rcx
    jz .found
    cmp [rdx + rcx * 8], rbx
    ja .repeat
.found:
    mov r12, rcx
    lea rdx, [seg_fline]
    mov rdi, [rdx + r12 * 8]
    add rdi, rbx
    lea rdx, [seg_bline]
    sub rdi, [rdx + r12 * 8]
    call put_num
    lea rdx, [seg_name]
    mov rax, [rdx + r12 * 8]
    cmp rax, [error_name]
    je .finish
    push rax
    PUT " in "
    pop rdi
    call put_cstr
.finish:
    pop r12
    pop rbx
    ret

; read_source: (unused since inclusions; loading is done by load_program)
; The byte after the end is always 0 (the lexer's sentinel).
read_source:
    push rbx
    push r12
    mov eax, SYS_OPENAT
    mov rdi, AT_FDCWD
    mov rsi, [path_input]
    mov edx, the_RDONLY
    syscall
    test rax, rax
    js .err_open
    mov rbx, rax                    ; fd
    xor r12d, r12d                  ; bytes lidos
.repeat:
    mov rdx, SIZE_SOURCE - 1
    sub rdx, r12
    jz .err_large
    mov eax, SYS_READ
    mov rdi, rbx
    mov rsi, [base_source]
    add rsi, r12
    syscall
    test rax, rax
    js .err_read
    jz .finish
    add r12, rax
    jmp .repeat
.finish:
    mov [size_source], r12
    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    pop r12
    pop rbx
    ret
.err_open:
    lea rsi, [msg_open]
    mov edx, msg_open_len
    jmp .fail
.err_read:
    lea rsi, [msg_read]
    mov edx, msg_read_len
    jmp .fail
.err_large:
    lea rsi, [msg_large]
    mov edx, msg_large_len
.fail:
    mov rdi, [path_input]
    jmp fail

; save_output: creates the output file, writes the buffer and applies chmod 0755
; (the explicit chmod guarantees 0755 even if the file existed or with a umask).
save_output:
    push rbx
    mov eax, SYS_OPENAT
    mov rdi, AT_FDCWD
    mov rsi, [path_output]
    mov edx, the_WRITE_NEW
    mov r10d, MODE_EXEC
    syscall
    test rax, rax
    js .err_create
    mov rbx, rax
    mov rdi, rbx
    mov rsi, [base_code]
    mov rdx, [size_code]
    call write_all
    test rax, rax
    js .err_write
    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    mov eax, SYS_CHMOD
    mov rdi, [path_output]
    mov esi, MODE_EXEC
    syscall
    test rax, rax
    js .err_chmod
    pop rbx
    ret
.err_create:
    lea rsi, [msg_create]
    mov edx, msg_create_len
    jmp .fail
.err_write:
    lea rsi, [msg_write]
    mov edx, msg_write_len
    jmp .fail
.err_chmod:
    lea rsi, [msg_chmod]
    mov edx, msg_chmod_len
.fail:
    mov rdi, [path_output]
    jmp fail

; escreve_tudo: rdi = fd, rsi = ptr, rdx = len
; Repeats write until everything is written. Returns rax = 0, or negative on error.
write_all:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.repeat:
    test r13, r13
    jz .ok
    mov eax, SYS_WRITE
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    syscall
    test rax, rax
    js .finish
    jz .without_progress
    add r12, rax
    sub r13, rax
    jmp .repeat
.without_progress:
    mov rax, -5                     ; -EIO: write made no progress
    jmp .finish
.ok:
    xor eax, eax
.finish:
    pop r13
    pop r12
    pop rbx
    ret

; strlen: rdi = 0-terminated string → rax = length
strlen:
    xor eax, eax
.repeat:
    cmp byte [rdi + rax], 0
    je .finish
    inc rax
    jmp .repeat
.finish:
    ret

; Errors without a position. fail: rsi = message, rdx = length, rdi = complement
; (0-terminated string, or 0). Writes "nihilc: <msg><compl>\n" and exits with 1.
error_usage:
    lea rsi, [msg_usage]
    mov edx, msg_usage_len
    xor edi, edi
    jmp fail
error_mmap:
    lea rsi, [msg_mmap]
    mov edx, msg_mmap_len
    xor edi, edi
    jmp fail
error_code_large:
    lea rsi, [msg_code]
    mov edx, msg_code_len
    xor edi, edi
    ; falls through to fail

fail:
    mov r12, rsi
    mov r13, rdx
    mov r14, rdi
    mov edi, 2
    lea rsi, [prefix]
    mov edx, prefix_len
    call write_all
    mov edi, 2
    mov rsi, r12
    mov rdx, r13
    call write_all
    test r14, r14
    jz .nl
    mov rdi, r14
    call strlen
    mov rdx, rax
    mov edi, 2
    mov rsi, r14
    call write_all
.nl:
    mov edi, 2
    lea rsi, [new_line]
    mov edx, 1
    call write_all
    mov eax, SYS_EXIT
    mov edi, 1
    syscall
