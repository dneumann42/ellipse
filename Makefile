NIM := nim
GLSLANG := glslangValidator
SHADERCROSS := shadercross

# Install prefix (~/local/bin is on PATH here; override for system-wide:
#   sudo make install PREFIX=/usr/local). DESTDIR stages into a root dir.
PREFIX ?= $(HOME)/.local
DESTDIR ?=

.PHONY: build_owl run_owl test_owl test_repl install owl_clean build_ellipse run_ellipse build_3d run_3d shaders shaders_portable ellipse_clean build_gallery run_gallery run_gallery_tui test_gui test_hot test_atlas run_display run_attached

OWL_FLAGS := --outdir:bin/ --nimcache:build/nimcache -p:src -p:src/clay

# owl embeds its libraries and links the ellipse_ui kit behind the gui module.
OWL_SOURCES := $(wildcard src/owl/*.nim src/owl/*/*.nim src/owl/*/*.owl src/owl/*/*.c \
	src/ellipse/*.nim src/ellipse/*/*.nim src/ellipse/*/*.c src/ellipse_ui/*.nim \
	src/ellipse_ui/*/*.nim src/ellipse_ui/*/*/*.nim src/clay/*.nim src/clay/*/*.nim)

ELLIPSE_FLAGS := --outdir:bin/ --nimcache:build/nimcache -p:src

ELLIPSE_SOURCES := $(wildcard src/ellipse/*.nim src/ellipse/*/*.nim src/ellipse/*/*/*.nim)

# The GUI kit (clay + ellipse_ui + its platform/terminal layer), ported from
# the nimony `ellipse-preview` checkout. Its platform layer links SDL3,
# SDL3_ttf and (on Linux) wayland directly, so it builds with plain `nim`;
# -p:src/clay matches the source tree's own Makefile.
GUI_FLAGS := --outdir:bin/ --nimcache:build/nimcache-gui -p:src -p:src/clay

