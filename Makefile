.PHONY: clean setup run run_tome run_owl run_duck test

build/nimony/bin/nimony:
	./scripts/setup.sh

bin/ellipse: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/ellipse.nim

bin/tome: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/tome.nim

build: bin/ellipse
	@echo "Finish building ellipse"

run: build 
	./bin/ellipse

run_tome: bin/tome
	./bin/tome

ifneq (,$(filter run_owl run_duck,$(firstword $(MAKECMDGOALS))))
APPS_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
%::
	@:
endif

run_owl: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/owl/owl.nim
	./bin/owl $(ARGS) $(APPS_ARGS)

bin/duck: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./apps/duck.nim

run_duck: bin/duck
	./bin/duck $(ARGS) $(APPS_ARGS)

test: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/objects_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/reader_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/evaluator_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/modules_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/clay_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/clay_dsl_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/widget_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/widgets_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/theme_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/keyboard_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/duck_test.nim

setup: build/nimony/bin/nimony
	@echo "Nimony is ready"

clean:
	rm -rf build/*
	rm -rf bin/*
