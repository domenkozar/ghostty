/**
 * @file action.h
 *
 * Action tag constants for VT sequence callbacks.
 *
 * These values match the action parameter passed to GhosttySequenceCallback.
 * They correspond to the Action.Key enum in the ghostty terminal stream.
 */

#ifndef GHOSTTY_VT_ACTION_H
#define GHOSTTY_VT_ACTION_H

#define GHOSTTY_ACTION_PRINT                         0
#define GHOSTTY_ACTION_PRINT_REPEAT                  1
#define GHOSTTY_ACTION_BELL                          2
#define GHOSTTY_ACTION_BACKSPACE                     3
#define GHOSTTY_ACTION_HORIZONTAL_TAB                4
#define GHOSTTY_ACTION_HORIZONTAL_TAB_BACK           5
#define GHOSTTY_ACTION_LINEFEED                      6
#define GHOSTTY_ACTION_CARRIAGE_RETURN               7
#define GHOSTTY_ACTION_ENQUIRY                       8
#define GHOSTTY_ACTION_INVOKE_CHARSET                9
#define GHOSTTY_ACTION_CURSOR_UP                    10
#define GHOSTTY_ACTION_CURSOR_DOWN                  11
#define GHOSTTY_ACTION_CURSOR_LEFT                  12
#define GHOSTTY_ACTION_CURSOR_RIGHT                 13
#define GHOSTTY_ACTION_CURSOR_COL                   14
#define GHOSTTY_ACTION_CURSOR_ROW                   15
#define GHOSTTY_ACTION_CURSOR_COL_RELATIVE          16
#define GHOSTTY_ACTION_CURSOR_ROW_RELATIVE          17
#define GHOSTTY_ACTION_CURSOR_POS                   18
#define GHOSTTY_ACTION_CURSOR_STYLE                 19
#define GHOSTTY_ACTION_ERASE_DISPLAY_BELOW          20
#define GHOSTTY_ACTION_ERASE_DISPLAY_ABOVE          21
#define GHOSTTY_ACTION_ERASE_DISPLAY_COMPLETE       22
#define GHOSTTY_ACTION_ERASE_DISPLAY_SCROLLBACK     23
#define GHOSTTY_ACTION_ERASE_DISPLAY_SCROLL_COMPLETE 24
#define GHOSTTY_ACTION_ERASE_LINE_RIGHT             25
#define GHOSTTY_ACTION_ERASE_LINE_LEFT              26
#define GHOSTTY_ACTION_ERASE_LINE_COMPLETE          27
#define GHOSTTY_ACTION_ERASE_LINE_RIGHT_UNLESS_PENDING_WRAP 28
#define GHOSTTY_ACTION_DELETE_CHARS                  29
#define GHOSTTY_ACTION_ERASE_CHARS                  30
#define GHOSTTY_ACTION_INSERT_LINES                 31
#define GHOSTTY_ACTION_INSERT_BLANKS                32
#define GHOSTTY_ACTION_DELETE_LINES                 33
#define GHOSTTY_ACTION_SCROLL_UP                    34
#define GHOSTTY_ACTION_SCROLL_DOWN                  35
#define GHOSTTY_ACTION_TAB_CLEAR_CURRENT            36
#define GHOSTTY_ACTION_TAB_CLEAR_ALL                37
#define GHOSTTY_ACTION_TAB_SET                      38
#define GHOSTTY_ACTION_TAB_RESET                    39
#define GHOSTTY_ACTION_INDEX                        40
#define GHOSTTY_ACTION_NEXT_LINE                    41
#define GHOSTTY_ACTION_REVERSE_INDEX                42
#define GHOSTTY_ACTION_FULL_RESET                   43
#define GHOSTTY_ACTION_SET_MODE                     44
#define GHOSTTY_ACTION_RESET_MODE                   45
#define GHOSTTY_ACTION_SAVE_MODE                    46
#define GHOSTTY_ACTION_RESTORE_MODE                 47
#define GHOSTTY_ACTION_REQUEST_MODE                 48
#define GHOSTTY_ACTION_REQUEST_MODE_UNKNOWN         49
#define GHOSTTY_ACTION_TOP_AND_BOTTOM_MARGIN        50
#define GHOSTTY_ACTION_LEFT_AND_RIGHT_MARGIN        51
#define GHOSTTY_ACTION_LEFT_AND_RIGHT_MARGIN_AMBIGUOUS 52
#define GHOSTTY_ACTION_SAVE_CURSOR                  53
#define GHOSTTY_ACTION_RESTORE_CURSOR               54
#define GHOSTTY_ACTION_MODIFY_KEY_FORMAT            55
#define GHOSTTY_ACTION_MOUSE_SHIFT_CAPTURE          56
#define GHOSTTY_ACTION_PROTECTED_MODE_OFF           57
#define GHOSTTY_ACTION_PROTECTED_MODE_ISO           58
#define GHOSTTY_ACTION_PROTECTED_MODE_DEC           59
#define GHOSTTY_ACTION_SIZE_REPORT                  60
#define GHOSTTY_ACTION_TITLE_PUSH                   61
#define GHOSTTY_ACTION_TITLE_POP                    62
#define GHOSTTY_ACTION_XTVERSION                    63
#define GHOSTTY_ACTION_DEVICE_ATTRIBUTES            64
#define GHOSTTY_ACTION_DEVICE_STATUS                65
#define GHOSTTY_ACTION_KITTY_KEYBOARD_QUERY         66
#define GHOSTTY_ACTION_KITTY_KEYBOARD_PUSH          67
#define GHOSTTY_ACTION_KITTY_KEYBOARD_POP           68
#define GHOSTTY_ACTION_KITTY_KEYBOARD_SET           69
#define GHOSTTY_ACTION_KITTY_KEYBOARD_SET_OR        70
#define GHOSTTY_ACTION_KITTY_KEYBOARD_SET_NOT       71
#define GHOSTTY_ACTION_DCS_HOOK                     72
#define GHOSTTY_ACTION_DCS_PUT                      73
#define GHOSTTY_ACTION_DCS_UNHOOK                   74
#define GHOSTTY_ACTION_APC_START                    75
#define GHOSTTY_ACTION_APC_END                      76
#define GHOSTTY_ACTION_APC_PUT                      77
#define GHOSTTY_ACTION_END_HYPERLINK                78
#define GHOSTTY_ACTION_ACTIVE_STATUS_DISPLAY        79
#define GHOSTTY_ACTION_DECALN                       80
#define GHOSTTY_ACTION_WINDOW_TITLE                 81
#define GHOSTTY_ACTION_REPORT_PWD                   82
#define GHOSTTY_ACTION_SHOW_DESKTOP_NOTIFICATION    83
#define GHOSTTY_ACTION_PROGRESS_REPORT              84
#define GHOSTTY_ACTION_START_HYPERLINK              85
#define GHOSTTY_ACTION_CLIPBOARD_CONTENTS           86
#define GHOSTTY_ACTION_MOUSE_SHAPE                  87
#define GHOSTTY_ACTION_CONFIGURE_CHARSET            88
#define GHOSTTY_ACTION_SET_ATTRIBUTE                89
#define GHOSTTY_ACTION_KITTY_COLOR_REPORT           90
#define GHOSTTY_ACTION_COLOR_OPERATION              91
#define GHOSTTY_ACTION_SEMANTIC_PROMPT              92

#endif /* GHOSTTY_VT_ACTION_H */
