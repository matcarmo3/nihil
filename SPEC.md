# Nihil — Language Specification (v2.7)

> **Nihil**: an imperative, minimalist language compiled straight to x86_64 machine
> code, with no libc, no linker and no VM. The name is Latin for
> *nothing*: Nihil programs have no keywords at all, only symbols, and `_` is the
> value that is not there. Source files use the `.nihil` extension; the
> compiler is `nihilc`.
>
> Appendix A lists every change since v1.0 and the reason for it. v2.0 renamed
> the language (it was *Cru*, then *Ket*; *Nihil* since v2.2) and moved the whole
> project to English.

---

## 1. Overview and constraints

- **Philosophy:** imperative and structured, ultra-minimal syntax, **no
  keywords** (there is no `if`, `else`, `for`, `while`, `fn`, `let`, `return`
  or `null`), and **strong static typing by inference**. The only reserved
  names are the literals `true` and `false` and the symbol `_`.
- **Target:** native x86_64 machine code for Linux, with no libc: only direct
  system calls.
- **Output:** an **ELF64** executable that the compiler assembles in memory and
  writes with mode `0755`. No `ld`.
- **Bootstrap compiler (stage 0):** x86_64 assembly (NASM, Intel syntax),
  using only `openat`, `read`, `write`, `close`, `mmap`, `chmod` and `exit`.
- **Self-hosting:** stage 0 implements just the **core** needed to rewrite the
  compiler in Nihil (§10). Stage 1 (`nihilc1`, §15) is that compiler, written in
  Nihil; it compiles itself and implements the rest of the language.

Usage:

```text
nihilc input.nihil [output]       # default output: a.out
```

---

## 2. Lexical structure

| Element | Form |
|---|---|
| Identifier | `[A-Za-z_][A-Za-z0-9_]*`, except a lone `_` |
| Integer | decimal `123`, hexadecimal `0x7F` |
| Character | `'a'`, `'\n'` → an **INT** holding the byte value |
| Float | `0.1`, `3.0`, `1.5e-10` (needs digits on both sides of the point) |
| String | `"text"` |
| Boolean | `true`, `false` |
| Absence | `_` |
| Comments | `// to the end of the line` and `/* block */` (they do not nest) |

Escapes in strings and characters: `\n \t \r \0 \\ \' \" \xHH`.

Spaces, tabs and line breaks only separate tokens. `;` ends a command.

---

## 3. Types and representation

Every value fits in **one 64-bit register**, except optionals.

| Type | Representation |
|---|---|
| `INT` | signed 64-bit integer |
| `FLOAT` | IEEE-754 `double`. Its 64 bits live in `rax` like any other value; arithmetic goes through `xmm0` and `xmm1` (SSE2) |
| `BOOL` | 0 or 1 in a 64-bit register; 8 bytes in memory |
| `STRING` | pointer to the bytes; the **length is in the 8 bytes before the pointer**, and a 0 byte follows the text. Immutable |
| `ARRAY` | pointer to 8-byte elements; the **length is in the 8 bytes before**. Fixed size, mutable contents |
| optional `T?` (any T) | value + presence flag: `rax` + `rdx` in registers, two 8-byte words in memory. `_` is value 0 and flag 0 |

- Arrays and strings are passed and assigned **by reference**: after `a = b;`
  both names point to the same block.
- An array's type is inferred from its first element. All elements must have
  the same type.
- There are no implicit conversions between types.

---

## 4. Variables and scope

- A variable is created by its first assignment. Its type comes from the value
  and is **locked**: assigning a value of another type is a compile error.
- **Globals** are the variables assigned at the top level, outside any block.
  The prescan collects them (§9.2), so every method sees them, whatever their
  order in the text.
- **Locals** are created inside a method or a `{ }` block and disappear at the
  `}` that closes the block.
- **Name lookup:** the current block, then the enclosing blocks, then the
  method's parameters, then the globals. If the name is found nowhere, the
  assignment creates a local.
- **Locals never hide globals.** If a name belongs to a global, an assignment
  inside a block or method changes the global, whatever the order of the
  declarations. Only a **parameter**, which is declared explicitly, can have the
  name of a global and hide it inside its method. A parameter with a method's
  name is an error.
- Reading a variable that does not exist yet is a compile error.
- **A global is born at the top level.** If a name is assigned at the top level,
  using it inside a block *before* that assignment in the text is a compile
  error, not a local with the same name:
  ```text
  3 { total = total + 1; }   // error: 'total' does not exist here yet (it is created on line 2)
  total = 0;
  ```
  This way a global is never read before it gets a value, and no name means two
  different things in the same program.
- **Inside methods** this ordering rule does not apply: a method may use a
  global created further down. If it runs before that assignment, it reads the
  initial value: `0`, `false` or `""`. STRING and ARRAY globals start as empty
  values, never as null pointers.

---

## 5. Absence (`_`) and optionals (`?`)

- `_` means "no value".
- Ordinary variables **do not accept** `_`.
- The `?` suffix at **creation** declares an optional: `b? = 10;`. From then on
  the variable is used without the `?`: `b = _;`, `b = 7;`.
- The initial value must be concrete, because it gives the type. To start
  empty, write `b? = 0; b = _;`. `b? = _;` is a compile error.
- `x == _` and `x != _` test for presence. They are only valid when `x` is
  optional.
- **The only way to extract the value is the `||` fallback:** `v = b || 5;`
  gives a non-optional `INT`.
- `>> b;` with an optional `b` prints the value, or `_` when it is empty.
- A T converts to T? automatically, and so does `_`, when assigning, passing an
  argument and returning. The other direction never happens automatically, only
  through `||`.
- A variable without `?` accepts neither T? nor `_`; the error message suggests
  `name? = …`.
- Optionals take part in no arithmetic, indexing, `#`, conditions or `==`, except
  `== _` and `!= _`. Arrays of optionals are not supported yet.
- **Optional parameters:** `f(n? = 0)` accepts INT, INT? or `_`. The default
  (when the argument is omitted) is present.
- **Optional return:** if a method has `: value;` of type T and also `: _;` (or a
  `: x;` where x is a T?), it returns T?.

  ```text
  find(v = [0], x = 0) {
      i = 0;
      * i < #v { v[i] == x { : i; } i = i + 1; }
      : _;                         // find returns INT?
  }
  pos = find(nums, 8) || -1;
  ```
