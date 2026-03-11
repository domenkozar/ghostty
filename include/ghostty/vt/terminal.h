/**
 * @file terminal.h
 *
 * Full VT terminal emulator with write/read interface.
 */

#ifndef GHOSTTY_VT_TERMINAL_H
#define GHOSTTY_VT_TERMINAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/result.h>
#include <ghostty/vt/allocator.h>

/**
 * Callback function type for sequence events.
 *
 * Called after each VT escape sequence is processed. The action parameter
 * identifies which sequence was processed (e.g., print, cursor movement,
 * mode change). The value parameter carries action-specific data:
 *   - set_mode/reset_mode/save_mode/restore_mode/request_mode: DEC/ANSI mode number
 *   - kitty_keyboard_push/set/set_or/set_not: flags bitmask
 *   - kitty_keyboard_pop: pop count
 *   - All others: 0
 *
 * @param action Action tag identifying the processed sequence
 * @param value Action-specific value (mode number, flags, etc.)
 * @param userdata User-provided context pointer
 *
 * @ingroup terminal
 */
typedef void (*GhosttySequenceCallback)(int action, int64_t value, void *userdata);

/**
 * Opaque handle to a VT terminal instance.
 *
 * @ingroup terminal
 */
typedef struct GhosttyTerminal *GhosttyTerminal;

/** @defgroup terminal VT Terminal
 *
 * Full VT terminal emulator providing a write/read interface.
 * Write raw bytes (including escape sequences) and read back
 * terminal state such as cursor position, screen dimensions,
 * and plain text content.
 *
 * ## Basic Usage
 *
 * 1. Create a terminal with ghostty_terminal_new()
 * 2. Write data using ghostty_terminal_write()
 * 3. Query state with ghostty_terminal_get_cursor_pos(),
 *    ghostty_terminal_get_size(), or ghostty_terminal_plain_string()
 * 4. Free the terminal with ghostty_terminal_free() when done
 *
 * @{
 */

/**
 * A heap-allocated string returned by ghostty_terminal_plain_string().
 * Must be freed with ghostty_terminal_plain_string_free().
 *
 * @ingroup terminal
 */
typedef struct {
    const uint8_t *ptr;
    size_t len;
} GhosttyTerminalString;

/**
 * Row metadata for a single terminal row.
 *
 * @ingroup terminal
 */
typedef struct {
    bool wrap;               /**< Row is soft-wrapped (continues on next row) */
    bool wrap_continuation;  /**< Row is continuation of previous wrapped row */
    bool styled;             /**< Row contains styled cells */
    bool hyperlink;          /**< Row contains hyperlinked cells */
    uint8_t semantic_prompt; /**< 0=none, 1=prompt, 2=prompt_continuation */
} GhosttyTerminalRow;

/**
 * Cell data for a single terminal cell.
 *
 * @ingroup terminal
 */
typedef struct {
    uint32_t codepoint;      /**< Primary codepoint (0 for empty/bg-only cells) */
    uint16_t style_id;       /**< Style ID (0 = default, no lookup needed) */
    uint8_t content_tag;     /**< 0=codepoint, 1=grapheme, 2=bg_palette, 3=bg_rgb */
    uint8_t wide;            /**< 0=narrow, 1=wide, 2=spacer_tail, 3=spacer_head */
    uint8_t bg_palette;      /**< Palette index (valid when content_tag == 2) */
    uint8_t bg_r;            /**< Red component (valid when content_tag == 3) */
    uint8_t bg_g;            /**< Green component (valid when content_tag == 3) */
    uint8_t bg_b;            /**< Blue component (valid when content_tag == 3) */
    bool has_grapheme;       /**< True if cell has multi-codepoint grapheme */
    bool is_hyperlink;       /**< True if cell is part of a hyperlink */
    uint8_t semantic_content; /**< 0=output, 1=input, 2=prompt */
    bool is_protected;       /**< Cell has protection attribute set */
} GhosttyTerminalCell;

/**
 * Color value used in styles. Discriminated by tag.
 *
 * @ingroup terminal
 */
typedef struct {
    uint8_t tag;     /**< 0=none, 1=palette, 2=rgb */
    uint8_t palette; /**< Palette index (valid when tag == 1) */
    uint8_t r;       /**< Red component (valid when tag == 2) */
    uint8_t g;       /**< Green component (valid when tag == 2) */
    uint8_t b;       /**< Blue component (valid when tag == 2) */
} GhosttyTerminalColor;

