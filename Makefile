# Compiler
CC = /usr/bin/g++
CXX = $(CC)

# Include paths
CFLAGS = -std=c++20 -Wc++11-extensions -I./include -I/usr/local/include -Wc++14-extensions -DENABLE_PRECOMPILED_HEADERS=OFF -I/Users/zyoussef/code/vulkan_test/vulkan_test -I/Users/zyoussef/stb/ -I/Users/zyoussef/VulkanSDK/1.4.321.0/macOS/include/
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

_SHADERS = nes.comp draw.frag draw.vert
SHADERS = $(patsubst %,shaders/spirv/%.spirv,$(_SHADERS))

smb3/ppu: $(COMMON) $(SMB3) | $(SHADERS)
	$(CC) $^ -o $@ $(LDFLAGS) $(LDLIBS)
	install_name_tool -add_rpath /usr/local/lib ./$@

.PHONY: clean 

clean:
	rm -f build/*.o shaders/spirv/*.spirv
	rm -f smb3/ppu