- **`@? path`** is like `@` (§6.1), but returns `STRING?`: `_` when the file
  cannot be opened, instead of a runtime error.

### 5.1 The three roles of `||`

| Context | Meaning |
|---|---|
| After `}` | `else` / `else if` (§7.3) |
| **Optional** left side | fallback: the left value if present, otherwise the right one |
| Non-optional `BOOL` left side | logical OR with short-circuit |

An optional `BOOL` on the left follows the second row: `x || y` is a fallback.
For a logical OR with an optional `x`, write `(x || false) || y`.

---

## 6. Expressions

### 6.1 Precedence (lowest to highest)

| Level | Operators | Operands |
|---|---|---|
| 1 | `\|\|` | §5.1 |
| 2 | `&&` | BOOL, short-circuit |
| 3 | `== != < > <= >=` | same type; **non-associative** (`a < b < c` is an error) |
| 4 | `\|` | INT (bits) |
| 5 | `^` | INT (bits) |
| 6 | `&` | INT (bits) |
| 7 | `<< >>` | INT, shifts (`>>` is arithmetic) |
| 8 | `+ -` | INT or FLOAT; `+` also concatenates STRINGs |
| 9 | `* / %` | INT or FLOAT (`%` INT only) |
| 10 | unary `- ! ~ # @ @? $ .` | see below |
| 11 | postfix `x[i]`, `r.field`, `f(...)` | indexing, field, call |

Unary operators:

| Operator | Meaning |
|---|---|
| `-x` | negation (INT or FLOAT) |
| `!x` | BOOL not |
| `~x` | INT bitwise not |
| `#x` | length of a STRING or ARRAY; for a FLOAT, the integer part (truncation toward zero) |
| `@path` | the whole contents of a file, as a STRING (runtime error if it cannot be read) |
| `@?path` | the same, as a `STRING?` (`_` if it cannot be read) |
| `$bytes` | a new STRING with the low byte of each element of an ARRAY of INT |
| `.n` | INT → FLOAT |

- Bit operators sit **above** comparisons, so `a & 1 == 0` is `(a & 1) == 0`.
  This fixes C's classic trap.
- `<<` and `>>` are shifts **inside expressions**. At the start of a command they
  are input and output (§8). There is no ambiguity: in `>> a >> 2;` the first
  `>>` is the output command and the second is a shift.
- `==` between STRINGs compares their contents.
- `s[i]` on a STRING gives an INT from 0 to 255 and is read-only. `a[i]` on an
  ARRAY reads and writes.
- An **index out of bounds** ends the program with a runtime error (§8.3).
- INT arithmetic wraps around at 64 bits (`9223372036854775807 + 1` is the
  minimum).
- `/` truncates toward zero and `%` takes the sign of the dividend, as in C
  (`-7 / 2 == -3`, `-7 % 2 == -1`). `MIN / -1` gives `MIN` and `MIN % -1` gives
  `0`.
- Division by zero is a runtime error.
- Shifts use only the low 6 bits of the count (`1 << 64 == 1`).
- The largest decimal literal is `9223372036854775807`; the minimum is written
  `-9223372036854775807 - 1`. Hexadecimal literals take up to 16 digits and can
  express any 64-bit pattern (`0xFFFFFFFFFFFFFFFF == -1`).
- `$` is how text is built: fill an array and convert it.
  ```text
  buf = [0 ; 2];  buf[0] = 'o'; buf[1] = 'k';
  name = $buf;
  contents = @name;
  ```

### 6.1.1 FLOAT

- **Literals:** `0.5`, `3.0`, `1.5e-10`, `2.0E+8`. They need digits on both sides
  of the point; the exponent is optional. `.5` and `1e5` are errors. Literals are
  rounded correctly to the nearest `double`. Going past the largest `double` is
  a compile error.
- **Operations:** `+ - * /` and comparisons between two FLOATs, with IEEE-754
  semantics: `x / 0.0` is `inf`, `0.0 / 0.0` is `nan`, and with `nan` only `!=`
  is true. `%`, bit operators and mixing with INT are compile errors.
- **Conversions** (no keywords):
  - `.n`: INT → FLOAT ("gains the decimal point"), as in `.(#v)`;
  - `#f`: FLOAT → INT, truncating toward zero ("integer part"). Outside the INT
    range it gives the minimum INT.
- **Text:** `>>` writes the **shortest decimal that reads back as the same
  number** (`0.1`, not `0.10000000000000001`), always with a point (`3.0`). It
  uses scientific notation outside 10⁻⁷ … 10²¹ (`1.0e+21`, `5.0e-324`).
  Specials: `inf`, `-inf`, `nan`, `-0.0`.
- Arrays of FLOAT, FLOAT?, parameters (`x = 0.0`, `y = -1.5`) and return values
  work as for the other types.

### 6.1.2 Concatenation

`"a" + "b"` creates a new STRING. Only STRING + STRING; for numbers, build the
text with `$` or print it in parts.

### 6.2 Array constructors

```text
nums = [10, 20, 30];     // literal
buf  = [0 ; 65536];      // repetition: 65536 zeroed INTs
n    = #buf;             // 65536
```

An empty `[]` is a compile error, because there is nothing to take the type
from. Use `[0 ; 0]`.

- Elements can be INT, BOOL, STRING or FLOAT. Arrays of arrays are not
  supported yet.
- `a[i] = v;` changes an element. At the start of a command, `name[…]` is an
  assignment only if the matching `]` is followed by `=`; otherwise it is an
  expression, as in `flags[i] { … }` or `v[0] == 3 { … }`.
- Arrays cannot be compared with `==`.
- Arrays live in a heap that only grows. It is requested from the kernel in
  16 MiB blocks (`mmap`) and never freed.

---

## 7. Control flow (no keywords)

Every `{ ... }` block is governed by the expression right before it. The
**type** of that expression decides what the block does.

### 7.1 Plain scope (no prefix)

Runs once and just opens a scope.

```text
{ t = 1; b = b + t; }
```

### 7.2 Counted repetition (`INT` prefix)

```text
3 { b = b + 1; }
n * 2 { >> "."; }
```

