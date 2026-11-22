# Nihil — stage 0 (assembly) and stage 1 (Nihil)
NASM := $(shell command -v nasm 2>/dev/null || echo $(HOME)/.local/bin/nasm)
NASMFLAGS := -w+all -w-reloc-rel-dword -w-reloc-abs-qword -I src/ -I build/
SOURCES1 := $(sort $(wildcard src1/*.nihil))
comma := ,

all: build/nihilc build/nihilc1

# ---- stage 0 ----
build/nihilc: build/nihilc.o
	ld -o $@ $<

build/nihilc.o: src/nihilc.asm src/commands.inc src/layout.inc build/runtime.bin
	$(NASM) -f elf64 -g -F dwarf $(NASMFLAGS) -o $@ src/nihilc.asm

build/runtime.bin: src/runtime.asm src/layout.inc
	@mkdir -p build
	$(NASM) -f bin $(NASMFLAGS) -o $@ src/runtime.asm

# ---- stage 1: the compiler written in Nihil, compiled by stage 0 ----
build/runtime.nihil: build/runtime.bin
	{ printf '// generated from build/runtime.bin — do not edit\nruntime_bin = ['; \
	  od -An -v -tu1 $< | xargs | sed 's/ /, /g'; printf '];\n'; } > $@

# the prelude (bigint + float_text + prelude) becomes a STRING inside nihilc1
PRELUDE := src1/bigint.nihil src1/float_text.nihil src1/prelude.nihil
build/prelude_text.nihil: $(PRELUDE)
	@mkdir -p build
	{ printf '// generated from $(PRELUDE) — do not edit\nPRELUDE_TEXT = "'; \
	  cat $(PRELUDE) | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{ printf "%s\\n", $$0 }'; \
	  printf '";\n'; } > $@

# the standard library (std/*.nihil, SPEC §16): each file becomes a STRING inside nihilc1,
# included by programs as @ "std:name.nihil";
STD := $(sort $(wildcard std/*.nihil))
build/std_text.nihil: $(STD)
	@mkdir -p build
	{ printf '// generated from std/*.nihil — do not edit\nSTD_LIST = "%s";\nstd_text(name = "") {\n' "$(subst $(eval) ,$(comma) ,$(notdir $(STD)))"; \
	  for f in $(STD); do \
	    printf '    name == "%s" { : "' "$$(basename $$f)"; \
	    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' $$f | awk '{ printf "%s\\n", $$0 }'; \
	    printf '"; }\n'; \
	  done; \
	  printf '    : "";\n}\n'; } > $@

build/nihilc1: build/nihilc build/runtime.nihil build/prelude_text.nihil build/std_text.nihil $(SOURCES1)
	build/nihilc src1/nihilc1.nihil $@

# ---- tests ----
test: build/nihilc
	@./tests/run.sh

test1: build/nihilc1
	@NIHILC=./nihilc1.sh DIRS="tests tests/stage1" ./tests/run.sh

# the whole suite through nihilc1 without optimizations
test1-O0: build/nihilc1
	@NIHIL_O0=1 NIHILC=./nihilc1.sh DIRS="tests tests/stage1" ./tests/run.sh

# every test program compiled by both stages must give identical bytes
compare: build/nihilc build/nihilc1
	@./tests/compare.sh

# fixed point:
#  1. without optimizations, nihilc1 compiles itself into the binary nihilc produced
#  2. optimized: nihilc2 (nihilc1 by itself) = nihilc3 (nihilc2 by itself)
#  3. nihilc2 (optimized) without optimizations produces exactly nihilc1 again
fixedpoint: build/nihilc1
	NIHIL_O0=1 ./nihilc1.sh src1/nihilc1.nihil build/nihilc1-O0
	cmp build/nihilc1 build/nihilc1-O0
	./nihilc1.sh src1/nihilc1.nihil build/nihilc2
	NIHILC1=build/nihilc2 ./nihilc1.sh src1/nihilc1.nihil build/nihilc3
	cmp build/nihilc2 build/nihilc3
	NIHIL_O0=1 NIHILC1=build/nihilc2 ./nihilc1.sh src1/nihilc1.nihil build/nihilc1-O0b
	cmp build/nihilc1 build/nihilc1-O0b
	@echo "fixed point: nihilc1 = nihilc1 -O0 ($$(stat -c %s build/nihilc1) bytes); nihilc2 = nihilc3 ($$(stat -c %s build/nihilc2) bytes, optimized)"

# FLOAT ⇄ text against Python: every number reads back the same, is the shortest, and parsing is exact
floatcheck: build/nihilc
	build/nihilc tests/float/conversion_check.nihil build/conversion_check
	python3 tests/float/check.py build/conversion_check 100000

# the collector under pressure: a copy whose runtime collects every 256 KiB,
# whatever is in use, runs the stage 1 suite, the fixed point and floatcheck
gcstress:
	rm -rf build/stress && mkdir -p build/stress
	cp -r src src1 std tests Makefile nihilc1.sh build/stress/
	$(MAKE) -C build/stress NASMFLAGS="$(NASMFLAGS) -DGC_STRESS" test1 fixedpoint floatcheck

# the IDE server, written in Nihil (SPEC §24): ./build/ide-server, then http://127.0.0.1:8730
ide: build/ide-server

build/ide-server: build/nihilc1 ide/server.nihil
	./nihilc1.sh ide/server.nihil $@.new && mv $@.new $@     # the running server keeps its copy

clean:
	rm -rf build

.PHONY: all test test1 test1-O0 compare fixedpoint floatcheck gcstress ide clean
