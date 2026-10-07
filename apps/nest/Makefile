# Nest -- built against the ellipse checkout below.

ELLIPSE ?= /mnt/@home/dneumann/ellipse
NIMONY  ?= $(ELLIPSE)/build/nimony/bin/nimony

.PHONY: build run clean

build: bin/nest

bin/nest: $(wildcard src/*.nim src/*/*.nim)
	$(NIMONY) --outdir:bin/ c ./src/nest.nim

run: bin/nest
	./bin/nest

clean:
	rm -rf bin nimcache