- The count is evaluated **once**, on entry.
- A count `<= 0` does not run the block.
- The counter is hidden: a stack slot in stage 0, and in stage 1 a register when
  one is free. Neither `syscall` (which destroys `rcx` and `r11`), nor calls, nor
  nested loops affect it.

### 7.3 Conditional (`BOOL` prefix)

```text
x > 10 {
    >> "large";
} || x > 5 {
    >> "medium";
} || {
    >> "small";
}
```

- The branches are exclusive: only the first one whose condition is true runs.
- `} || cond {` works as `else if`; `} || {` as the final `else`.

### 7.4 Conditional loop (`*` prefix)

```text
* b < 10 { b = b + 1; }
```

The condition is evaluated again before each turn. A `*` at the start of a
command is always the loop; multiplication never appears in that position.

### 7.5 Prefixed calls

```text
3 blink();           // calls 3 times
m > 20 add(5);       // calls if m > 20
```

---

## 8. Input and output

### 8.1 Commands

| Command | Effect |
|---|---|
| `>> expr;` | Writes text: INT in decimal, BOOL as `true`/`false`, STRING as is, FLOAT as in §6.1.1, an empty optional as `_`. **No newline is added.** |
| `<< x;` | Reads a line (without the `\n`) and converts it to the type of `x` (§8.2). |
| `>>> expr;` | Writes **one raw byte**: the low 8 bits of an INT. |
| `<<< x;` | Reads **one raw byte** into the INT `x`; gives `-1` at the end of input. |
| `!>> expr;` | Like `>>`, but to **standard error**. It flushes standard output first, to keep the order on a terminal. |
| `:: expr;` / `::;` | **Ends the program from anywhere**, including from inside methods, with exit code `expr` (an INT) or 0. Output is flushed first. |
| `... expr;` | **Waits** `expr` milliseconds (an INT; `<= 0` does not wait). Output is flushed first, so what was written shows up before the pause. Uses `nanosleep` and resumes after a signal (stage 1). |
| `@>> path, text;` | **Writes a file**: creates it or replaces its contents with the STRING `text` (stage 1). Atomic: the text goes to `path.nihil-tmp`, which is synced to disk (`fsync`) and renamed over `path`, so a crash leaves the old file or the new one, never a mix. A new file gets mode `0644` (minus the umask); a replaced file gets those permissions too. |
| `@+>> path, text;` | **Appends** `text` to the file, creating it if needed, and syncs it to disk before going on (stage 1). |
| `@[i]>> path, r;` | **Changes record `i`** of a table file in place, writing only that line (§20.4, stage 1). |
| `@{}>> path, r;` | **Writes `r` under its key**: replaces the record with the same key, or adds `r` (§20.5, stage 1). |

### 8.1.1 Writing files

Both `path` and `text` are STRINGs (bytes: use `$` to write an ARRAY of INT).
If the file cannot be written, the program **ends with a runtime error** and
exit code 2, naming the file and the reason:

```text
nihil: could not write 'notes/today.txt': no such file or directory
```

The reasons spelled out are: no such file or directory, permission denied, it
is a directory, a part of the path is not a directory, no space left on the
device, read-only file system, the path is too long (over 4080 bytes), disk
quota exceeded; any other one is shown as `error N` (the `errno`). A failed
`@>>` removes its temporary file. Both commands sync every write, which makes
them durable but slow in a tight loop (a few milliseconds each): build the text
first and write it once when you can.

### 8.2 Rules for `<<`

- `<< x;` requires that `x` already exist: its type says how to convert the
  line (INT, BOOL, STRING or FLOAT, optionals included). A `\r` before the `\n`
  is dropped.
- With an optional `x`, at the end of input `x` gets `_`.
- With a non-optional `x`, at the end of input `x` gets `0`, `""`, `false` or
  `0.0`.
- Text that is not valid for the type is a runtime error
  (`nihil: the input is not a valid INT: 'twelve'`).

### 8.3 Buffers and runtime errors

- Standard output goes through a 64 KiB buffer. It is flushed when full, at the
  end of the program and before any read (`<<` or `<<<`), so prompts appear
  before the program waits for input.
- A runtime error (index out of bounds, division by zero, invalid input, …)
  flushes the output, writes `nihil: <reason>` to standard error and exits with
  code **2**. The existing ones are: `division by zero`,
  `index 5 out of bounds (size 3)`, `negative array size`, `array too large`,
  `out of memory`, `could not read 'x'`,
  `method 'f' ended without returning a value` and the input errors of `<<`.

---

## 9. Methods

### 9.1 Declaration, call and return

```text
max(a = 0, b = 0) {
    a > b { : a; }
    : b;
}

m = max(10, 25);
```

- Methods can only be declared **at the top level**.
- At the top level, `name() {` and `name(p = … ) {` are **declarations**: empty
  parentheses, or parentheses starting with `name =` or `name?`. Any other form
  is a call: `even(4) { … }` calls `even` and uses the result for the block.
  Inside a block or method, `f() { … }` is always a call.
- Each parameter's type comes from its default value: `x = 0` gives INT,
  `x? = 0` an optional INT, `v = [0]` an ARRAY of INT.
- **The default must be a literal**: `0`, `-1`, `0xFF`, `'a'`, `"text"`,
  `true`, `false` or a FLOAT. It is put in place of every omitted argument.
- For an ARRAY parameter the default is a **one-element** literal, such as
  `v = [0]`, `l = [""]` or `f = [false]`. Each call that omits the argument gets
  a **new** array with that element.
- Arguments can be omitted **from the right**; the omitted ones get their
  defaults.
- Scalars are passed by value; STRING and ARRAY by reference.
- `: expr;` returns the value. The return type is that of the first `:` with a
  known type, and every other `:` must match it (with the optional rule of §5).
- `:;` returns without a value. A method without `: expr` cannot appear in an
  expression, only as a command (`f();`). Mixing `:;` and `: expr;` in the same
  method is an error.
- A method with a value that reaches the end of its body without `:` ends the
  program with the runtime error `nihil: method 'f' ended without returning a
  value`.
- **At the top level:** `: expr;` ends the program with exit code `expr` (an
  INT; the system keeps only the low 8 bits, so `: 256 + 7;` exits with 7), and
  `:;` exits with 0. Reaching the end of the file also exits with 0. Output is
  flushed before exiting.

### 9.2 Order, recursion and passes

1. **Prescan (tokens only):** registers the globals and the methods with their
   parameter types.
