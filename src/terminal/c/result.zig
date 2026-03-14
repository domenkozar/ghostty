/// C: GhosttyResult
pub const Result = enum(c_int) {
    success = 0,
    out_of_memory = -1,
    invalid_value = -2,
    io_error = -3,
};