GUI_SOURCES := $(wildcard src/ellipse_ui.nim src/clay/*.nim src/ellipse_ui/*.nim \
	src/ellipse_ui/*/*.nim src/ellipse_ui/*/*/*.nim \
	src/ellipse/logger.nim src/ellipse/failure.nim src/ellipse/clock.nim \
	src/ellipse/hotload.nim src/ellipse/platform/*.nim src/ellipse/terminal/*.nim)

# `hot_reload_test` is excluded: it is a headless project skeleton that only
# makes sense inside its bash wrapper (scratch src/, a real rebuild, an
# execv over the same pid) -- `make test_hot` runs that.
GUI_TESTS := $(filter-out hot_reload_test.nim,$(notdir $(wildcard tests/gui/*_test.nim)))

SHADER_SOURCES := $(wildcard src/ellipse/drawing/shaders/*.glsl)
SHADER_SPVS := $(patsubst src/ellipse/drawing/shaders/%.glsl,src/ellipse/drawing/shaders/spv/%.spv,$(SHADER_SOURCES))
SHADER_PORTABLE := $(SHADER_SPVS:.spv=.msl)

src/ellipse/drawing/shaders/spv/%.vert.spv: src/ellipse/drawing/shaders/%.vert.glsl
	@mkdir -p $(dir $@)
	$(GLSLANG) -V --quiet -S vert -o $@ $<

src/ellipse/drawing/shaders/spv/%.frag.spv: src/ellipse/drawing/shaders/%.frag.glsl
	@mkdir -p $(dir $@)
	$(GLSLANG) -V --quiet -S frag -o $@ $<

src/ellipse/drawing/shaders/spv/%.comp.spv: src/ellipse/drawing/shaders/%.comp.glsl
	@mkdir -p $(dir $@)
	$(GLSLANG) -V --quiet -S comp -o $@ $<

src/ellipse/drawing/shaders/spv/%.msl: src/ellipse/drawing/shaders/spv/%.spv
	$(SHADERCROSS) $< -o $@

shaders: $(SHADER_SPVS)

shaders_portable: $(SHADER_PORTABLE)

bin/ellipse: $(ELLIPSE_SOURCES) $(SHADER_SPVS)
	@mkdir -p bin
	$(NIM) $(ELLIPSE_FLAGS) c src/ellipse.nim

build_ellipse: bin/ellipse

bin/hello3d: examples/hello3d.nim $(ELLIPSE_SOURCES) $(SHADER_SPVS)
	@mkdir -p bin
	$(NIM) $(ELLIPSE_FLAGS) c examples/hello3d.nim

build_3d: bin/hello3d

run_3d: bin/hello3d
	./bin/hello3d $(ARGS)

run_ellipse: bin/ellipse
	./bin/ellipse $(ARGS)

# --- development mode: the window lives in a display server, the game in its
# own process. A game run with --display-attach raises the server from its own
# image when none answers (see `platform/display.ensureDisplayServer`), so one
# terminal is enough; `run_display` starts it separately if you prefer. Kill
# and relaunch the game all you like: the window stays, input keeps flowing,
# and frames mirror straight back.

run_display: bin/ellipse
	./bin/ellipse --display-serve

run_attached: bin/ellipse
	ELLIPSE_DISPLAY_ATTACH=1 ./bin/ellipse $(ARGS)

# --- GUI kit (clay + ellipse_ui, ported from the nimony ellipse-preview) ----

bin/gallery: examples/gallery.nim examples/gallery/memberform.nim $(GUI_SOURCES)
	@mkdir -p bin
	$(NIM) $(GUI_FLAGS) c examples/gallery.nim

build_gallery: bin/gallery

run_gallery: bin/gallery
	./bin/gallery $(ARGS)

run_gallery_tui: bin/gallery
	./bin/gallery --tui

test_gui:
	@mkdir -p bin/tests
	@for t in $(GUI_TESTS); do \
	  echo ";; $$t"; \
	  SDL_VIDEODRIVER=offscreen $(NIM) -r --outdir:bin/tests/ \
	    --nimcache:build/nimcache-gui -p:src -p:src/clay c tests/gui/$$t || exit 1; \
	done

test_hot:
	@bash tests/gui/hot_reload_test.sh

# Aseprite reading and atlas packing (owl metadata beside each atlas image).
test_atlas:
	@mkdir -p build
	$(NIM) $(ELLIPSE_FLAGS) -r c tests/atlas_test.nim

gui_clean:
	rm -rf bin/tests build/nimcache-gui

ellipse_clean:
	rm -rf src/ellipse/drawing/shaders/spv

bin/owl: $(OWL_SOURCES)
	@mkdir -p bin
	$(NIM) $(OWL_FLAGS) c src/owl/owl.nim

build_owl: bin/owl

run_owl: bin/owl
	./bin/owl $(ARGS)

# Build owl and install the binary into $(PREFIX)/bin. Its libraries and
# scripts are embedded at compile time (embedFile), so the binary is all
# that is needed.
install: build_owl
	install -Dm755 bin/owl $(DESTDIR)$(PREFIX)/bin/owl

test_owl:
	@mkdir -p build
	$(NIM) $(OWL_FLAGS) -r c tests/objects_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/reader_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/evaluator_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/modules_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/errors_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/serde_test.nim
	$(NIM) $(OWL_FLAGS) -r c tests/settings_test.nim

# The repl app. Its window face runs headless (offscreen SDL, scripted
# frames); its terminal face runs `owl repl` on a pseudo-terminal, keys as
# the kitty keyboard protocol sends them.
test_repl: bin/owl
	@mkdir -p build
	SDL_VIDEODRIVER=offscreen $(NIM) $(OWL_FLAGS) -r c tests/repl_gui_test.nim
	python3 -I ./tests/repl_commands_test.py
	python3 -I ./tests/repl_screens_test.py

owl_clean:
	rm -rf bin build
