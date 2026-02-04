#pragma once

#include <cstdint>

// Referencing https://www.nesdev.org/

// Tile value at pixel -> index into palette
// Attribute table -> which palette to use

namespace nes {
    // A tile is an 8x8 grid of 2-bit pixels
    struct Tile {
        uint8_t data[16];
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
        TileSet tileSets[2];
        NameTable nameTables[4];
        Palette backgroundPalettes[4];
        Palette spritePalettes[4];
    };

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

    struct SpriteRam {
        Sprite sprites[64];
    };

} // nes
