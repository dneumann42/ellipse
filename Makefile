.PHONY: clean setup cli run run_gallery run_gallery_tui run_tome build_owl build_owl_sdl FORCE run_owl run_duck run_bar test run_owl_gallery gallery_parity bench

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

# owl is terminal only by default: built with -d:ellipseNoSdl it links no SDL3
# (nor SDL3_ttf or wayland), and every app and the repl run in the terminal.
# build_owl_sdl builds it with the window backend: gui apps open windows and
# `owl repl` opens the repl in one (`owl repl --tui` keeps it in the terminal).
# The two builds keep separate nimcaches; build/owl-variant records which one
# bin/owl is, so switching rebuilds it.
OWL_SDL ?= 0
ifeq ($(OWL_SDL),1)
OWL_FLAGS :=
OWL_NIMCACHE := nimcache
else
OWL_FLAGS := -d:ellipseNoSdl
OWL_NIMCACHE := nimcache-tui
endif

OWL_SOURCES := $(wildcard src/owl/*.nim src/owl/*/*.nim src/owl/*/*.owl src/owl/*/*.c \
	src/ellipse/*.nim src/ellipse/*/*.nim src/ellipse/*/*.c src/ellipse_ui/*.nim \
	src/ellipse_ui/*/*.nim src/clay/*.nim)

build/owl-variant: FORCE
	@mkdir -p build
	@echo "sdl=$(OWL_SDL)" | cmp -s - $@ || echo "sdl=$(OWL_SDL)" > $@

# rm first: nimony skips the link when bin/owl looks newer than its objects,
# which after a variant switch is the other variant's binary.
bin/owl: build/owl-variant $(OWL_SOURCES) | setup
	rm -f bin/owl
	./build/nimony/bin/nimony --outdir:bin/ $(OWL_FLAGS) --nimcache:$(OWL_NIMCACHE) -p:src c ./src/owl/owl.nim

build_owl: bin/owl

build_owl_sdl:
	$(MAKE) bin/owl OWL_SDL=1

FORCE:

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
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/errors_test.nim
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
	SDL_VIDEODRIVER=offscreen ./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/repl_gui_test.nim
	./build/nimony/bin/nimony --outdir:bin/ -p:src -r c ./tests/attach_test.nim
	python3 -I ./tests/repl_screens_test.py
	python3 -I ./tests/repl_commands_test.py
	$(MAKE) bin/gallery
	$(MAKE) bin/ellipse
	python3 -I ./tests/hotload_test.py
	python3 -I ./tests/tui_backend_test.py

bin/bar: setup
	./build/nimony/bin/nimony --outdir:bin/ -p:src c ./apps/bar.nim

run_bar: bin/bar
	./bin/bar

setup: build/nimony/bin/nimony
	@echo "Nimony is ready"

clean:
	rm -rf bin/*
	rm -rf nimcache nimcache-tui nimcache-win
	rm -rf apps/nest/nimcache