2. **Compilation passes:** each pass compiles the whole program. A call to a
   method whose return type is not known yet gets a **provisional** type, which
   operators accept without complaint; the types discovered are kept for the
   next pass.
   - If a pass used no provisional type, its code is final. Most programs are
     done after the first pass.
   - If an already known type changes (an INT return becomes INT? when a `: _;`
     shows up), the pass is redone.
   - If nothing new was discovered, the next pass is **strict**: a provisional
     type in it becomes an error.

So a method can call another one declared further down, and recursion (mutual
recursion too) works. A recursive method needs at least one `:` whose type does
not depend on itself:

```text
fact(n = 0) {
    n <= 1 { : 1; }      // fixes the return type as INT
    : n * fact(n - 1);
}
```

---

## 10. The stage 0 core

The assembly compiler implements **only** what the compiler written in Nihil
needs:

- INT, BOOL, STRING and ARRAY (of INT, BOOL or STRING), with literals,
  characters and hexadecimals;
- every INT and BOOL operator (§6), `#`, indexing, `[v ; n]`;
- globals, locals, blocks and the four forms of control flow;
- methods, recursion, the passes, `:`;
- `>>`, `>>>`, `<<<`, `!>>`, `::`, `@`, `$` and inclusion (§16).

Optionals, FLOAT, STRING concatenation, `<<`, `...`, `@>>`/`@+>>`, data models
and the optimizations exist only in stage 1 (§17).

---

## 11. Grammar (EBNF)

```ebnf
program         ::= command*

command         ::= method                      (* top level only *)
                  | model                       (* top level only, §20 *)
                  | ">>"  expression ";"
                  | "!>>" expression ";"
                  | "::" [ expression ] ";"
                  | "..." expression ";"
                  | ( "@>>" | "@+>>" ) expression "," expression ";"
                  | "@" "[" expression "]" ">>" expression "," expression ";"
                  | "@" "{" "}" ">>" expression "," expression ";"   (* by key, §20.5 *)
                  | ">>>" expression ";"
                  | "<<"  IDENT ";"
                  | "<<<" IDENT ";"
                  | ":" [ expression ] ";"
                  | "*" expression block
                  | assignment ";"
                  | [ expression ] block ( "||" [ expression ] block )*
                  | [ expression ] call ";"
                  | "@" STRING ";"              (* inclusion, §16 *)

method          ::= IDENT "(" [ param ( "," param )* ] ")" block
param           ::= IDENT [ "?" ] "=" ( literal | IDENT "(" ")" | "[" IDENT "(" ")" "]" )
model           ::= IDENT "=" "@" "[" field ( ";" field )* [ ";" ] "]" ";"
field           ::= [ "#" ] IDENT ":" ( ( "INT" | "STRING" | "FLOAT" ) "(" INTEGER ")" | "BOOL" )
block           ::= "{" command* "}"
assignment      ::= IDENT [ "?" ] [ "[" expression "]" ] "=" expression
                  | IDENT ( "[" expression "]" | "." IDENT )* "." IDENT "=" expression
call            ::= IDENT "(" [ expression ( "," expression )* ] ")"

expression      ::= or
or              ::= and  ( "||" and )*
and             ::= comp ( "&&" comp )*
comp            ::= bor  [ ( "==" | "!=" | "<" | ">" | "<=" | ">=" ) bor ]
bor             ::= bxor ( "|" bxor )*
bxor            ::= band ( "^" band )*
band            ::= shift ( "&" shift )*
shift           ::= sum  ( ( "<<" | ">>" ) sum )*
sum             ::= prod ( ( "+" | "-" ) prod )*
prod            ::= unary ( ( "*" | "/" | "%" ) unary )*
unary           ::= ( "-" | "!" | "~" | "#" | "@" | "@?" | "$" | "." ) unary | postfix
postfix         ::= primary ( "[" expression "]" | "." IDENT )*
primary         ::= INTEGER | CHARACTER | FLOAT | STRING | "true" | "false" | "_"
                  | "[" expression ( "," expression )* "]"
                  | "[" expression ";" expression "]"
                  | call                        (* also MODEL( … ): a new record *)
                  | IDENT ( "@" | "@?" ) unary  (* IDENT is a model: reads a table *)
                  | IDENT ( "@" | "@?" ) "[" expression "]" unary   (* one record, §20.4 *)
                  | IDENT "@" "#" unary         (* how many records *)
                  | IDENT ( "@" | "@?" ) "{" expression "}" unary   (* by key, §20.5 *)
                  | IDENT
                  | "(" expression ")"
```

### 11.1 Command disambiguation

The grammar is LL(1) except at the start of a command that begins with `IDENT`.
The parser decides in this order:

1. `IDENT` followed by `=`, or by `?` `=`: **assignment**.
2. `IDENT [` … `] =` (scanning for the matching `]`): **indexed assignment**.
3. At the top level, `IDENT (` … `) {` in declaration form (§9.1): **method
   declaration**.
4. Otherwise: parse an **expression** and look at the next token:
   - `{` → a block governed by the expression;
   - `IDENT` → a prefixed call (§7.5);
   - `;` → valid only if the whole expression is a call;
   - anything else → error.

---

## 12. Compiler architecture (stage 0)

### 12.1 Memory

A single `mmap` (`PROT_READ|PROT_WRITE`, `MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE`)
reserves the arenas:

| Arena | Size | Use |
|---|---|---|
| Source | 16 MiB | expanded source (§16) |
| Symbols | 4 MiB | 32-byte records |
| Code | 16 MiB | ELF header + machine code + constant data |
| Fixups | 4 MiB | pending jumps and references |
| Constants | 16 MiB | decoded string literals, copied after the code |
| Parameters | 1 MiB | type and default of every method parameter |
| Raw files | 16 MiB | files as read, before inclusions are expanded |
| Names | 1 MiB | paths of the included files |

**Symbol record (32 bytes):**

| Field | Bytes | Contents |
|---|---|---|
| `name_off` | 4 | position of the name in the source arena |
| `name_len` | 2 | length of the name |
| `type` | 1 | type (or return type of a method) |
| `flags` | 1 | global, method, created, parameter |
| `level` | 2 | scope depth |
| — | 2 | reserved |
| `nparam` | 4 | methods: number of parameters |
| `address` | 8 | global address, `rbp` offset, or method code position |
| `extra` | 8 | global: line of creation; method: first parameter index |

