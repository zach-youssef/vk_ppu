#pragma once

#include <cstdint>
#include <sys/types.h>
#include <string>

#ifndef PPU_DATA_DIR
#error "PPU_DATA_DIR must be defined to the directory containing the games' memory dumps"
#endif

static const uint SCANLINES = 240;

// Where the games' memory dumps are (the repository root)
static const std::string dataDir = PPU_DATA_DIR;
