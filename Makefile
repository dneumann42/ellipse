.PHONY: clean setup run run_owl test

build/nimony/bin/nimony:
	./scripts/setup.sh

bin/ellipse: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/ellipse.nim

build: bin/ellipse
	@echo "Finish building ellipse"

run: build 
	./bin/ellipse

ifeq ($(firstword $(MAKECMDGOALS)),run_owl)
OWL_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
%::
	@:
endif

run_owl: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/owl/owl.nim
	./bin/owl $(ARGS) $(OWL_ARGS)

test: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/objects_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/reader_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/evaluator_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/modules_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/clay_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/clay_dsl_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/widget_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/widgets_test.nim

setup: build/nimony/bin/nimony
	@echo "Nimony is ready"

clean:
	rm -rf build/*
	rm -rf bin/*
