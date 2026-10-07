.PHONY: clean setup cli run run_gallery run_gallery_tui run_tome build_owl run_owl run_duck run_bar test run_owl_gallery gallery_parity bench

build/nimony/bin/nimony:
	./scripts/setup.sh

bin/gallery: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./apps/gallery.nim

bin/ellipse: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/ellipse.nim

cli: bin/ellipse

bin/tome: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/tome.nim

build: bin/gallery
	@echo "Finish building ellipse"

run: run_gallery

run_gallery: bin/gallery
	./bin/gallery

run_gallery_tui: bin/gallery
	./bin/gallery --tui

run_tome: bin/tome
	./bin/tome

ifneq (,$(filter run_owl run_duck,$(firstword $(MAKECMDGOALS))))
APPS_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
%::
	@:
endif

bin/owl: setup $(wildcard src/owl/*.nim src/owl/*/*.nim src/owl/*/*.owl src/owl/*/*.c)
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./src/owl/owl.nim

build_owl: bin/owl

run_owl: bin/owl
	./bin/owl $(ARGS) $(APPS_ARGS)

run_owl_gallery: bin/owl
	cd apps/owl-gallery && ../../bin/owl run

gallery_parity: bin/owl
	./tests/gallery_cmp/run.sh

# Interpreter benchmarks against tests/bench/baseline.json (see tests/bench/run.py).
bench: bin/owl
	python3 -I ./tests/bench/run.py

bin/duck: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./apps/duck.nim

run_duck: bin/duck
	./bin/duck $(ARGS) $(APPS_ARGS)

test: setup bin/owl
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/objects_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/reader_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/evaluator_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/modules_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/source_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/live_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/tui_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/clay_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/clay_dsl_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/grid_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/terminal_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/tui_widgets_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/widget_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/widgets_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/theme_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/keyboard_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/keys_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/duck_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/pacing_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/pacing_loop_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/damage_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/debug_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/fields_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/dialogs_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/dialog_header_test.nim
	SDL_VIDEODRIVER=offscreen ./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/fdwatch_test.nim
	SDL_VIDEODRIVER=offscreen ./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/gui_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/attach_test.nim
	python3 -I ./tests/repl_screens_test.py
	$(MAKE) bin/gallery
	python3 -I ./tests/tui_backend_test.py

bin/bar: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./apps/bar.nim

run_bar: bin/bar
	./bin/bar

setup: build/nimony/bin/nimony
	@echo "Nimony is ready"

clean:
	rm -rf build/*
	rm -rf bin/*
