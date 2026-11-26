# make's own default CC (cc) would beat a ?=; the image has clang only
ifeq ($(origin CC),default)
CC      := clang
endif
CLANG   ?= clang
BPFTOOL ?= bpftool
STRIP   ?= llvm-strip
CFLAGS  ?= -O2 -g -Wall -Wextra
ARCH    := $(shell uname -m | sed -e 's/x86_64/x86/' -e 's/aarch64/arm64/')

all: x3cap

out/x3_kern.bpf.o: bpf/x3_kern.c inc/x3_abi.h
	@mkdir -p out
	$(CLANG) -target bpf -g -O2 -D__TARGET_ARCH_$(ARCH) -Wall -Wextra -Iinc -c $< -o $@
	$(STRIP) --strip-debug $@

out/x3_kern.skel.h: out/x3_kern.bpf.o
	$(BPFTOOL) gen skeleton $< name x3_kern_bpf > $@

x3cap: src/x3cap.c inc/x3_abi.h out/x3_kern.skel.h
	$(CC) $(CFLAGS) -Iinc -Iout -o $@ $< -lbpf

clean:
	rm -rf out x3cap

.PHONY: all clean
