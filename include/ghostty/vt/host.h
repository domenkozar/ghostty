/**
 * @file host.h
 *
 * Host terminal control helpers.
 */

#ifndef GHOSTTY_VT_HOST_H
#define GHOSTTY_VT_HOST_H

#include <stdint.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup host Host Terminal
 *
 * Convenience functions for interacting with the host terminal
 * (raw mode, terminal size queries).
 *
 * @{
 */

/**
 * Enable raw mode on a terminal file descriptor.
 *
 * Saves the current termios state so it can be restored with
 * ghostty_host_disable_raw_mode().
 *
 * @param fd The file descriptor
 * @return GHOSTTY_SUCCESS on success, or an error code
 *
 * @ingroup host
 */
GhosttyResult ghostty_host_enable_raw_mode(int fd);

/**
 * Disable raw mode on a terminal file descriptor.
 *
 * Restores the termios state saved by ghostty_host_enable_raw_mode().
 *
 * @param fd The file descriptor
 * @return GHOSTTY_SUCCESS on success, or an error code
 *
 * @ingroup host
 */
GhosttyResult ghostty_host_disable_raw_mode(int fd);

/**
 * Query the terminal size for a file descriptor.
 *
 * @param fd The file descriptor
 * @param cols Pointer to store the number of columns
 * @param rows Pointer to store the number of rows
 * @return GHOSTTY_SUCCESS on success, or an error code
 *
 * @ingroup host
 */
GhosttyResult ghostty_host_get_size(int fd, uint16_t* cols, uint16_t* rows);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_HOST_H */
