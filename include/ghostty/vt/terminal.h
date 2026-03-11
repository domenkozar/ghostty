/**
 * @file terminal.h
 *
 * Full VT terminal emulator with write/read interface.
 */

#ifndef GHOSTTY_VT_TERMINAL_H
#define GHOSTTY_VT_TERMINAL_H

#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/result.h>
#include <ghostty/vt/allocator.h>

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

/** @} */

#endif /* GHOSTTY_VT_TERMINAL_H */
