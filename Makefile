.PHONY: clean setup run

build/nimony/bin/nimony:
	./scripts/setup.sh

bin/ellipse: setup
	./build/nimony/bin/nimony --outdir:bin/ c ./src/ellipse.nim

build: bin/ellipse
	@echo "Finish building ellipse"

run: build 
	./bin/ellipse

setup: build/nimony/bin/nimony
	@echo "Nimony is ready"

clean:
	rm -rf build/*
	rm -rf bin/*

