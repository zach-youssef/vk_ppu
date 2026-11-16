/*
 * A headless libretro frontend for the Genesis Plus GX core: loads a game and a savestate, runs N
 * frames, and writes the last frame as a PNG and the core's state after it. The state then holds
 * the memory that frame was drawn from (Genesis Plus GX's retro_run runs the vertical blank first
 * and the active lines last), so the PNG is its reference screenshot. See ../genesis.md.
 *
 *   gpgx-frame <core> <game> <state> <frames> <out.png> <out.state> <system-dir> <save-dir>
 *
 * <core> is the libretro core (built by build.sh). <game> is a cartridge ROM or a Sega CD disc's
 * .cue (a path of at most 255 bytes): the core reads it from the path itself. It must be the game
 * the state was saved from: the core doesn't check, and runs another game's state into garbage.
 * <state> is the core's own state (retro_serialize), or RetroArch's uncompressed container around
 * one. <frames> >= 1 is how many frames to run. <system-dir> is where the core looks for BIOS
 * files (bios_CD_U/E/J.bin for the Sega CD) and <save-dir> where it reads and writes backup RAM:
 * give it a throwaway directory.
 * Every core option keeps its default value. Exits 0 on success, printing the frame's width and
 * height, and 1 (with the reason on stderr) on any failure; the outputs are written last, but a
 * failure while writing them can leave one behind, so a caller that keeps them writes them to a
 * temporary directory first.
 *
 * Genesis Plus GX is GPL and non-commercial: this file only calls it through the libretro API
 * (libretro.h, MIT, from the core's own checkout), and copies none of its code.
 */
#include <dlfcn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "libretro.h"

static void fail(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    fputs("gpgx-frame: ", stderr);
    vfprintf(stderr, fmt, args);
    fputc('\n', stderr);
    va_end(args);
    exit(1);
}

/* ---- Core options: every option at its default, which the core lists first ---------------- */

#define MAX_OPTIONS 256
static struct {
    char *key;
    char *value;
} options[MAX_OPTIONS];
static int option_count;

/* RETRO_ENVIRONMENT_SET_VARIABLES: each value is "Description; default|other|...". */
static void set_variables(const struct retro_variable *vars)
{
    for (; vars->key; vars++) {
        const char *values = strstr(vars->value, "; ");
        if (!values)
            fail("core option %s has no values: \"%s\"", vars->key, vars->value);
        values += 2;
        size_t length = strcspn(values, "|");
        if (option_count == MAX_OPTIONS)
            fail("more than %d core options", MAX_OPTIONS);
        options[option_count].key = strdup(vars->key);
        options[option_count].value = strndup(values, length);
        option_count++;
    }
}

static const char *get_variable(const char *key)
{
    for (int i = 0; i < option_count; i++)
        if (!strcmp(options[i].key, key))
            return options[i].value;
    return NULL;
}

/* ---- Environment ---------------------------------------------------------------------------- */

static const char *system_dir;
static const char *save_dir;
static enum retro_pixel_format pixel_format = RETRO_PIXEL_FORMAT_0RGB1555; /* libretro's default */

static void log_message(enum retro_log_level level, const char *fmt, ...)
{
    if (level < RETRO_LOG_WARN)
        return;
    va_list args;
    va_start(args, fmt);
    fputs(level == RETRO_LOG_WARN ? "gpgx-frame: core warning: " : "gpgx-frame: core error: ",
          stderr);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

static bool environment(unsigned cmd, void *data)
{
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        ((struct retro_log_callback *)data)->log = log_message;
        return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        *(const char **)data = system_dir;
        return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = save_dir;
        return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        enum retro_pixel_format format = *(const enum retro_pixel_format *)data;
        if (format != RETRO_PIXEL_FORMAT_0RGB1555 && format != RETRO_PIXEL_FORMAT_RGB565 &&
            format != RETRO_PIXEL_FORMAT_XRGB8888)
            return false;
        pixel_format = format;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLES:
        set_variables(data);
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *var = data;
        var->value = get_variable(var->key);
        return var->value != NULL;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *(bool *)data = false;
        return true;
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
        /* Video and audio on; not "fast savestates" (bit 2), so loading a state resets fully */
        *(int *)data = 1 | 2;
        return true;
    default:
        /* Everything else is unsupported, which the core handles: notably
         * GET_CORE_OPTIONS_VERSION (so it lists its options with SET_VARIABLES) and
         * GET_GAME_INFO_EXT (so it reads the game from its path). */
        return false;
    }
}

