# Each game is a ZGAL program (<game>/<game>.zgal, importing its system's PPU, e.g. nes/nes.zgal),
# built with the wrapper's rules (zgal.mk) into build/<game>/<game>, with its memory dumps
# (<game>/assets) beside it.
#   make                     - build every game
#   make test                - capture each game's frames and compare them with tests/approved
#   make approve-screenshots - accept the frames captured by the last run
#   make web                 - build every game for the web into build/web/<game>: serve it and open
#                              <game>.zgal.html, or run it headless under Node
#   make test-web            - capture each game's frames on the web, under Node, and compare them
#                              with tests/approved
#   make test-tools          - test the dump tools (tools/dump, Racket; separate from make test)

# Compiler: clang, the one the wrapper is tested with (Apple's c++ on macOS, clang++ on Linux),
# unless CXX is given in the environment or on the command line (make CXX=g++). make's built-in
# default, or none under make -R, counts as not given.
ifneq ($(filter default undefined,$(origin CXX)),)
CXX = $(if $(filter Darwin,$(ZGAL_OS)),c++,clang++)
endif

# The Vulkan wrapper and ZGAL (git submodule); ZGAL_ROOT=<path> builds with another checkout
ZGAL_ROOT ?= external/vulkan_test

# The platform's include and library paths (the Vulkan SDK's, GLFW's, GLM's) come from zgal.mk's
# ZGAL_CFLAGS and ZGAL_LDFLAGS
CFLAGS = -std=c++20
CXXFLAGS = $(CFLAGS)
LDFLAGS =
LDLIBS = -lvulkan

OUT = build

include $(ZGAL_ROOT)/zgal.mk

# The games: each system lists its own in <system>/games.mk (GAMES += ...)
GAMES :=
include $(sort $(wildcard */games.mk))

$(foreach game,$(GAMES),$(eval $(call zgal-program,$(game)/$(game).zgal,$(OUT)/$(game),$(game),-lglfw)))

all: $(foreach game,$(GAMES),$(OUT)/$(game)/$(game))

# For the web (WebGPU): the same games, compiled to TypeScript and WGSL and built to JavaScript
$(foreach game,$(GAMES),$(eval $(call zgal-web-program,$(game)/$(game).zgal,$(OUT)/web/$(game))))

web: $(foreach game,$(GAMES),$(OUT)/web/$(game))

.DEFAULT_GOAL := all

# ---------------------------------------------------------------------------
# Screenshot tests: each game's frames (CAPTURE_FRAMES, one game frame per frame), headless with
# validation, compared with tests/approved/<game>/<frame>.png
# ---------------------------------------------------------------------------
CAPTURE_FRAMES = 1,2,3,4,8,16,60,120
RECEIVED = $(OUT)/screenshots

$(OUT)/compare_screenshots: tests/compare_screenshots.cpp
	@mkdir -p $(dir $@)
	$(CXX) -o $@ $< $(CFLAGS) $(ZGAL_CFLAGS)

test: all $(OUT)/compare_screenshots
	tests/run_screenshot_tests.sh $(OUT)/compare_screenshots $(RECEIVED) $(CAPTURE_FRAMES) native $(GAMES)

# The web builds' frames, under Node with Dawn, against the same approved screenshots
test-web: web $(OUT)/compare_screenshots
	tests/run_screenshot_tests.sh $(OUT)/compare_screenshots $(OUT)/screenshots-web $(CAPTURE_FRAMES) web $(GAMES)

approve-screenshots:
	@for game in $(GAMES); do \
		mkdir -p tests/approved/$$game; \
		for image in $(RECEIVED)/$$game/*.png; do \
			case $$image in *.diff.png) continue;; esac; \
			cp $$image tests/approved/$$game/ && echo "Approved $$game/$$(basename $$image)"; \
		done; \
	done

# The dump tools' tests, which need only Racket (see tools/dump/genesis.md)
test-tools:
	raco test tools/dump

.PHONY: all clean test approve-screenshots web test-web test-tools

clean:
	rm -rf $(OUT)
