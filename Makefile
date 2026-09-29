.PHONY: clean setup run run_owl test

build/nimony/bin/nimony:
	./scripts/setup.sh

bin/ellipse: setup
	./build/nimony/bin/nimony --outdir:bin/ c ./src/ellipse.nim

build: bin/ellipse
	@echo "Finish building ellipse"

run: build 
	./bin/ellipse

run_owl: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./src/owl/owl.nim

test: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/objects_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/reader_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/evaluator_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/modules_test.nim

setup: build/nimony/bin/nimony
	@echo "Nimony is ready"

clean:
	rm -rf build/*
	rm -rf bin/*