/* ---- Video, audio, input -------------------------------------------------------------------- */

static struct {
    uint8_t *rgb; /* 8-bit RGB, width * height * 3 */
    unsigned width, height;
    bool drawn;   /* the core drew this frame (not a duplicate) */
} frame;

/* Converts the frame to 8-bit RGB. Each channel's bits are replicated into the low bits
 * (5 bits: v << 3 | v >> 2; 6 bits: v << 2 | v >> 4), the usual conversion, which RetroArch's
 * screenshots use too. */
static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch)
{
    frame.drawn = data != NULL;
    if (!data)
        return;
    free(frame.rgb);
    frame.rgb = malloc((size_t)width * height * 3);
    if (!frame.rgb)
        fail("out of memory");
    frame.width = width;
    frame.height = height;
    for (unsigned y = 0; y < height; y++) {
        const uint8_t *row = (const uint8_t *)data + y * pitch;
        uint8_t *out = frame.rgb + (size_t)y * width * 3;
        for (unsigned x = 0; x < width; x++, out += 3) {
            unsigned r, g, b;
            if (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
                uint32_t p = ((const uint32_t *)row)[x];
                r = (p >> 16) & 0xFF;
                g = (p >> 8) & 0xFF;
                b = p & 0xFF;
            } else if (pixel_format == RETRO_PIXEL_FORMAT_RGB565) {
                uint16_t p = ((const uint16_t *)row)[x];
                r = (p >> 11) & 0x1F;
                g = (p >> 5) & 0x3F;
                b = p & 0x1F;
                r = r << 3 | r >> 2;
                g = g << 2 | g >> 4;
                b = b << 3 | b >> 2;
            } else {
                uint16_t p = ((const uint16_t *)row)[x];
                r = (p >> 10) & 0x1F;
                g = (p >> 5) & 0x1F;
                b = p & 0x1F;
                r = r << 3 | r >> 2;
                g = g << 3 | g >> 2;
                b = b << 3 | b >> 2;
            }
            out[0] = r;
            out[1] = g;
            out[2] = b;
        }
    }
}

static void audio_sample(int16_t left, int16_t right) { (void)left, (void)right; }
static size_t audio_sample_batch(const int16_t *data, size_t frames) { (void)data; return frames; }
static void input_poll(void) {}
static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
    (void)port, (void)device, (void)index, (void)id;
    return 0; /* no buttons pressed */
}

/* ---- Files ---------------------------------------------------------------------------------- */

static uint8_t *read_file(const char *path, size_t *size)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        fail("can't open %s", path);
    size_t capacity = 1 << 20, length = 0;
    uint8_t *data = malloc(capacity);
    for (size_t n; data && (n = fread(data + length, 1, capacity - length, f)) > 0;) {
        length += n;
        if (length == capacity)
            data = realloc(data, capacity *= 2);
    }
    if (!data)
        fail("out of memory");
    if (ferror(f))
        fail("can't read %s", path);
    fclose(f);
    *size = length;
    return data;
}

static void write_file(const char *path, const void *data, size_t size)
{
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(data, 1, size, f) != size || fclose(f) != 0)
        fail("can't write %s", path);
}

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void put_be32(uint8_t *p, uint32_t v) { p[0] = v >> 24, p[1] = v >> 16, p[2] = v >> 8, p[3] = v; }

/* RetroArch's uncompressed savestate container: "RASTATE", a version byte, then blocks of a
 * 4-byte id, a little-endian 32-bit length and the content, padded to 8 bytes, up to "END ". The
 * core's state is the "MEM " block. Anything else is taken as the core's state itself. */
