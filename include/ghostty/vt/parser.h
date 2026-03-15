/**
 * @file parser.h
 *
 * VT escape and control sequence parser (state machine).
 */

#ifndef GHOSTTY_VT_PARSER_H
#define GHOSTTY_VT_PARSER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup parser VT Parser
 *
 * VT-series escape and control sequence parser implementing the state machine
 * described at https://vt100.net/emu/dec_ansi_parser.
 *
 * The parser processes input byte-by-byte and returns actions describing
 * what the terminal should do (print a character, execute a control function,
 * dispatch a CSI/ESC/OSC/DCS sequence, etc.).
 *
 * @{
 */

typedef struct GhosttyParser *GhosttyParser;

typedef enum {
    GHOSTTY_PARSER_ACTION_NONE = 0,
    GHOSTTY_PARSER_ACTION_PRINT = 1,
    GHOSTTY_PARSER_ACTION_EXECUTE = 2,
    GHOSTTY_PARSER_ACTION_CSI_DISPATCH = 3,
    GHOSTTY_PARSER_ACTION_ESC_DISPATCH = 4,
    GHOSTTY_PARSER_ACTION_OSC_DISPATCH = 5,
    GHOSTTY_PARSER_ACTION_DCS_HOOK = 6,
    GHOSTTY_PARSER_ACTION_DCS_PUT = 7,
    GHOSTTY_PARSER_ACTION_DCS_UNHOOK = 8,
    GHOSTTY_PARSER_ACTION_APC_START = 9,
    GHOSTTY_PARSER_ACTION_APC_PUT = 10,
    GHOSTTY_PARSER_ACTION_APC_END = 11,
} GhosttyParserActionTag;

typedef struct {
    GhosttyParserActionTag tag;
    uint32_t value;
} GhosttyParserAction;

typedef struct {
    GhosttyParserAction actions[3];
    uint8_t count;
} GhosttyParserActions;

typedef struct {
    const uint8_t *intermediates;
    uint8_t intermediates_len;
    const uint16_t *params;
    uint8_t params_len;
    uint8_t final_byte;
    uint32_t params_sep;
} GhosttyParserCSI;

typedef struct {
    const uint8_t *intermediates;
    uint8_t intermediates_len;
    uint8_t final_byte;
} GhosttyParserESC;

typedef struct {
    const uint8_t *intermediates;
    uint8_t intermediates_len;
    const uint16_t *params;
    uint8_t params_len;
    uint8_t final_byte;
} GhosttyParserDCS;

GhosttyResult ghostty_parser_new(const GhosttyAllocator *allocator,
                                 GhosttyParser *parser);

void ghostty_parser_free(GhosttyParser parser);

void ghostty_parser_reset(GhosttyParser parser);

void ghostty_parser_next(GhosttyParser parser,
                         uint8_t byte,
                         GhosttyParserActions *actions);

bool ghostty_parser_csi(GhosttyParser parser, GhosttyParserCSI *result);

bool ghostty_parser_esc(GhosttyParser parser, GhosttyParserESC *result);

bool ghostty_parser_dcs(GhosttyParser parser, GhosttyParserDCS *result);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_PARSER_H */