Names are compared **byte by byte**, never by hash alone, so a collision never
merges two variables. The table is a stack: opening a block marks the top and
closing it drops the block's symbols.

### 12.2 Code generation

- **Stack machine:** every expression ends in `rax`. Binary operators use
  `push`/`pop`. Stage 0 does no register allocation.
- **Locals** in `[rbp - 8n]`, **globals** at fixed absolute addresses in the
  data segment (`mov rax, [disp32]`), known as early as the prescan.
- **Own calling convention** (there is no libc to talk to): arguments are pushed
  left to right, the result comes back in `rax` (and `rdx` for optionals), and
  the caller removes the arguments.
- **Runtime routines** (printing, output buffer, errors, files, …) live in
  `src/runtime.asm`. It is assembled separately and copied whole to the start of
  every executable, at the entry point. Its first instruction is a
  `jmp program`, followed by a table of `jmp routine` at fixed offsets
  (`src/layout.inc`); programs call the routines through that table.
- **Fixups:** control-flow jumps are patched as soon as the target is known.
  The fixup table holds references to constants (strings emitted after the code)
  and calls to methods.
- **Stack frame:** the top level opens a frame (`push rbp; mov rbp, rsp;
  sub rsp, N`). Every local and every loop counter takes a slot `[rbp - 8k]`.
  Closing a block frees its slots for reuse, and N (the largest use, aligned to
  16) is patched at the end.

### 12.3 Generated executable

```text
0x000  ELF64 header                 64 bytes
0x040  PT_LOAD code  (R+X)          56 bytes   offset 0, vaddr 0x400000
0x078  PT_LOAD data  (R+W)          56 bytes   no bytes in the file, vaddr 0x40000000
0x0B0  runtime: jmp program + routine table (entry = 0x4000B0)
       program code
       constant data (strings, aligned to 8)
```

- The code segment is **not** writable.
- The data segment exists only in memory (`p_filesz = 0`); the kernel hands it
  over zeroed. Layout:

  | Offset | Contents |
  |---|---|
  | `+0x0`–`+0x28` | pending output bytes, heap (position and end), input (position, size, end) |
  | `+0x1000` | standard output buffer, 64 KiB |
  | `+0x11000` | standard input buffer, 64 KiB |
  | `+0x21000` | globals, 8 bytes each (16 for optionals) |

- Every STRING or ARRAY global is set to a length-0 constant before the first
  line of the program runs, and is never a null pointer.
- The fixed address `0x40000000` gives absolute addresses known in advance that
  fit in a `disp32`.

---

## 13. Tests

- `make test` runs `tests/run.sh` with stage 0.
  - Every `tests/NAME.nihil` is compiled and run. Its output is compared with
    `NAME.out` (default: empty), its exit code with `NAME.code` (default: `0`),
    its stderr with `NAME.stderr` (if present), and it reads `NAME.in` as input
    (if present). `readelf` must accept the binary, and its mode must be `755`.
  - Every `tests/errors/NAME.nihil` **must fail** to compile, and its stderr must
    contain the text of `NAME.err`.
- `make test1` runs the same suite, plus `tests/stage1/`, with stage 1;
  `make test1-O0` does it without optimizations.
- `make compare`, `make fixedpoint` and `make floatcheck`: §15, §19 and §18.

---

## 14. Milestones

| # | Delivered |
|---|---|
| 1 | Infrastructure: arenas, reading the source, ELF with two segments, `sys_exit(0)`, `chmod 755`, test suite |
| 2 | Full lexer, INT expressions (all operators), globals, `>>` of INT and string literals, `: expr;` at the top level, output buffer |
| 3 | Blocks, locals, the four forms of control flow |
| 4 | Methods, parameters, `:`, passes, recursion |
| 5 | Self-hosting core: ARRAY, indexable STRING, `#`, `[v ; n]`, `>>>`, `<<<`, runtime errors |
| 6 | **Self-hosting**: the compiler rewritten in Nihil (`src1/`), compiled by stage 0, with the same output and a fixed point (§15); then `::`, `!>>`, `@`, `$` and inclusion (§16) |
| 7 | **Optionals**: `_`, `?`, the `\|\|` fallback, `@?` (stage 1) |
| 8 | **FLOAT** (SSE2, exact literals and printing, `.n` and `#f`), `<<` and STRING concatenation (stage 1) |
| 9 | **Optimizations** (§19, stage 1) |

---

## 15. Stage 1 (`nihilc1`)

The compiler written in Nihil lives in `src1/`. `src1/nihilc1.nihil` is just a list of
inclusions (§16). `build/runtime.nihil` is generated from `runtime.bin`, and
`build/prelude_text.nihil` from the prelude (§18).

- **Same output as stage 0.** Without optimizations (`NIHIL_O0=1`), `nihilc1`
  mirrors the algorithm of `nihilc` and produces exactly the same bytes.
  `make compare` checks this for every test program.
- **Fixed point** (`make fixedpoint`, three parts):
  1. without optimizations, `nihilc1` compiles itself into the binary `nihilc` made;
  2. optimized, `nihilc2` (`nihilc1` compiled by itself) = `nihilc3` (`nihilc2` by
     itself);
  3. `nihilc2`, without optimizations, produces exactly `nihilc1` again.
- **Protocol:** `nihilc1` reads the path of the program from stdin (one line,
  optionally prefixed with `-O0 `), reads the files itself with `@`, writes the
  executable to stdout and errors to stderr (with exit code 1). `nihilc1.sh` gives
  it the same command line as `nihilc`.
- `nihilc1` reports compile errors with `!>>` and exits with `:: 1;`.
- The only difference in behavior between the stages is an **included file that
  cannot be opened**: `nihilc` gives a compile error with a position, `nihilc1` the
  runtime error of `@`. Both messages contain `could not read '…'`.

## 16. File inclusion

```text
@ "lexer.nihil";
@ "../common/util.nihil";
```

- `@ "file";` puts the contents of the file in place of the line, before any
  other analysis.
- It is valid only **at the top level, between commands, alone on its line**. A
  `//` comment may follow the `;`.
- The path is **relative to the directory of the including file**, or absolute
  if it starts with `/`.
