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
#include <ghostty/vt/result.h>
#include <ghostty/vt/allocator.h>

/**
 * Opaque handle to a VT parser instance.
 *
 * @ingroup parser
 */
typedef struct GhosttyParser *GhosttyParser;

/** @defgroup parser VT Parser
 *
 * VT-series escape and control sequence parser implementing the state machine
 * described at https://vt100.net/emu/dec_ansi_parser.
 *
 * The parser processes input byte-by-byte and returns actions describing
 * what the terminal should do (print a character, execute a control function,
 * dispatch a CSI/ESC/OSC/DCS sequence, etc.).
 *
 * ## Basic Usage
 *
 * 1. Create a parser instance with ghostty_parser_new()
 * 2. Feed bytes using ghostty_parser_next(), which returns actions
 * 3. For CSI/ESC/DCS actions, use the corresponding accessor to get details
 * 4. Free the parser with ghostty_parser_free() when done
 *
 * @{
 */

/**
 * Action tags returned by the parser.
 *
 * @ingroup parser
 */
typedef enum {
    GHOSTTY_PARSER_ACTION_NONE = 0,
    /** Draw a unicode codepoint. Value is the codepoint. */
    GHOSTTY_PARSER_ACTION_PRINT = 1,
    /** Execute a C0/C1 control function. Value is the byte. */
    GHOSTTY_PARSER_ACTION_EXECUTE = 2,
    /** CSI sequence dispatched. Use ghostty_parser_csi() for details. */
    GHOSTTY_PARSER_ACTION_CSI_DISPATCH = 3,
    /** ESC sequence dispatched. Use ghostty_parser_esc() for details. */
    GHOSTTY_PARSER_ACTION_ESC_DISPATCH = 4,
    /** OSC sequence dispatched. */
    GHOSTTY_PARSER_ACTION_OSC_DISPATCH = 5,
    /** DCS hook. Use ghostty_parser_dcs() for details. */
    GHOSTTY_PARSER_ACTION_DCS_HOOK = 6,
    /** DCS data byte. Value is the byte. */
    GHOSTTY_PARSER_ACTION_DCS_PUT = 7,
    /** DCS unhook (end of DCS sequence). */
    GHOSTTY_PARSER_ACTION_DCS_UNHOOK = 8,
    /** APC sequence start. */
    GHOSTTY_PARSER_ACTION_APC_START = 9,
    /** APC data byte. Value is the byte. */
    GHOSTTY_PARSER_ACTION_APC_PUT = 10,
    /** APC sequence end. */
    GHOSTTY_PARSER_ACTION_APC_END = 11,
} GhosttyParserActionTag;

/**
 * A single action returned by the parser.
 *
 * The `value` field interpretation depends on the `tag`:
 *   - PRINT: unicode codepoint (u21 stored as uint32_t)
 *   - EXECUTE: the C0/C1 byte
 *   - CSI_DISPATCH: the final byte
 *   - ESC_DISPATCH: the final byte
 *   - DCS_PUT, APC_PUT: the data byte
 *   - Others: unused (0)
 *
 * @ingroup parser
 */
typedef struct {
    GhosttyParserActionTag tag;
    uint32_t value;
} GhosttyParserAction;

/**
 * The set of actions returned by a single call to ghostty_parser_next().
 * Up to 3 actions may be returned per byte (state exit, transition, entry).
 *
 * @ingroup parser
 */
typedef struct {
    GhosttyParserAction actions[3];
    uint8_t count;
} GhosttyParserActions;

/**
 * CSI sequence details.
 * Pointers are valid until the next call to ghostty_parser_next().
 *
 * @ingroup parser
 */
typedef struct {
    const uint8_t *intermediates;
    uint8_t intermediates_len;
    const uint16_t *params;
    uint8_t params_len;
    uint8_t final;
    /** Bitmask: bit i set means separator after param i is colon, else semicolon. */
    uint32_t params_sep;
} GhosttyParserCSI;

/**
 * ESC sequence details.
 * Pointers are valid until the next call to ghostty_parser_next().
 *
 * @ingroup parser
 */
typedef struct {
    const uint8_t *intermediates;
    uint8_t intermediates_len;
    uint8_t final;
} GhosttyParserESC;

/**
 * DCS hook details.
 * Pointers are valid until the next call to ghostty_parser_next().
 *
 * @ingroup parser
 */
typedef struct {
    const uint8_t *intermediates;
    uint8_t intermediates_len;
    const uint16_t *params;
    uint8_t params_len;
    uint8_t final;
} GhosttyParserDCS;

/**
 * Create a new VT parser instance.
 *
 * @param allocator Pointer to the allocator, or NULL for the default allocator
 * @param parser Pointer to store the created parser handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup parser
 */
GhosttyResult ghostty_parser_new(const GhosttyAllocator *allocator, GhosttyParser *parser);

/**
 * Free a VT parser instance.
 *
 * @param parser The parser handle to free (may be NULL)
 *
 * @ingroup parser
 */
void ghostty_parser_free(GhosttyParser parser);

/**
 * Reset a VT parser to its initial state.
 *
 * @param parser The parser handle, must not be NULL
 *
 * @ingroup parser
 */
void ghostty_parser_reset(GhosttyParser parser);

/**
 * Process the next byte through the parser.
 *
 * Returns up to 3 actions (state exit, transition, and entry actions).
 * The actions should be processed in order.
 *
 * @param parser The parser handle, must not be NULL
 * @param byte The next input byte
 * @param actions Pointer to store the resulting actions
 *
 * @ingroup parser
 */
void ghostty_parser_next(GhosttyParser parser, uint8_t byte, GhosttyParserActions *actions);

/**
 * Get CSI sequence details from the last parsed action.
 *
 * Only valid after ghostty_parser_next() returned an action with tag
 * GHOSTTY_PARSER_ACTION_CSI_DISPATCH, and before the next call to
 * ghostty_parser_next().
 *
 * @param parser The parser handle
 * @param result Pointer to store CSI details
 * @return true if CSI data was available, false otherwise
 *
 * @ingroup parser
 */
bool ghostty_parser_csi(GhosttyParser parser, GhosttyParserCSI *result);

/**
 * Get ESC sequence details from the last parsed action.
 *
 * Only valid after ghostty_parser_next() returned an action with tag
 * GHOSTTY_PARSER_ACTION_ESC_DISPATCH, and before the next call to
 * ghostty_parser_next().
 *
 * @param parser The parser handle
 * @param result Pointer to store ESC details
 * @return true if ESC data was available, false otherwise
 *
 * @ingroup parser
 */
bool ghostty_parser_esc(GhosttyParser parser, GhosttyParserESC *result);

/**
 * Get DCS hook details from the last parsed action.
 *
 * Only valid after ghostty_parser_next() returned an action with tag
 * GHOSTTY_PARSER_ACTION_DCS_HOOK, and before the next call to
 * ghostty_parser_next().
 *
 * @param parser The parser handle
 * @param result Pointer to store DCS details
 * @return true if DCS data was available, false otherwise
 *
 * @ingroup parser
 */
bool ghostty_parser_dcs(GhosttyParser parser, GhosttyParserDCS *result);

/** @} */

#endif /* GHOSTTY_VT_PARSER_H */
