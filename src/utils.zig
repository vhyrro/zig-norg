const std = @import("std");

// TODO: Make this handle unicode characters too!
pub fn isPunctuation(char: u8) bool {
    return std.ascii.isPunct(char);
}
