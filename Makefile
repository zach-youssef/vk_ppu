# Compiler
CC = /usr/bin/g++
CXX = $(CC)

# Vulkan wrapper headers (git submodule)
VK_WRAP = external/vulkan_test/vulkan_test

# Include paths
CFLAGS = -std=c++20 -Wc++11-extensions -I./include -I/usr/local/include -Wc++14-extensions -DENABLE_PRECOMPILED_HEADERS=OFF -I$(VK_WRAP) -I/Users/zyoussef/stb/ -I/Users/zyoussef/VulkanSDK/1.4.321.0/macOS/include/
CXXFLAGS = $(CFLAGS)

# Library paths
LDFLAGS = -L/opt/homebrew/lib  -L/usr/local/lib

# Opencv Libraries
LDLIBS = -lglfw -lvulkan

OUT = build
SRC = src

# Rule for building Cpp objects
$(OUT)/%.o : $(SRC)/%.cpp
	$(CC) -c -o $@ $< $(CFLAGS) $(CLI_FLAGS)

# Rule for building shader spirv
shaders/spirv/%.comp.spirv : shaders/%.comp
	glslc $^ -o $@
shaders/spirv/%.frag.spirv : shaders/%.frag
	glslc $^ -o $@
shaders/spirv/%.vert.spirv : shaders/%.vert
	glslc $^ -o $@

_COMMON = PpuComputeNode.o MemoryUpdateComposer.o PpuSession.o
COMMON = $(patsubst %,$(OUT)/%,$(_COMMON))

_SMB3 =  smb3.o
SMB3 = $(patsubst %,$(OUT)/%,$(_SMB3))

_BATMAN =  batman.o
BATMAN = $(patsubst %,$(OUT)/%,$(_BATMAN))

_SHADERS = nes.comp draw.frag draw.vert
SHADERS = $(patsubst %,shaders/spirv/%.spirv,$(_SHADERS))

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

.PHONY: clean test approve-screenshots

clean:
	rm -f build/*.o build/compare_screenshots shaders/spirv/*.spirv
	rm -rf $(RECEIVED)
	rm -f smb3/ppu batman/ppu