/**
 * Style attributes for a terminal cell.
 *
 * @ingroup terminal
 */
typedef struct {
    GhosttyTerminalColor fg;              /**< Foreground color */
    GhosttyTerminalColor bg;              /**< Background color */
    GhosttyTerminalColor underline_color; /**< Underline color */
    uint8_t underline; /**< 0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed */
    bool bold;
    bool italic;
    bool faint;
    bool blink;
    bool inverse;
    bool invisible;
    bool strikethrough;
    bool overline;
} GhosttyTerminalStyle;

/**
 * Create a new VT terminal instance.
 *
 * @param allocator Pointer to the allocator, or NULL for the default allocator
 * @param cols Number of columns
 * @param rows Number of rows
 * @param terminal Pointer to store the created terminal handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_new(
    const GhosttyAllocator *allocator,
    uint16_t cols,
    uint16_t rows,
    GhosttyTerminal *terminal
);

/**
 * Free a VT terminal instance.
 *
 * @param terminal The terminal handle to free (may be NULL)
 *
 * @ingroup terminal
 */
void ghostty_terminal_free(GhosttyTerminal terminal);

/**
 * Perform a full reset of the terminal (equivalent to RIS).
 *
 * @param terminal The terminal handle (may be NULL)
 *
 * @ingroup terminal
 */
void ghostty_terminal_full_reset(GhosttyTerminal terminal);

/**
 * Write raw bytes to the terminal, processing any escape sequences.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param data Pointer to the byte data
 * @param len Number of bytes to write
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_write(
    GhosttyTerminal terminal,
    const uint8_t *data,
    size_t len
);

/**
 * Get the current terminal dimensions.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param cols Pointer to store the number of columns
 * @param rows Pointer to store the number of rows
 *
 * @ingroup terminal
 */
void ghostty_terminal_get_size(
    GhosttyTerminal terminal,
    uint16_t *cols,
    uint16_t *rows
);

/**
 * Get the current cursor position (0-indexed).
 *
 * @param terminal The terminal handle (may be NULL)
 * @param x Pointer to store the cursor column
 * @param y Pointer to store the cursor row
 *
 * @ingroup terminal
 */
void ghostty_terminal_get_cursor_pos(
    GhosttyTerminal terminal,
    size_t *x,
    size_t *y
);

/**
 * Resize the terminal to new dimensions.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param cols New number of columns
 * @param rows New number of rows
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_resize(
    GhosttyTerminal terminal,
    uint16_t cols,
    uint16_t rows
);

/**
 * Get the plain text content of the terminal viewport.
 *
 * The returned string must be freed with ghostty_terminal_plain_string_free().
 *
 * @param terminal The terminal handle (may be NULL)
 * @param result Pointer to store the resulting string
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_plain_string(
    GhosttyTerminal terminal,
    GhosttyTerminalString *result
);

/**
 * Free a string previously returned by ghostty_terminal_plain_string().
 *
 * @param terminal The terminal handle (may be NULL)
 * @param str The string to free
 *
 * @ingroup terminal
 */
void ghostty_terminal_plain_string_free(
    GhosttyTerminal terminal,
    GhosttyTerminalString str
);

/**
 * Set a callback to be invoked after each VT escape sequence is processed.
 *
 * The callback receives an action tag (int) identifying the sequence type
 * and the provided userdata pointer. Pass NULL for callback to remove
 * a previously set callback.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param callback The callback function, or NULL to remove
 * @param userdata User context pointer passed to each callback invocation
 *
 * @ingroup terminal
 */
void ghostty_terminal_set_sequence_callback(
    GhosttyTerminal terminal,
    GhosttySequenceCallback callback,
    void *userdata
);

/**
 * Get the number of scrollback rows (rows above the active area).
 *
 * @param terminal The terminal handle (may be NULL)
 * @return Number of scrollback rows
 *
 * @ingroup terminal
 */
size_t ghostty_terminal_scrollback_rows(GhosttyTerminal terminal);

/**
 * Get the total number of rows (scrollback + active area).
 *
 * All row/cell access functions use screen coordinates where y=0 is the
 * top of scrollback. The active area starts at y = scrollback_rows().
 *
 * @param terminal The terminal handle (may be NULL)
 * @return Total number of rows
 *
 * @ingroup terminal
 */