- **Each file is included once.** A repeated inclusion of the same path is
  ignored, so two files can include the same utility. Paths are compared as
  written: `a/../b.nihil` and `b.nihil` count as different.
- Error messages point to the original file and line, e.g.
  `nihilc: src1/lexer.nihil:12:5: …` and `it is created on line 2 in util.nihil`.
- Implementation: each file is read into the raw-files arena and copied into the
  "expanded source". A table of **segments** (offset in the expanded source →
  file and line) translates positions back.

## 17. Stage policy from M7 on

- **Stage 0** (`nihilc`, assembly) is frozen at M6 and serves only for
  bootstrapping.
- New features go only into **stage 1** (`nihilc1`). The source of `nihilc1` itself
  stays free of them, so stage 0 can still compile it. When that stops being
  true, bootstrapping will start from an already compiled `nihilc1`.
- Guarantees:
  - for programs that do not use the new features, both stages produce the same
    bytes (`make compare`);
  - the fixed point still holds (`make fixedpoint`);
  - stage-1-only tests live in `tests/stage1/` (`make test1`).

## 18. Prelude

Some of the language's routines are written in the language itself, in
`src1/bigint.nihil`, `src1/float_text.nihil` and `src1/prelude.nihil`:
- big integers;
- exact FLOAT ⇄ text conversion;
- reading lines (`<<`).

- `nihilc1` **includes `bigint.nihil` and `float_text.nihil` itself**, to convert FLOAT
  literals at compile time.
- All three go, as text, **to the start of every program that uses FLOAT or
  `<<`**, in a segment named `<prelude>`. Programs that use neither do not get
  the prelude.
- The conversion is checked against Python (`make floatcheck`: 100,000 cases plus
  the edge cases): the text reads back as the same number, is the shortest
  possible, and parsing is exact.
- **Names starting with `__nihil_` are reserved.**
- **A lesson for libraries:** by the rule in §4, an assignment inside a method
  changes a global with the same name. Code meant to be included in someone
  else's program must give its locals names no program uses; the prelude
  prefixes all of them with `__`. Parameters do not have this problem, because
  they can hide globals.

## 19. Optimizations (stage 1)

`nihilc1` optimizes by default. With `-O0` (`NIHIL_O0=1 ./nihilc1.sh`) it produces
exactly the same bytes as stage 0. Every optimization rewrites the stack
machine's code right after emitting it, and only when no jump targets the
rewritten stretch.

| Optimization | Before | After |
|---|---|---|
| Direct operand | `push rax ; <load> ; mov rcx, rax ; pop rax` | `mov rcx, <load>` |
| Increment | `x = x + 1` in 4 instructions | `inc x`; `x = x ± k` becomes `add`/`sub x, k` (k fits in imm32) |
| Compare + branch | `cmp ; setcc ; movzx ; test ; jz` | `cmp ; jcc` (inverted) |
| Simple fallback | `test rdx ; jnz ; <load>` | `test rdx ; mov rcx, <load> ; cmovz rax, rcx` |
| Registers | locals and counters in `[rbp - x]` | non-optional locals and loop counters of methods in `rbx`, `r12` … `r15` |

**How many registers each method saves** is learned: in the first pass a
method uses none and counts how many it would use (up to 5). The next pass saves
exactly those in the prologue and restores them at every `:`. A method that
needs none, like `fib`, gets no extra `push`. The runtime preserves these
registers.

**Verification:**
- the whole suite runs with and without optimizations (`make test1`,
  `make test1-O0`);
- `tests/stage1/optimizations.nihil` exercises the edge cases;
- the fixed point (§15) checks that the optimized compiler behaves exactly like
  the unoptimized one.

**Measured gain** (best of several runs): FLOAT 3×, INT loops 1.4×, the compiler
itself 1.6×, little where the cost is `idiv` or memory access.

**Not done yet:**
- null pointers for STRING? and ARRAY? (it would change the representation of
  every optional);
- dead code removal;
- parameters in registers;
- register allocation across commands (every expression still goes through
  `rax`).

---

## 20. Data models and records (stage 1)

A **data model** describes a record: its fields, their types and how wide each
one is in a file. Records model data in memory, and a file of records is a
**fixed-width table**: one record per line, every line the same length.

```text
PRODUCT = @[code: INT(6); name: STRING(12); price: FLOAT(8); active: BOOL];

p = PRODUCT(7, "Coffee", 12.5, true);   // a record
>> p.name;                              // a field
p.price = 13.75;                        // fields can change
@+>> "products.dat", p;                 // appends its line to a file
rows = PRODUCT @ "products.dat";        // reads the table: ARRAY of PRODUCT
>> rows[0].name;
@>> "products.dat", rows;               // rewrites the whole table, atomically
```

### 20.1 Declaring a model

`NAME = @[field: TYPE(width); …];` at the **top level**, outside any block.
It can be used anywhere in the program, before or after its line. The name
follows the rules of any name; a model cannot receive a value.

| Field type | Width | In the file |
|---|---|---|
| `INT(w)` | 1 … 20 characters (with the sign) | decimal, aligned to the **right** |
| `FLOAT(w)` | 1 … 40 characters | shortest text that reads back the same (§6.1.1), aligned to the right |
| `STRING(w)` | 1 … 65535 **bytes** | the bytes, aligned to the **left** |
| `BOOL` | always 1 (no width) | `T` or `F` |

Spaces fill the rest of each field. A `;` may follow the last field. Field names
are checked at compile time: a misspelled field is a compile error.

### 20.2 Records

- `NAME(a, b, …)` creates a record; the arguments go to the fields in order and
  must have their exact types (no conversions: write `12.0`, not `12`, for a
  FLOAT). Omitted fields start as `0`, `""`, `0.0` and `false`; `NAME()` is an
  empty record.
- `r.field` reads a field and `r.field = value;` changes it, also through an
  index: `rows[i].price = 4.5;`.
- A record is a **reference**, like an ARRAY: `q = p;` makes both names point to
  the same record.
- Records can be elements of an ARRAY (`[p, q]`); `[r ; n]` makes **n independent
  copies** of `r`. They can be parameters (the default is `NAME()`, or `[NAME()]`
  for an ARRAY of records), return values, optionals (`: _;` gives `NAME?`) and
  globals (a global record starts as `NAME()`).
