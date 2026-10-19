# Each game is a ZGAL program (<game>/<game>.zgal, importing the PPU in nes/nes.zgal), built with the
# wrapper's rules (zgal.mk) into build/<game>/<game>, with its memory dumps (<game>/assets) beside it.
#   make                     - build every game
#   make test                - capture each game's frames and compare them with tests/approved
#   make approve-screenshots - accept the frames captured by the last run
#   make web                 - build every game for the web into build/web/<game>: serve it and open
#                              <game>.zgal.html, or run it headless under Node
#   make test-web            - capture each game's frames on the web, under Node, and compare them
#                              with tests/approved

# Compiler
CC = /usr/bin/g++
CXX = $(CC)

# The Vulkan wrapper and ZGAL (git submodule); ZGAL_ROOT=<path> builds with another checkout
ZGAL_ROOT ?= external/vulkan_test

CFLAGS = -std=c++20 -I/usr/local/include -I/Users/zyoussef/VulkanSDK/1.4.321.0/macOS/include/
CXXFLAGS = $(CFLAGS)
LDFLAGS = -L/opt/homebrew/lib -L/usr/local/lib
LDLIBS = -lvulkan

OUT = build

include $(ZGAL_ROOT)/zgal.mk

GAMES = smb3 batman

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
	$(CC) -o $@ $< $(CFLAGS) $(ZGAL_CFLAGS)

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

.PHONY: all clean test approve-screenshots web test-web

clean:
	rm -rf $(OUT)
