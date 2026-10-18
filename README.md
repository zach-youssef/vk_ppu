# Vulkan PPU

Implemention of retro picture processing units (just NES for now) implemented as Vulkan compute pipelines.

I wrote a compute shader that approximates how the NES PPU would render a single scanline and use this to render real NES memory dumps from an emulator.

To support advanced functionality like changing registers partway through a frame (as is done in the title screen of Super Mario Bros 3, which switches name tables at scanline 192), the scanlines before and after a change are rendered by separate dispatches, each with its own registers. Animations (palette cycling, metasprites, animated tiles, OAM cycling) are each game's state, advanced every game frame and written into the PPU's memory before the frame renders (as during 'V-Blank').

Everything is written in ZGAL, the shader and render graph language of my [Vulkan Wrapper](https://github.com/zach-youssef/vulkan_testing/tree/zgal) (a submodule in `external/vulkan_test`): the PPU (`nes/nes.zgal`) and each game's program (`smb3/smb3.zgal`, `batman/batman.zgal`), whose C++ and shaders the build generates. There's no C++ of its own.

# Building and running

The games' memory dumps go in `<game>/assets` (they aren't in the repository): `ppu_dump.bin` and `oam_dump.bin`, and Batman's animated tiles in `batman/assets/tileframes/0.bin` to `7.bin`. Building needs what the wrapper does (the Vulkan SDK, `glslc`, GLFW, GLM and Racket 8).

    make                       # builds build/smb3/smb3 and build/batman/batman
    build/smb3/smb3            # in a window (--help for the options)
    make test                  # captures frames 1 to 120 headless, with validation, and compares them
                               # with tests/approved
    make approve-screenshots   # accepts the last run's frames

# Screnshots

![screenshot](screenshots/smb3.png)
![screenshot](screenshots/batman.png)