- `>>` does not print a record; `$r` is its line (with the `\n`) and `$rows` the
  whole table. Records cannot be compared with `==`.

### 20.3 Table files

- `NAME @ path` reads the file and returns an `ARRAY of NAME`. Every line must
  have exactly the model's width (the last one may lack its `\n`). Numbers may
  have spaces around them; an empty number is 0, an empty BOOL is `false`; a
  STRING loses the spaces on its right (the ones on the left stay).
- `NAME @? path` is the same, but a file that cannot be read gives an **empty
  table** instead of an error: the usual way to start the first run.
- `@>> path, r;` / `@>> path, rows;` write a record or a table, and `@+>> path,
  r;` appends records (§8.1.1): the text is `$r` or `$rows`.

A value that does not fit (`INT(3)` holding `1234`, a 61-byte text in a
`STRING(50)`, a STRING with a line break) ends the program when it is written,
and a line that does not match the model ends it when it is read, both with exit
code 2:

```text
nihil: field 'name' of PRODUCT does not fit in STRING(12): the text has 15 bytes
nihil: 'products.dat', line 3: field 'code' is not a valid INT: 'abc'
nihil: 'products.dat', line 4: the line has 30 bytes, but a PRODUCT record has 27
```

### 20.4 One record at a time

Because every line has the same width, record *i* starts at byte *i × (width +
1)*, so one record can be read without loading the file:

| Expression | Type | Result |
|---|---|---|
| `NAME @[i] path` | `NAME` | record *i* (counting from 0); an error if the file or the record does not exist |
| `NAME @?[i] path` | `NAME?` | the same, but `_` when the file or the record does not exist |
| `NAME @# path` | `INT` | how many records the file has, from its size; 0 if the file does not exist |

Only the bytes of that line are read (`pread`): record 50 000 costs the same as
record 0. The size must be a whole number of lines (the last one may lack its
`\n`); otherwise the file was cut in the middle of a record, which is an error:

```text
nihil: 'products.dat' has no record 7 (it has 5: 0 to 4)
nihil: 'products.dat', line 6: the file ends in the middle of a PRODUCT record (300 bytes is not a whole number of 55-byte lines)
```

The path after `@`, `@[i]` or `@#` is a unary expression: a computed path goes in
parentheses, `NAME @[i] (dir + "/products.dat")`.

**Changing one record in place:** `@[i]>> path, r;` writes record `r` as line
*i* of the file and leaves every other byte as it is: one `pwrite` of that line,
then `fsync`. The model comes from the type of `r`.

```text
p = PRODUCT @[3] "products.dat";
p.price = 13.75;
@[3]>> "products.dat", p;                        // only line 3 changes
@[PRODUCT @# "products.dat"]>> "products.dat", q; // i = the count adds a line
```

- *i* goes from 0 to the count: *i* equal to the count adds a line at the end, a
  file that does not exist has 0 records, and a larger *i* is an error (a table
  never has holes). If the last line lacks its `\n`, it gets one first.
- The file is checked as by `@#`, so one cut in the middle of a record is an
  error and nothing is written. A value that does not fit stops the program
  before anything is written, too.
- One line is small, so in practice it is written whole; but unlike `@>>`
  (temporary file + `rename`) it is not atomic against a crash in the middle of
  the write. To change many records at once safely, rewrite the table with `@>>`.

```text
nihil: 'products.dat' has no record 7 to write (it has 5: 0 to 4, or 5 to add one)
```

### 20.5 Keys

One field of a model can be its **key**, marked with `#`. It must be INT or
STRING, and no two records of a table may have the same key.

```text
PRODUCT = @[#code: INT(6); name: STRING(24); price: FLOAT(10)];

@{}>> "products.dat", PRODUCT(42, "Coffee", 12.5);   // adds it (a new key)
p = PRODUCT @{42} "products.dat";                    // the record with code 42
p.price = 13.75;
@{}>> "products.dat", p;                             // same key: replaced in place
q? = PRODUCT @?{99} "products.dat";                  // _ : there is none
```

