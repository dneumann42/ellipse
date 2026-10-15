NIM := nim

.PHONY: build_owl run_owl test_owl owl_clean

OWL_FLAGS := --outdir:bin/ --nimcache:build/nimcache -p:src

OWL_SOURCES := $(wildcard src/owl/*.nim src/owl/*/*.nim src/owl/*/*.owl src/owl/*/*.c)

bin/owl: $(OWL_SOURCES)
	@mkdir -p bin
	$(NIM) $(OWL_FLAGS) c src/owl/owl.nim

build_owl: bin/owl

run_owl: bin/owl
	./bin/owl $(ARGS)

test_owl:
	@mkdir -p build
	$(NIM) $(OWL_FLAGS) -r c tests/objects_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/reader_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/evaluator_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/modules_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/errors_test.nim

owl_clean:
	rm -rf bin build
