/**
 * @file host.h
 *
 * Host terminal control: raw mode and terminal size queries.
 */

#ifndef GHOSTTY_VT_HOST_H
#define GHOSTTY_VT_HOST_H

#include <stdint.h>
#include <ghostty/vt/result.h>

/** @defgroup host Host Terminal Control
 *
 * Functions for controlling the host terminal (the terminal that the
 * application is running inside of, as opposed to the emulated terminal).
 *
 * These provide raw mode toggling and terminal size queries on POSIX
 * file descriptors.
 *
 * @{
 */

/**
 * Enable raw mode on a terminal file descriptor.
 *
 * Saves the current termios state and configures the fd for raw input:
 * disables echo, canonical mode, signal generation, and output processing.
 * The original state can be restored with ghostty_host_disable_raw_mode().
 *
 * @param fd The terminal file descriptor
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_IO_ERROR on failure
 *
 * @ingroup host
 */
GhosttyResult ghostty_host_enable_raw_mode(int fd);

/**
 * Disable raw mode on a terminal file descriptor.
 *
 * Restores the termios state saved by a previous call to
 * ghostty_host_enable_raw_mode() on the same fd.
 *
 * @param fd The terminal file descriptor
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_IO_ERROR on failure
 *
 * @ingroup host
 */
GhosttyResult ghostty_host_disable_raw_mode(int fd);

/**
 * Get the size of a terminal.
 *
 * @param fd   The terminal file descriptor
 * @param cols Pointer to store the number of columns
 * @param rows Pointer to store the number of rows
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_IO_ERROR on failure
 *
 * @ingroup host
 */
GhosttyResult ghostty_host_get_size(int fd, uint16_t *cols, uint16_t *rows);

/** @} */

#endif /* GHOSTTY_VT_HOST_H */
