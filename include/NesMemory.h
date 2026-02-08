#pragma once

#include <cstdint>

// Referencing https://www.nesdev.org/

// Tile value at pixel -> index into palette
// Attribute table -> which palette to use

namespace nes {
    // A tile is an 8x8 grid of 2-bit pixels
    struct Tile {
        uint8_t plane0[8];
        uint8_t plane1[8];
    };

    // Each tileset has 256 tiles
    struct TileSet { 
        Tile tiles[256];
    };

    // A name table has 32 * 30 -> 960 tile indices, followed by a 64-bit attribute table
    struct NameTable {
        uint8_t tileIndies[960];
        uint8_t attributeTable[64];
    };

    // A palette has 3 colors + the background color
    struct Palette {
        uint8_t data[4];
    };

    struct PPUMemory {
        // 0x0000 - 0x1FFF
        TileSet tileSets[2];
        // 0x2000 - 0x2FFF
        NameTable nameTables[4];
        // 0x3000 - 0x3EFF
        uint8_t padding0[3840];
        // 0x3F00 - 0x3F1F
        Palette backgroundPalettes[4];
        Palette spritePalettes[4];
        // 0x3f20 - 0x3FFF
        uint8_t padding1[224];
    };
    static_assert(sizeof(PPUMemory) == 0x4000);

    // Each sprite is 4 bytes
    struct Sprite {
        uint8_t y;
        uint8_t tileIndex;
        uint8_t attr;
        uint8_t x;
    };

    enum SpriteAttrMask {
        VERTICAL_FLIP = 0x80,
        HORIZONTAL_FLIP = 0x40,
        PRIORITY = 0x20,
        TILE_HIGH_BITS = 0x03
    };

    struct OAM {
        Sprite sprites[64];
    };
    static_assert(sizeof(OAM) == 256);

} // nes
