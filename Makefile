# Compiler
CC = /usr/bin/g++
CXX = $(CC)

# Vulkan wrapper (git submodule)
VK_WRAP = external/vulkan_test

OUT = build
SRC = src
SHADER_OUT = $(OUT)/shaders

# Include paths
CFLAGS = -std=c++20 -Wc++11-extensions -I./include -I/usr/local/include -Wc++14-extensions -DENABLE_PRECOMPILED_HEADERS=OFF -I$(VK_WRAP)/include -I$(VK_WRAP)/third_party/stb -I/Users/zyoussef/VulkanSDK/1.4.321.0/macOS/include/
# Where the memory dumps and compiled shaders are
CFLAGS += -DPPU_DATA_DIR='"$(abspath .)"' -DPPU_SHADER_DIR='"$(abspath $(SHADER_OUT))"'
CXXFLAGS = $(CFLAGS)

HEADERS = $(wildcard include/*.h) $(shell find $(VK_WRAP)/include -name '*.h')

# Library paths
LDFLAGS = -L/opt/homebrew/lib  -L/usr/local/lib

# Opencv Libraries
LDLIBS = -lglfw -lvulkan

# Rule for building Cpp objects
$(OUT)/%.o : $(SRC)/%.cpp $(HEADERS)
	@mkdir -p $(OUT)
	$(CC) -c -o $@ $< $(CFLAGS) $(CLI_FLAGS)

# Rule for building shader SPIR-V, written to $(SHADER_OUT)/<name>.<stage>.spv. Shaders include the
# wrapper's GLSL (bindless.glsl).
GLSL_INCLUDES = $(wildcard $(VK_WRAP)/include/glsl/*.glsl)
$(SHADER_OUT)/%.spv : shaders/% $(GLSL_INCLUDES)
	@mkdir -p $(SHADER_OUT)
	glslc -I$(VK_WRAP)/include/glsl --target-env=vulkan1.3 $< -o $@

_COMMON = PpuNodes.o PpuSession.o
COMMON = $(patsubst %,$(OUT)/%,$(_COMMON))

_SMB3 =  smb3.o
SMB3 = $(patsubst %,$(OUT)/%,$(_SMB3))

_BATMAN =  batman.o
BATMAN = $(patsubst %,$(OUT)/%,$(_BATMAN))

_SHADERS = nes.comp draw.frag draw.vert
SHADERS = $(patsubst %,$(SHADER_OUT)/%.spv,$(_SHADERS))

smb3/ppu: $(COMMON) $(SMB3) | $(SHADERS)
	$(CC) $^ -o $@ $(LDFLAGS) $(LDLIBS)
	install_name_tool -add_rpath /usr/local/lib ./$@

batman/ppu: $(COMMON) $(BATMAN) | $(SHADERS)
	$(CC) $^ -o $@ $(LDFLAGS) $(LDLIBS)
	install_name_tool -add_rpath /usr/local/lib ./$@

# ---------------------------------------------------------------------------
# Screenshot tests
#   make test                - capture each game's frames and compare them with tests/approved
#   make approve-screenshots - accept the frames captured by the last run
# ---------------------------------------------------------------------------
GAMES = smb3 batman
RECEIVED = $(OUT)/screenshots

$(OUT)/compare_screenshots: tests/compare_screenshots.cpp
	$(CC) -o $@ $< $(CFLAGS)

test: $(patsubst %,%/ppu,$(GAMES)) $(OUT)/compare_screenshots
	tests/run_screenshot_tests.sh $(OUT)/compare_screenshots $(RECEIVED) $(GAMES)

approve-screenshots:
	@for game in $(GAMES); do \
		mkdir -p tests/approved/$$game; \
		for image in $(RECEIVED)/$$game/*.png; do \
			case $$image in *.diff.png) continue;; esac; \
			cp $$image tests/approved/$$game/ && echo "Approved $$game/$$(basename $$image)"; \
		done; \
	done

.PHONY: clean test approve-screenshots shaders

shaders: $(SHADERS)

clean:
	rm -rf $(OUT)
	rm -f smb3/ppu batman/ppu