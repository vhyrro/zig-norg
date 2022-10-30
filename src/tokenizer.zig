const std = @import("std");
const testing = std.testing;

pub const SimpleTokenType = union(enum) {
    Character,
    Space,
    Newline,
    Special,
    LinkOpen,
    LinkClose,
};

pub const SimpleToken = struct {
    type: SimpleTokenType,
    char: u8,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]SimpleToken {
    var tokens = std.ArrayList(SimpleToken).init(allocator);
    errdefer tokens.deinit();

    var i: u64 = 0;

    while (i < input.len) : (i += 1) {
        try tokens.append(.{
            .type = switch (input[i]) {
                '\t', ' ' => .Space,
                '\n' => .Newline,
                '*', '/', '_', '^', ',', '-', '%' => .Special,
                '{' => .LinkOpen,
                '}' => .LinkClose,
                else => .Character,
            },
            .char = input[i],
        });
    }

    return tokens.toOwnedSlice();
}

test "Simple parse" {
    const input = "*Hello* {world}!";

    const output = try parse(testing.allocator, input);

    try testing.expectEqualSlices(SimpleToken, output, &[_]SimpleToken {
        .{ .type = .Special, .char = '*' },
        .{ .type = .Character, .char = 'H' },
        .{ .type = .Character, .char = 'e' },
        .{ .type = .Character, .char = 'l' },
        .{ .type = .Character, .char = 'l' },
        .{ .type = .Character, .char = 'o' },
        .{ .type = .Special, .char = '*' },
        .{ .type = .Space, .char = ' ' },
        .{ .type = .LinkOpen, .char = '{' },
        .{ .type = .Character, .char = 'w' },
        .{ .type = .Character, .char = 'o' },
        .{ .type = .Character, .char = 'r' },
        .{ .type = .Character, .char = 'l' },
        .{ .type = .Character, .char = 'd' },
        .{ .type = .LinkClose, .char = '}' },
        .{ .type = .Character, .char = '!' },
    });

    testing.allocator.free(output);
}
