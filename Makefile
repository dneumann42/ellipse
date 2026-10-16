NIM := nim
GLSLANG := glslangValidator
SHADERCROSS := shadercross

.PHONY: build_owl run_owl test_owl owl_clean build_ellipse run_ellipse build_3d run_3d shaders shaders_portable ellipse_clean

OWL_FLAGS := --outdir:bin/ --nimcache:build/nimcache -p:src

OWL_SOURCES := $(wildcard src/owl/*.nim src/owl/*/*.nim src/owl/*/*.owl src/owl/*/*.c)

ELLIPSE_FLAGS := --outdir:bin/ --nimcache:build/nimcache -p:src

ELLIPSE_SOURCES := $(wildcard src/ellipse/*.nim src/ellipse/*/*.nim src/ellipse/*/*/*.nim)

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

ellipse_clean:
	rm -rf src/ellipse/drawing/shaders/spv

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
