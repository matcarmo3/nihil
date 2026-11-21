; =============================================================================
; commands.inc — the language's commands (included by nihilc.asm)
;
; Each function starts with the first token of the command in tok_* and ends with the
; token seguinte ao comando.
; =============================================================================

command:
    mov rax, [tok_type]
    cmp rax, T_SHR
    je cmd_print
    cmp rax, ':'
    je cmd_return
    cmp rax, '{'
    je block
    cmp rax, '*'
    je cmd_while
    cmp rax, T_IDENT
    je .ident
    cmp rax, T_BYTE_OUT
    je cmd_write_byte
    cmp rax, T_BYTE_IN
    je cmd_read_byte
    cmp rax, T_SHL
    je .in
    cmp rax, T_OR
    je .or_loose
    cmp rax, T_EXIT
    je cmd_exit
    cmp rax, T_ERROR_OUT
    je cmd_print_error
    cmp rax, '@'
    je .include_out
    ; tokens that can start an expression → a block governed by it
    lea rcx, [start_expr]
.start:
    mov edx, [rcx]
    test edx, edx
    jz .invalid
    cmp rdx, rax
    je cmd_expr_block
    add rcx, 4
    jmp .start
.invalid:
    lea rdi, [.d_command]
    jmp error_expected
.ident:
    call peek_type                 ; name = …  |  name(…)  |  name op … {
    cmp rax, '='
    je cmd_assignment
    cmp rax, '?'
    je cmd_assignment
    cmp rax, '['
    je .bracket
    cmp rax, '('
    jne cmd_expr_block
    ; name(…): it is the declaration if the method's symbol points to this token
    ; (the prescan registers the method at the position of the declared name)
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call lookup_symbol
    test rax, rax
    jz cmd_expr_block
    test byte [rax + S_FLAGS], FLAG_METHOD
    jz cmd_expr_block
    mov ecx, [rax + S_NAME_OFS]
    add rcx, [base_source]
    cmp rcx, [tok_start]
    jne cmd_expr_block
    jmp cmd_method
.in:
    ERROR "'<<' (text input) is only supported by stage 1"
.bracket:
    call bracket_then_equals  ; name[…] = …  or  name[…] op … {
    test eax, eax
    jnz cmd_assignment
    jmp cmd_expr_block
.include_out:
    ERROR `the inclusion @ "file"; can only appear at the top level, alone on its line`
.or_loose:
    ERROR "'||' only continues a conditional chain: cond { … } || cond { … } || { … }"
[section .rodata]
.d_command: db "a command", 0
start_expr: dd T_INT, T_TRUE, T_FALSE, T_STR, T_UNDERSCORE, '(', '[', '-', '!', '~', '#', '$', 0
__?SECT?__

; bracket_then_equals: tok = name, followed by "[". Returns eax = 1 if the
; matching "]" is followed by "=" (indexed assignment). Consumes nothing.
bracket_then_equals:
    push rbx
    sub rsp, 8 * (QWORDS_LEXER + 1)
    lea rsi, [lx_pos]
    mov rdi, rsp
    mov ecx, QWORDS_LEXER
    rep movsq
    mov rax, [size_const]
    mov [rsp + 8 * QWORDS_LEXER], rax
    call next_token              ; name → "["
    xor ebx, ebx                    ; depth of [ ]
.search:
    mov rax, [tok_type]
    cmp rax, T_END
    je .nao_
    cmp rax, '['
    jne .p1
    inc rbx
.p1:
    cmp rax, ']'
    jne .p2
    dec rbx
    jnz .p2
    call next_token
    xor eax, eax
    cmp qword [tok_type], '='
    sete al
    jmp .finish
.p2:
    call next_token
    jmp .search
.nao_:
    xor eax, eax
.finish:
    mov rbx, rax
    mov rsi, rsp
    lea rdi, [lx_pos]
    mov ecx, QWORDS_LEXER
    rep movsq
    mov rax, [rsp + 8 * QWORDS_LEXER]
    mov [size_const], rax
    mov rax, rbx
    add rsp, 8 * (QWORDS_LEXER + 1)
    pop rbx
    ret

; block ::= "{" command* "}"  — opens a scope: locals created here disappear at the "}"
block:
    push rbx
    push r12
    push r13
    mov r13, [tok_line]              ; line of the "{", for the unclosed-block error
    call next_token
    mov rbx, [n_sym]
    mov r12, [slots]
    inc qword [level]
.repeat:
    mov rax, [tok_type]
    cmp rax, '}'
    je .finish
    cmp rax, T_END
    je .opened
    call command
    jmp .repeat
.finish:
    call next_token
    mov [n_sym], rbx
    mov [slots], r12
    dec qword [level]
    pop r13
    pop r12
    pop rbx
    ret
.opened:
    call error_start
    PUT "missing '}' to close the block opened on line "
    mov rdi, r13
    call put_line
    jmp error_end

; expr { … }     INT: repeats N times; BOOL: conditional (with a "||" chain)
; expr method(…);   the same, with a call in place of the block
; method(…);     a call as a command
cmd_expr_block:
    SAVE_POS
    call expression
    mov rcx, [tok_type]
    cmp rcx, '{'
    je .block
    cmp rcx, ';'
    je .point_comma
    cmp rcx, T_IDENT
    je .prefix
    lea rdi, [.d_brace]
    jmp error_expected
.block:
    cmp eax, TYPE_BOOL
    je .conditional
    cmp eax, TYPE_INT
    je .counted
    cmp eax, TYPE_UNKNOWN
    jne .type_bad
.counted:
    add rsp, 32
    lea rdi, [block]
    jmp counted_loop
.conditional:
    add rsp, 32
    jmp conditional
.point_comma:
    ; only a call can be a command: nothing was emitted after it
    mov rdx, [call_end]
    cmp rdx, [size_code]
    jne .loose
    add rsp, 32
    jmp next_token
.loose:
    lea rdi, [.d_brace]
    jmp error_expected
.prefix:
    push rax
    call peek_type
    mov rcx, rax
    pop rax
    cmp rcx, '('
    jne .loose
    cmp eax, TYPE_BOOL
    je .if_call
    cmp eax, TYPE_INT
    je .count_call
    cmp eax, TYPE_UNKNOWN
    jne .type_bad
.count_call:
    add rsp, 32
    lea rdi, [cmd_call]
    jmp counted_loop
.if_call:
    add rsp, 32
    lea rdi, [cmd_call]
    jmp simple_if
.type_bad:
    mov ebx, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "before '{' or a call there must be an INT (repeat N times) or a BOOL (condition), but the expression is "
    mov edi, ebx
    call put_type
    jmp error_end
[section .rodata]
.d_brace: db "'{' after the expression (an expression alone is not a command)", 0
__?SECT?__

; cmd_call: name(…);  — body of "N name(…);" and "cond name(…);"
cmd_call:
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call lookup_symbol
    mov rdi, rax
    call call_method
    EXPECT ';', "';'"
    ret

; counted_loop: rdi = body function (block or cmd_call); count in rax.
; The count is evaluated once and kept in a hidden slot:
;   mov [rbp+c], rax
; top: cmp qword [rbp+c], 0 ; jle end
;   … body …
;   dec qword [rbp+c] ; jmp top
; end:
counted_loop:
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi
    call new_slot
    mov r12d, eax                   ; offset of the counter
    mov edi, r12d
    call emit_store_local
    mov r13, [size_code]           ; top
    EMIT 0x48, 0x83, 0xBD          ; cmp qword [rbp+disp32], imm8
    mov edi, r12d
    call emit_dword
    EMIT 0x00, 0x0F, 0x8E          ; 0 ; jle rel32
    mov r14, [size_code]
    xor edi, edi
    call emit_dword
    call r15
    EMIT 0x48, 0xFF, 0x8D          ; dec qword [rbp+disp32]
    mov edi, r12d
    call emit_dword
    mov rdi, r13
    call emit_jmp_to
    mov rdi, r14
    call patch_here
    dec qword [slots]               ; frees the counter
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; simple_if: rdi = body function; condition in rax.  test ; jz end ; body ; end:
simple_if:
    push r13
    push r15
    mov r15, rdi
    EMIT 0x48, 0x85, 0xC0, 0x0F, 0x84  ; test rax, rax ; jz end
    mov r13, [size_code]
    xor edi, edi
    call emit_dword
    call r15
    mov rdi, r13
    call patch_here
    pop r15
    pop r13
    ret

; cond { … } || cond { … } || { … }   — the condition is already in rax
; Each branch: test rax,rax ; jz next ; … ; jmp end. The pending "jmp end"s
; stay on the stack (r12 = how many) and are patched at the end.
conditional:
    push r12
    push r13
    xor r12d, r12d
.branch:
    EMIT 0x48, 0x85, 0xC0, 0x0F, 0x84  ; test rax, rax ; jz next
    mov r13, [size_code]
    xor edi, edi
    call emit_dword
    call block
    cmp qword [tok_type], T_OR
    jne .last
    mov edi, 0xE9                   ; jmp end
    call emit_byte
    push qword [size_code]
    inc r12
    xor edi, edi
    call emit_dword
    mov rdi, r13
    call patch_here               ; the next branch starts here
    call next_token              ; consome "||"
    cmp qword [tok_type], '{'
    je .else
    SAVE_POS
    call expression
    cmp eax, TYPE_BOOL
    je .cond_ok
    cmp eax, TYPE_UNKNOWN
    jne .not_bool
.cond_ok:
    add rsp, 32
    cmp qword [tok_type], '{'
    je .branch
    lea rdi, [.d_brace]
    jmp error_expected
.else:
    call block
    jmp .close
.last:
    mov rdi, r13
    call patch_here
.close:
    test r12, r12
    jz .finish
    pop rdi
    call patch_here
    dec r12
    jmp .close
.finish:
    cmp qword [tok_type], T_OR      ; "|| …" after the final else
    je .or_after_else
    pop r13
    pop r12
    ret
.not_bool:
    mov ebx, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "the condition after '||' must be BOOL, but the expression is "
    mov edi, ebx
    call put_type
    jmp error_end
.or_after_else:
    ERROR "nothing can come after the final branch '|| { … }'"
[section .rodata]
.d_brace: db "'{' after the condition", 0
__?SECT?__

; * cond { … }
; top: cond ; test rax,rax ; jz end ; … block … ; jmp top ; end:
cmd_while:
    push r13
    push r14
    call next_token              ; consome "*"
    mov r13, [size_code]
    SAVE_POS
    call expression
    cmp eax, TYPE_BOOL
    je .cond_ok
    cmp eax, TYPE_UNKNOWN
    jne .not_bool
.cond_ok:
    add rsp, 32
    cmp qword [tok_type], '{'
    jne .without_brace
    EMIT 0x48, 0x85, 0xC0, 0x0F, 0x84  ; test rax, rax ; jz end
    mov r14, [size_code]
    xor edi, edi
    call emit_dword
    call block
    mov rdi, r13
    call emit_jmp_to
    mov rdi, r14
    call patch_here
    pop r14
    pop r13
    ret
.without_brace:
    lea rdi, [.d_brace]
    jmp error_expected
.not_bool:
    mov ebx, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "'*' needs a BOOL condition (to repeat N times use 'N { … }'), but the expression is "
    mov edi, ebx
    call put_type
    jmp error_end
[section .rodata]
.d_brace: db "'{' after the condition of '*'", 0
__?SECT?__

; -----------------------------------------------------------------------------
; name(p1 = default, …) { … }   — method declaration (rax = symbol)
;
; Code:   jmp after
;   method: push rbp ; mov rbp, rsp ; sub rsp, N
;           … body … (each ":" emits leave ; ret)
;           leave ; ret            (method without a value)
;           error "ended without ':'" (method with a value)
;   after:
; The arguments are pushed from left to right: with n parameters,
; parameter i is at [rbp + 16 + 8·(n-1-i)].
cmd_method:
    push rbx                        ; method
    push r12                        ; rel32 of the jmp over the body
    push r13                        ; imm32 of the frame size
    push r14                        ; n
    push r15                        ; i
    mov rbx, rax
    mov edi, 0xE9
    call emit_byte
    mov r12, [size_code]
    xor edi, edi
    call emit_dword
    mov rax, [size_code]
    mov [rbx + S_ADDRESS], rax
    EMIT 0x55, 0x48, 0x89, 0xE5, 0x48, 0x81, 0xEC
    mov r13, [size_code]
    xor edi, edi
    call emit_dword
    push qword [slots]
    push qword [max_slots]
    push qword [n_sym]
    mov qword [slots], 0
    mov qword [max_slots], 0

    call next_token              ; name → "("
    call next_token              ; "(" → 1st parameter or ")"
    mov r14d, [rbx + S_NPARAM]
    xor r15d, r15d
.param:
    cmp qword [tok_type], ')'
    je .end_params
    ; (the form "name [= default]" was already checked by the prescan)
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call lookup_symbol
    test rax, rax
    jz .name_free
    test byte [rax + S_FLAGS], FLAG_GLOBAL  ; a parameter may hide a global
    jz .conflict
.name_free:
    mov rax, [rbx + S_EXTRA]
    add rax, r15
    shl rax, 4
    add rax, [base_param]
    mov rdx, [rax]                  ; type
    lea rcx, [r14 - 1]
    sub rcx, r15
    lea rcx, [rcx * 8 + 16]         ; offset from rbp
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call create_param
    call next_token              ; name → "="
.skip_default:
    call next_token
    cmp qword [tok_type], ','
    je .end_default
    cmp qword [tok_type], ')'
    jne .skip_default
.end_default:
    cmp qword [tok_type], ','
    jne .next
    call next_token
.next:
    inc r15
    jmp .param
.end_params:
    call next_token              ; ")" → "{"
    mov [method_current], rbx
    mov qword [saw_value], 0
    mov qword [saw_empty], 0
    call block

    cmp qword [saw_value], 0
    jne .armadilha
    EMIT 0xC9, 0xC3                ; leave ; ret
    cmp byte [rbx + S_TYPE], 0
    jne .close
    mov byte [rbx + S_TYPE], TYPE_NONE
    mov qword [discovered], 1
    jmp .close
.armadilha:
    ; a method with a value that reached the end without ":" — runtime error
    call const_init
    CONST_PUT "method '"
    mov edi, [rbx + S_NAME_OFS]
    add rdi, [base_source]
    movzx esi, word [rbx + S_NAME_LEN]
    call const_put
    CONST_PUT "' ended without returning a value (missing ': value;')"
    call const_close
    push rax
    EMIT 0x48, 0x8D, 0x35          ; lea rsi, [rip + mensagem]
    mov rdi, [size_code]
    pop rsi
    call register_fixup
    xor edi, edi
    call emit_dword
    CALL_RT RT_ERROR
.close:
    mov rax, [max_slots]            ; frame: slots × 8, aligned to 16
    shl rax, 3
    add rax, 15
    and rax, -16
    mov rcx, [base_code]
    mov [rcx + r13], eax
    pop qword [n_sym]
    pop qword [max_slots]
    pop qword [slots]
    mov qword [method_current], 0
    mov rdi, r12
    call patch_here
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.conflict:
    mov r12, rax
    call error_start
    PUT "parameter '"
    mov rdi, [tok_start]
    mov rsi, [tok_len]
    call put_mem
    test byte [r12 + S_FLAGS], FLAG_PARAM
    jnz .repeated
    test byte [r12 + S_FLAGS], FLAG_METHOD
.from_method:
    PUT "' has the same name as a method"
    jmp error_end
.repeated:
    PUT "' appears twice"
    jmp error_end

; -----------------------------------------------------------------------------
; >> expr ;
cmd_print:
    call next_token
    call expression
    cmp eax, TYPE_NONE
    je .none
    test eax, TYPE_ARR
    jnz .array
    cmp eax, TYPE_BOOL
    je .bool
    cmp eax, TYPE_STR
    je .str
    CALL_RT RT_PRINT_INT         ; INT (or provisional)
    jmp .finish
.str:
    CALL_RT RT_PRINT_STR
    jmp .finish
.bool:
    CALL_RT RT_PRINT_BOOL
.finish:
    EXPECT ';', "';'"
    ret
.none:
    ERROR "'>>' got a call to a method with no value"
.array:
    ERROR "'>>' does not print a whole ARRAY; loop over its elements"

; !>> expr ;   — like ">>", but to stderr (normal output is flushed first)
cmd_print_error:
    call next_token
    call expression
    cmp eax, TYPE_NONE
    je cmd_print.none
    test eax, TYPE_ARR
    jnz .array
    cmp eax, TYPE_BOOL
    je .bool
    cmp eax, TYPE_STR
    je .str
    CALL_RT RT_ERROR_INT
    jmp .finish
.str:
    CALL_RT RT_ERROR_STR
    jmp .finish
.bool:
    CALL_RT RT_ERROR_BOOL
.finish:
    EXPECT ';', "';'"
    ret
.array:
    ERROR "'!>>' does not print a whole ARRAY; loop over its elements"

; :: ;  |  :: expr ;   — ends the program from anywhere (code 0 or expr)
cmd_exit:
    call next_token
    cmp qword [tok_type], ';'
    jne .with_value
    EMIT 0x31, 0xFF                ; xor edi, edi
    jmp .do_call
.with_value:
    SAVE_POS
    call expression
    cmp eax, TYPE_INT
    je .ok
    cmp eax, TYPE_UNKNOWN
    jne .err
.ok:
    add rsp, 32
    EMIT 0x48, 0x89, 0xC7          ; mov rdi, rax
.do_call:
    CALL_RT RT_EXIT
    EXPECT ';', "';'"
    ret
.err:
    mov ebx, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "the exit code of '::' must be INT, but the expression is "
    mov edi, ebx
    call put_type
    jmp error_end

; >>> expr ;   — writes one raw byte (the low 8 bits)
cmd_write_byte:
    call next_token
    SAVE_POS
    call expression
    cmp eax, TYPE_INT
    je .ok
    cmp eax, TYPE_UNKNOWN
    jne .bad
.ok:
    add rsp, 32
    CALL_RT RT_WRITE_BYTE
    EXPECT ';', "';'"
    ret
.bad:
    mov ebx, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "'>>>' writes one byte and needs an INT, but the expression is "
    mov edi, ebx
    call put_type
    jmp error_end

; <<< name ;   — reads one raw byte into the INT name (-1 at the end of input).
; Reuses the assignment: the same stack that cmd_assignment builds.
cmd_read_byte:
    push rbx
    push r12
    push r13
    call next_token
    cmp qword [tok_type], T_IDENT
    jne .without_name
    SAVE_POS
    call next_token
    CALL_RT RT_READ_BYTE
    mov r13d, TYPE_INT
    jmp cmd_assignment.after_value
.without_name:
    lea rdi, [.d_name]
    jmp error_expected
[section .rodata]
.d_name: db "the name of an INT variable after '<<<'", 0
__?SECT?__

; :;  |  : expr ;     at the top level: ends the program; in a method: returns
cmd_return:
    cmp qword [method_current], 0
    jne method_return
    call next_token
    cmp qword [tok_type], ';'
    jne .with_value
    EMIT 0x31, 0xFF                ; xor edi, edi
    jmp .do_call
.with_value:
    SAVE_POS
    call expression
    cmp eax, TYPE_INT
    je .ok
    cmp eax, TYPE_UNKNOWN
    jne .err
.ok:
    add rsp, 32
    EMIT 0x48, 0x89, 0xC7          ; mov rdi, rax
.do_call:
    CALL_RT RT_EXIT
    EXPECT ';', "';'"
    ret
.err:
    mov ebx, eax
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "the exit code of ':' must be INT, but the expression is "
    mov edi, ebx
    call put_type
    jmp error_end

; ":" inside a method. The return type is that of the first ": expr;" with a known
; type; all the others must match it.
method_return:
    push rbx
    push r12
    mov rbx, [method_current]
    call next_token
    cmp qword [tok_type], ';'
    jne .value
    mov qword [saw_empty], 1
    cmp qword [saw_value], 0
    jne .mixed
    movzx eax, byte [rbx + S_TYPE]
    test eax, eax
    jz .emit_empty
    cmp eax, TYPE_NONE
    jne .empty_in_value
.emit_empty:
    EMIT 0xC9, 0xC3                ; leave ; ret
    jmp .finish
.value:
    SAVE_POS
    call expression
    mov r12d, eax
    cmp r12d, TYPE_NONE
    je .returns_none
    mov qword [saw_value], 1
    cmp qword [saw_empty], 0
    jne .mixed
    cmp r12d, TYPE_UNKNOWN
    je .emit
    movzx eax, byte [rbx + S_TYPE]
    test eax, eax
    jnz .compare
    mov [rbx + S_TYPE], r12b        ; first known type: locks it
    mov qword [discovered], 1
    jmp .emit
.compare:
    cmp eax, r12d
    jne .type_different
.emit:
    add rsp, 32
    EMIT 0xC9, 0xC3                ; leave ; ret
.finish:
    EXPECT ';', "';'"
    pop r12
    pop rbx
    ret
.mixed:
    ERROR "do not mix ':;' (no value) and ': value;' in the same method"
.empty_in_value:
    call error_start
    PUT "':;' has no value, but this method returns "
    movzx edi, byte [rbx + S_TYPE]
    call put_type
    jmp error_end
.returns_none:
    mov rdi, rsp
    call restore_pos
    ERROR "':' got a call to a method with no value"
.type_different:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "'"
    mov edi, [rbx + S_NAME_OFS]
    add rdi, [base_source]
    movzx esi, word [rbx + S_NAME_LEN]
    call put_mem
    PUT "' returns "
    movzx edi, byte [rbx + S_TYPE]
    call put_type
    PUT ", but this ':' returns "
    mov edi, r12d
    call put_type
    jmp error_end

; -----------------------------------------------------------------------------
; name = expr ;
cmd_assignment:
    push rbx
    push r12
    push r13
    SAVE_POS                       ; position of the name, for errors
    call next_token
    mov rax, [tok_type]
    cmp rax, '?'
    je .optional
    cmp rax, '['
    je .indexed
    EXPECT '=', "'='"
    call expression
    mov r13d, eax                   ; type of the value
.after_value:
    cmp r13d, TYPE_NONE
    je .value_none
    mov rdi, [rsp + 24]             ; name
    mov rsi, [rsp + 16]
    call lookup_symbol
    test rax, rax
    jnz .exists
    ; new name: a local (at the top level the prescan already registered every global)
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    mov edx, r13d
    cmp qword [level], 0
    jne .new_local
    call create_global
    jmp .exists
.new_local:
    call create_local
    mov rbx, rax
    jmp .store
.exists:
    mov rbx, rax
    mov cl, [rbx + S_FLAGS]
    test cl, FLAG_METHOD
    jnz .is_method
    test cl, FLAG_GLOBAL
    jz .local
    cmp qword [method_current], 0
    jne .global_in_method
    ; global, top-level code: the first assignment in the text creates the global
    test cl, FLAG_CREATED
    jnz .verify
    cmp qword [level], 0
    jne .global_early
    or byte [rbx + S_FLAGS], FLAG_CREATED
    cmp byte [rbx + S_TYPE], 0
    jne .verify
    cmp r13d, TYPE_UNKNOWN
    je .store
    mov [rbx + S_TYPE], r13b
    mov qword [discovered], 1
    jmp .store
.global_in_method:
    cmp byte [rbx + S_TYPE], 0
    jne .verify
    call global_unknown
    jmp .store
.local:
    cmp byte [rbx + S_TYPE], TYPE_UNKNOWN
    jne .verify
    cmp r13d, TYPE_UNKNOWN
    je .store
    mov [rbx + S_TYPE], r13b        ; a provisional local gets its real type
    jmp .store
.verify:
    cmp r13d, TYPE_UNKNOWN
    je .store
    movzx ecx, byte [rbx + S_TYPE]
    test ecx, ecx
    jz .store
    cmp ecx, r13d
    jne .err_type
.store:
    mov rdi, rbx
    call emit_store_var
    add rsp, 32
    EXPECT ';', "';'"
    pop r13
    pop r12
    pop rbx
    ret
.err_type:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "'"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' is "
    movzx edi, byte [rbx + S_TYPE]
    call put_type
    PUT " and cannot receive "
    mov edi, r13d
    call put_type
    jmp error_end
.global_early:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "'"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' is global and is only created on line "
    mov rdi, [rbx + S_EXTRA]
    call put_line
    PUT "; give it a value at the top level before this block"
    jmp error_end
.is_method:
    mov rdi, rsp
    call restore_pos
    ERROR "cannot assign to a method"
.value_none:
    ERROR "the assignment got a call to a method with no value"
.optional:
    ERROR "optional variables ('?') are not supported by stage 0"
.indexed:
    ; name[i] = value ;
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call lookup_symbol
    test rax, rax
    jz .indexed_not_exists
    mov rbx, rax
    test byte [rbx + S_FLAGS], FLAG_METHOD
    jnz .is_method
    movzx r12d, byte [rbx + S_TYPE]
    test byte [rbx + S_FLAGS], FLAG_GLOBAL
    jz .indexed_type
    cmp qword [method_current], 0
    jne .indexed_global_method
    test byte [rbx + S_FLAGS], FLAG_CREATED
    jz .indexed_early
    jmp .indexed_type
.indexed_global_method:
    test r12d, r12d
    jnz .indexed_type
    call global_unknown
    mov r12d, TYPE_UNKNOWN
.indexed_type:
    test r12d, r12d
    jnz .indexed_t
    mov r12d, TYPE_UNKNOWN
.indexed_t:
    cmp r12d, TYPE_UNKNOWN
    je .indexed_ok
    cmp r12d, TYPE_STR
    je .immutable
    test r12d, TYPE_ARR
    jz .not_array
.indexed_ok:
    call next_token              ; "[" → index
    call expression
    cmp eax, TYPE_INT
    je .idx_int
    cmp eax, TYPE_UNKNOWN
    jne .idx_bad
.idx_int:
    EMIT 0x50                      ; push rax  (index)
    EXPECT ']', "']'"
    EXPECT '=', "'='"
    call expression
    mov r13d, eax
    cmp r13d, TYPE_UNKNOWN
    je .idx_value_ok
    cmp r12d, TYPE_UNKNOWN
    je .idx_value_ok
    mov eax, r12d
    and eax, 0x0F
    cmp eax, r13d
    jne .idx_value_bad
.idx_value_ok:
    EMIT 0x48, 0x89, 0xC2, 0x59    ; mov rdx, rax ; pop rcx
    mov rdi, rbx
    call emit_load_var
    call emit_check_limit
    EMIT 0x48, 0x89, 0x14, 0xC8    ; mov [rax + rcx*8], rdx
    add rsp, 32
    EXPECT ';', "';'"
    pop r13
    pop r12
    pop rbx
    ret
.indexed_not_exists:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "variable '"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' does not exist"
    jmp error_end
.indexed_early:
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
.immutable:
    mov rdi, rsp
    call restore_pos
    ERROR "STRING is immutable: a character cannot be changed"
.not_array:
    mov rdi, rsp
    call restore_pos
    call error_start
    PUT "only an ARRAY can take 'name[i] = value', but '"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' is "
    mov edi, r12d
    call put_type
    jmp error_end
.idx_bad:
    mov r13d, eax
    call error_start
    PUT "the index must be INT, but it is "
    mov edi, r13d
    call put_type
    jmp error_end
.idx_value_bad:
    call error_start
    PUT "'"
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 16]
    call put_mem
    PUT "' is "
    mov edi, r12d
    call put_type
    PUT " and cannot receive "
    mov edi, r13d
    call put_type
    jmp error_end

; global_unknown: a global used in a method before its type is known.
; Outside the final pass it becomes a provisional type; in the final pass it is an error (rbx = symbol;
; [rsp + 8 …] = the name position saved by the caller is not used: the error points
; to the current token).
global_unknown:
    cmp qword [final_pass], 0
    jne .err
    inc qword [unknowns]
    mov eax, TYPE_UNKNOWN
    ret
.err:
    call error_start
    PUT "could not find out the type of the global '"
    mov edi, [rbx + S_NAME_OFS]
    add rdi, [base_source]
    movzx esi, word [rbx + S_NAME_LEN]
    call put_mem
    PUT "'"
    jmp error_end