size_t ghostty_terminal_total_rows(GhosttyTerminal terminal);

/**
 * Get row metadata for a given screen row.
 *
 * Uses screen coordinates: y=0 is the top of scrollback, the active area
 * starts at y = ghostty_terminal_scrollback_rows().
 *
 * @param terminal The terminal handle (may be NULL)
 * @param y Screen row coordinate (0-indexed)
 * @param row Pointer to store row metadata
 *
 * @ingroup terminal
 */
void ghostty_terminal_get_row(
    GhosttyTerminal terminal,
    size_t y,
    GhosttyTerminalRow *row
);

/**
 * Get cell data for all cells in a screen row.
 *
 * Fills the provided buffer with cell data. The buffer should be at least
 * as large as the terminal width (from ghostty_terminal_get_size()).
 *
 * @param terminal The terminal handle (may be NULL)
 * @param y Screen row coordinate (0-indexed)
 * @param cells Buffer to fill with cell data
 * @param max_cells Maximum number of cells to write
 * @return Number of cells written
 *
 * @ingroup terminal
 */
size_t ghostty_terminal_get_cells(
    GhosttyTerminal terminal,
    size_t y,
    GhosttyTerminalCell *cells,
    size_t max_cells
);

/**
 * Look up style attributes for a given style ID.
 *
 * The style_id comes from GhosttyTerminalCell.style_id. A style_id of 0
 * is the default style (no attributes set). The y coordinate is needed
 * because styles are stored per-page internally.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param y Screen row coordinate (identifies the page for style lookup)
 * @param style_id Style ID from a cell in that row
 * @param style Pointer to store style attributes
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if y is out of range
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_get_style(
    GhosttyTerminal terminal,
    size_t y,
    uint16_t style_id,
    GhosttyTerminalStyle *style
);

/**
 * Get the full codepoint sequence for a cell's grapheme cluster.
 *
 * Returns the primary codepoint followed by any combining/extension
 * codepoints. For simple cells this returns 1 codepoint. For cells with
 * has_grapheme=true, this returns the complete grapheme cluster.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param y Screen row coordinate
 * @param x Column coordinate
 * @param codepoints Buffer to fill with codepoints (as uint32_t)
 * @param max Maximum number of codepoints to write
 * @return Number of codepoints written (0 if cell is empty or out of range)
 *
 * @ingroup terminal
 */
size_t ghostty_terminal_get_grapheme(
    GhosttyTerminal terminal,
    size_t y,
    uint16_t x,
    uint32_t *codepoints,
    size_t max
);

/**
 * Get cursor visibility state.
 *
 * @param terminal The terminal handle (may be NULL)
 * @return true if the cursor is visible (DEC mode 25)
 *
 * @ingroup terminal
 */
bool ghostty_terminal_get_cursor_visible(GhosttyTerminal terminal);

/**
 * Query whether a DEC private mode or ANSI mode is currently set.
 *
 * The mode parameter is the raw mode number (e.g., 1049 for alt screen,
 * 2004 for bracketed paste, 25 for cursor visible). DEC private modes
 * use the plain number; ANSI modes should have bit 15 set (mode | 0x8000).
 *
 * @param terminal The terminal handle (may be NULL)
 * @param mode Mode number to query
 * @return true if the mode is currently set
 *
 * @ingroup terminal
 */
bool ghostty_terminal_is_mode_set(GhosttyTerminal terminal, uint16_t mode);

/**
 * Query whether the alternate screen buffer is active.
 *
 * @param terminal The terminal handle (may be NULL)
 * @return true if alternate screen is active
 *
 * @ingroup terminal
 */
bool ghostty_terminal_is_alt_screen(GhosttyTerminal terminal);

/**
 * Get the current kitty keyboard protocol stack depth.
 *
 * Returns 0 when no push has been done, increments with each push,
 * decrements with each pop.
 *
 * @param terminal The terminal handle (may be NULL)
 * @return Current stack depth
 *
 * @ingroup terminal
 */
uint32_t ghostty_terminal_kitty_keyboard_depth(GhosttyTerminal terminal);

/** @} */

#endif /* GHOSTTY_VT_TERMINAL_H */