| Form | Result |
|---|---|
| `NAME @{k} path` | the record whose key is `k` (an INT or STRING, the key's type); an error if there is none |
| `NAME @?{k} path` | `NAME?`: the same, but `_` when there is none or the file does not exist |
| `@{}>> path, r;` | writes `r` under its own key: replaces that record in place (one line), or adds `r` at the end |

A STRING key is compared without the spaces on its right, as the table file
keeps it. The table stays an ordinary table file: `NAME @ path`, `@[i]`, `@#`
and the other writes still work on it.

**The index.** Next to the table, `path.nihil-idx` holds a hash table on disk:
16 bytes of header, then one 4-byte slot per position, with the record number
(+ 1) or 0 for an empty slot. Finding a key costs a few small reads (the slot,
then the record, whose key is always checked), whatever the size of the table;
adding one costs a write of the line and of one slot. The index has at least
twice as many slots as records and doubles when it gets half full.

The index is a **cache** of the table: its header keeps the size and the
*stamp* (modification time and inode) the table had when the index was last
right. When they do not match, because the table was written by `@>>`, `@+>>`,
another program or an editor, the next key operation reads the whole table
once and rebuilds the index (atomically, like `@>>`). A missing or damaged
index is rebuilt the same way, so it can always be deleted. `@[i]>>` keeps the
index right when the key of line *i* does not change.

Each key write syncs the table and then the index to disk (`fsync`), so a
crash leaves at worst an index that no longer matches, and that is rebuilt.

```text
nihil: 'products.dat' has no PRODUCT with code = 99
nihil: 'products.dat', line 3: the key code = 1 is also in line 1, and a key is unique
```

### 20.6 Implementation

A record is a block of 8-byte slots with the ARRAY layout (§3); a STRING field
holds the address of its text. Its type is a model number, so each model is a
distinct type. The compiler reads the models before the methods and globals (so
any part of the program can use them) and keeps, for each one, constants with
the field types and widths, the field names and the model's name. The text
conversions are prelude methods (§18) that receive those constants; programs
with models always get the prelude.

## Appendix A — What changed since v1.0, and why

| Change | Reason |
|---|---|
| The counted-loop counter lives on the stack, not in `rcx` | `syscall` destroys `rcx`; a `>>` inside the loop broke the count |
| A count `<= 0` skips the block | `dec rcx; jnz` with 0 would run about 2⁶⁴ times |
| Globals in a fixed data segment, not in `rbx`/`r12`–`r15` | Methods overwrote the registers, and five are not enough |
| Two `PT_LOAD`s (code R+X, data R+W) instead of one RWX | Global addresses known in advance and non-writable code. The entry moved from `0x400078` to `0x4000B0` |
| STRING/ARRAY as a pointer with the length before the data, not a `(ptr, len)` pair | Every value fits in one register, which makes stage 0 much simpler |
| `f() {` at the top level is a declaration | v1.0 was ambiguous with "call `f` and use the result as a condition" |
| Passes | Recursion and forward calls were impossible with the return type locked at the first `:` |
| Locals never hide globals | In v1.0, `b = ...` in a method became a local or a global depending on the order of the text |
| `b? = _;` forbidden | The type would require flow analysis |
| An explicit rule for `\|\|` with an optional BOOL | It was ambiguous |
| Unary minus, bit operators, `#`, `[v ; n]`, `'c'`, `0x` | Needed to write the compiler in the language |
| `>>>` and `<<<` (raw bytes) | Without them the compiler could not read the source or write the ELF |
| `>>` adds no newline | Full control of the output, needed to generate files |
| `: expr;` at the top level sets the exit code | Programs and tests can signal a result |
| Names compared byte by byte | Hash alone let two variables collide silently |
| Runtime routines through `call`, not inline | The binary does not grow with every `>>` |
| The `close` syscall added | It was missing from the list |
| **v1.2:** comparisons below the bit operators in the precedence table | v1.1 said the bit operators were above, but the table and grammar put them below, so `a & 1 == 0` became `a & (1 == 0)` |
| **v1.3:** a parameter may have a global's name | v1.0's own example (`max(a = 0, b = 0)` with a global `b`) would be an error. A parameter is declared explicitly, so there is no ambiguity |
| **v1.3:** `even(4) {` at the top level is a call, not a declaration | The rule "`IDENT(…) {` at the top level is always a declaration" prevented using a method as a condition there |
| **v1.3:** parameter defaults are literals | The default is put into every call that omits it; arbitrary expressions would have to be evaluated in the method's context |
| **v1.3:** a method with a value and no `:` at the end is a runtime error | Returning garbage in `rax` would be silent; detecting it at compile time needs flow analysis |
| **v1.4:** an ARRAY parameter's default is a one-element literal, new on every call | A shared constant array would be changed by one call and seen by the next |
| **v1.4:** `name[…]` is an assignment only if the `]` is followed by `=` | `flags[i] { … }` is a valid conditional |
| **v1.5:** `[0 ; n]` does not fill the memory | A new heap block comes zeroed from the kernel. Without this, the 16 MiB buffers of the compiler would touch hundreds of MB |
| **v1.6:** `::`, `!>>`, `@ path`, `$ bytes`, `@ "file";` | The compiler written in the language needed to exit from inside methods, write errors to stderr, read files and build paths. All of them use symbols that were invalid before, with no keyword |
| **v1.7:** every optional is value + flag (STRING? and ARRAY? too) | A single representation keeps assignment, arguments, returns and fallback simple; null pointers are an optimization |
| **v1.7:** a T return with `: _;` becomes T? | Search methods become natural (`: i;` … `: _;`) with no type annotation |
| **v1.7:** `@?` | Reading a file that may fail without ending the program |
| **v1.8:** FLOAT as bits in `rax` | The stack machine keeps the same registers; SSE2 is used only for the arithmetic |
| **v1.8:** `.n` and `#f` as conversions | No keyword and no implicit conversion |
| **v1.8:** a prelude written in the language | Converting `double` ⇄ text exactly needs big integers; writing them in the language (not in assembly) makes them testable and reusable by the compiler |
| **v1.8:** with a provisional side, `+ - * /` give a provisional result (not INT) | With FLOAT and STRING `+`, assuming INT locked wrong return types in the first pass |
| **v1.9:** optimizations by rewriting the code already emitted, with `-O0` for the bytes of stage 0 | Keeps the generator simple (a stack machine) and keeps the equivalence with stage 0 |
| **v1.9:** saved registers learned between passes | The prologue comes before the body; using the count from the previous pass avoids saving registers for nothing |
| **v2.1:** `... ms;` waits | Animations need a fixed speed; a busy loop depends on the machine. The ellipsis reads as a pause and cannot start any valid expression |
| **v2.2:** renamed from Ket to Nihil | Latin for *nothing*: no keywords, and `_` for the missing value |
| **v2.7:** key fields `#name`, `NAME @{k} path`, `@{}>> path, r;` | A key-value store: finding a record by its key without reading the table. The index lives in its own file as a cache that is rebuilt when it does not match the table, so the table stays a plain text file that any write or editor may change. `#` reads as "number"; `{}` after `@` was never valid |
| **v2.6:** `@[i]>> path, r;` | A key-value store needs to change one record without rewriting the table. With fixed widths the line's position is known, so one `pwrite` replaces it. `@[i]` already meant "record i" and `>>` "write"; a command never started with `@[` before |
| **v2.5:** `NAME @[i] path`, `NAME @?[i] path`, `NAME @# path` | Reading one record should not cost reading the whole table: with fixed widths its position is known, and `pread` reads only that line. The count comes from the file's size, which also detects a file cut in the middle of a record |
| **v2.4:** data models `NAME = @[field: TYPE(width); …];`, records, `r.field`, `NAME @ path` | Programs needed structured data that matches a file layout. Fixed widths make a file a table where record *n* has a known position, which a key-value store will need; names without quotes let the compiler check every field. `@[` keeps the "file" meaning of `@`; `.` after a value was never valid before |
| **v2.3:** `@>> path, text;` and `@+>> path, text;` write files | Programs could read files but not save anything. The first step towards storing data: atomic replace (temporary + `fsync` + `rename`) so a crash never leaves half a file, and a durable append for logs. `@` already meant "file" and `>>` "write"; neither combination was valid before |
| **v2.0:** renamed from Cru to Ket, and the whole project moved to English | Ket came from Dirac's ket notation: a state written with symbols only, like a language without keywords |
| FLOAT and optionals after self-hosting | The compiler needs neither, and converting a `double` to text is a project of its own |
| Optimizations postponed | Correctness first; optimize in stage 1 |
