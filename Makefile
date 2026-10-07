# hdeh 3D - software 3D engine in Free Pascal
#
#   make            build engine units, examples and tests
#   make run        build and run the terminal demo
#   make test       build and run the unit tests
#   make clean      remove build products
#
# Requires: Free Pascal >= 3.2 (make sure "fpc" is in PATH).
#           The SDL demo additionally needs libSDL2 (runtime + headers on
#           most distributions it is enough to have libSDL2-2.0.so.0).

FPC      ?= fpc
SRC       = src
BACKENDS  = src/backends
EXAMPLES  = examples
TESTS     = tests
BIN       = bin
UNITS     = build/units

COMMON    = -Mobjfpc -Sh -O2 -gl -vw -Fu$(SRC) -Fu$(BACKENDS) -FU$(UNITS) -FE$(BIN)
UNITONLY  = $(COMMON) -Fu$(BACKENDS)

CORE_UNITS = \
	$(SRC)/hdeh_math.pas \
	$(SRC)/hdeh_image.pas \
	$(SRC)/hdeh_mesh.pas \
	$(SRC)/hdeh_scene.pas \
	$(SRC)/hdeh_raster.pas \
	$(SRC)/hdeh_shadow.pas \
	$(SRC)/hdeh_display.pas \
	$(SRC)/hdeh_engine.pas \
	$(BACKENDS)/hdeh_console.pas \
	$(BACKENDS)/hdeh_sdl2.pas \
	$(SRC)/hdeh.pas

DEMOS = $(BIN)/demo_terminal $(BIN)/demo_sdl
TESTS_BIN = $(BIN)/hdeh_tests

.PHONY: all dirs core examples tests run run-sdl test clean units

all: core examples tests

dirs:
	@mkdir -p $(BIN) $(UNITS)

# --- compile every unit on its own: catches errors even if nothing uses it --
units: dirs
	@fail=0; for u in $(CORE_UNITS); do \
		if [ -f "$$u" ]; then \
			echo "== fpc $$u"; \
			$(FPC) $(UNITONLY) $$u || fail=1; \
		fi; \
	done; exit $$fail

core: units

examples: dirs
	$(FPC) $(COMMON) $(EXAMPLES)/demo_terminal.lpr -o$(BIN)/demo_terminal
	$(FPC) $(COMMON) $(EXAMPLES)/demo_sdl.lpr -o$(BIN)/demo_sdl

tests: dirs
	$(FPC) $(COMMON) $(TESTS)/hdeh_tests.lpr -o$(TESTS_BIN)

run: $(BIN)/demo_terminal
	$(BIN)/demo_terminal $(ARGS)

run-sdl: $(BIN)/demo_sdl
	$(BIN)/demo_sdl $(ARGS)

test: $(TESTS_BIN)
	$(TESTS_BIN)

clean:
	rm -rf $(BIN) build