static const uint8_t *core_state(const uint8_t *data, size_t *size)
{
    if (*size < 8 || memcmp(data, "RASTATE", 7))
        return data;
    for (size_t at = 8; at + 8 <= *size;) {
        size_t length = le32(data + at + 4);
        if (length > *size - at - 8)
            break;
        if (!memcmp(data + at, "MEM ", 4)) {
            *size = length;
            return data + at + 8;
        }
        if (!memcmp(data + at, "END ", 4))
            fail("the RetroArch savestate has no core state");
        at += 8 + ((length + 7) & ~(size_t)7);
    }
    fail("the RetroArch savestate runs past its end");
    return NULL;
}

/* An 8-bit RGB PNG (colour type 2), zlib-compressed at the best level */
static void write_png(const char *path, const uint8_t *rgb, unsigned width, unsigned height)
{
    size_t row = (size_t)width * 3 + 1, raw_size = row * height;
    uint8_t *raw = malloc(raw_size);
    uLongf packed_size = compressBound(raw_size);
    uint8_t *png = malloc(8 + 25 + 12 + packed_size + 12);
    if (!raw || !png)
        fail("out of memory");
    for (unsigned y = 0; y < height; y++) {
        raw[y * row] = 0; /* filter: none */
        memcpy(raw + y * row + 1, rgb + (size_t)y * width * 3, row - 1);
    }

    uint8_t *p = png;
    memcpy(p, "\x89PNG\r\n\x1a\n", 8);
    p += 8;
    /* Each chunk: length, type, data, CRC of type and data */
    uint8_t ihdr[13];
    put_be32(ihdr, width);
    put_be32(ihdr + 4, height);
    memcpy(ihdr + 8, "\x08\x02\x00\x00\x00", 5); /* 8 bits, RGB, deflate, no filter, no interlace */
    const struct { const char *type; const uint8_t *data; size_t size; } chunks[] = {
        {"IHDR", ihdr, sizeof ihdr}, {"IDAT", NULL, 0}, {"IEND", NULL, 0}};
    for (int i = 0; i < 3; i++) {
        uint8_t *start = p;
        size_t size = chunks[i].size;
        memcpy(p + 4, chunks[i].type, 4);
        if (i == 1) {
            if (compress2(p + 8, &packed_size, raw, raw_size, Z_BEST_COMPRESSION) != Z_OK)
                fail("can't compress the PNG");
            size = packed_size;
        } else if (size) {
            memcpy(p + 8, chunks[i].data, size);
        }
        put_be32(start, size);
        put_be32(p + 8 + size, crc32(crc32(0, NULL, 0), p + 4, size + 4));
        p += 12 + size;
    }
    write_file(path, png, p - png);
    free(raw);
    free(png);
}

/* ---- Main ----------------------------------------------------------------------------------- */

#define CORE_FUNCTIONS(X)                                                                       \
    X(void, retro_set_environment, (retro_environment_t))                                       \
    X(void, retro_set_video_refresh, (retro_video_refresh_t))                                   \
    X(void, retro_set_audio_sample, (retro_audio_sample_t))                                     \
    X(void, retro_set_audio_sample_batch, (retro_audio_sample_batch_t))                         \
    X(void, retro_set_input_poll, (retro_input_poll_t))                                         \
    X(void, retro_set_input_state, (retro_input_state_t))                                       \
    X(void, retro_init, (void))                                                                 \
    X(void, retro_deinit, (void))                                                               \
    X(unsigned, retro_api_version, (void))                                                      \
    X(bool, retro_load_game, (const struct retro_game_info *))                                  \
    X(void, retro_unload_game, (void))                                                          \
    X(void, retro_run, (void))                                                                  \
    X(size_t, retro_serialize_size, (void))                                                     \
    X(bool, retro_serialize, (void *, size_t))                                                  \
    X(bool, retro_unserialize, (const void *, size_t))

#define DECLARE(ret, name, args) static ret(*core_##name) args;
CORE_FUNCTIONS(DECLARE)

int main(int argc, char **argv)
{
    if (argc != 9) {
        fprintf(stderr, "usage: gpgx-frame <core> <game> <state> <frames> <out.png> <out.state> "
                        "<system-dir> <save-dir>\n");
        return 1;
    }
    const char *core_path = argv[1], *game_path = argv[2], *state_path = argv[3];
    const char *png_path = argv[5], *state_out_path = argv[6];
    system_dir = argv[7];
    save_dir = argv[8];
    char *end;
    long frames = strtol(argv[4], &end, 10);
    if (*argv[4] == '\0' || *end != '\0' || frames < 1 || frames > 1000000)
        fail("frames must be a whole number from 1 (the frame after the state) to 1000000: \"%s\"",
             argv[4]);
    /* The core copies these paths into 256-byte buffers, truncating them without an error: the
     * game's as it is, and the directories' with a file name (bios_CD_U.bin, scd_U.brm) after */
    if (strlen(game_path) > 255)
        fail("the game's path is over 255 bytes, more than the core takes: %s", game_path);
    if (strlen(system_dir) > 200 || strlen(save_dir) > 200)
        fail("the system and save directories' paths must be at most 200 bytes");

    void *core = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
    if (!core)
        fail("can't load the core: %s", dlerror());
#define RESOLVE(ret, name, args)                                                                \
    if (!(*(void **)&core_##name = dlsym(core, #name)))                                         \
        fail("the core has no %s", #name);
    CORE_FUNCTIONS(RESOLVE)
    if (core_retro_api_version() != RETRO_API_VERSION)
        fail("the core's libretro API version is %u, not %u", core_retro_api_version(),
             RETRO_API_VERSION);

    core_retro_set_environment(environment);
    core_retro_set_video_refresh(video_refresh);
    core_retro_set_audio_sample(audio_sample);
    core_retro_set_audio_sample_batch(audio_sample_batch);
    core_retro_set_input_poll(input_poll);
    core_retro_set_input_state(input_state);
    core_retro_init();

    /* The core reads the game from its path (need_fullpath): a .cue's tracks from beside it */
    struct retro_game_info game = {.path = game_path};
    if (!core_retro_load_game(&game))
        fail("the core can't load %s (for a Sega CD disc, is its BIOS in %s?)", game_path,
             system_dir);

    size_t state_file_size, state_size;
    uint8_t *state_file = read_file(state_path, &state_file_size);
    state_size = state_file_size;
    const uint8_t *state = core_state(state_file, &state_size);
    /* A Mega-CD state's "SCD!" marker follows the sound context, which a build without the Nuked
     * YM3438 core (OpenEmu's) saves one byte shorter: this build, which has it, would misread
     * everything after the VDP. (A Mega Drive state from such a build has no marker to tell.) */
    if (state_size >= 0x234C5 + 4 && !memcmp(state + 0x234C5, "SCD!", 4))
        fail("%s is a Mega-CD state from a Genesis Plus GX build without the Nuked YM3438 core "
             "(such as OpenEmu's), whose layout this core reads differently", state_path);
    /* The core takes exactly its own state size; a shorter state (one saved by another build,
     * which writes only what it used) is padded with zeros, which the core doesn't read. */
    size_t core_size = core_retro_serialize_size();
    if (state_size > core_size)
        fail("the state is %zu bytes, more than the core's %zu", state_size, core_size);
    uint8_t *padded = calloc(1, core_size);
    if (!padded)
        fail("out of memory");
    memcpy(padded, state, state_size);
    if (!core_retro_unserialize(padded, core_size))
        fail("the core refused the state %s (not a Genesis Plus GX state, or a Mega Drive state "
             "with a Sega CD disc)", state_path);

    for (long i = 0; i < frames; i++)
        core_retro_run();
    if (!frame.drawn)
        fail("the core didn't draw frame %ld", frames);

    /* calloc: the core writes only the part of the state it uses */
    uint8_t *state_out = calloc(1, core_size);
    if (!state_out || !core_retro_serialize(state_out, core_size))
        fail("the core couldn't save its state");
    write_png(png_path, frame.rgb, frame.width, frame.height);
    write_file(state_out_path, state_out, core_size);

    core_retro_unload_game();
    core_retro_deinit();
    printf("width=%u\nheight=%u\nframes=%ld\n", frame.width, frame.height, frames);
    return 0;
}
