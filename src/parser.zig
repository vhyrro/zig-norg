const std = @import("std");
const testing = std.testing;
const tokenizer = @import("tokenizer.zig");

pub const Token = struct {
    range: struct {
        start: u64,
        end: u64,
    },

    data: TokenData,
};

pub const LinkType = enum {
    URL,
};

pub const AttachedModifierType = enum {
Bold,
Italic,
};

pub const TokenData = union(enum) {
    Word: []const u8,
    Space: u32,
    SoftBreak,
    ParagraphBreak,
    Link: struct {
        type: LinkType,
        content: []const u8,
    },
    AttachedModifier: struct {
        char: u8,
        type: AttachedModifierType,
        content: []const u8,
    },
};

pub const ParseError = error{NeedsMoreData};

pub fn parse(allocator: std.mem.Allocator, input: []const u8, simpleTokens: []tokenizer.SimpleToken) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: u64 = 0;
    var start: u64 = 0;

    while (i < simpleTokens.len) : (i += 1) {
        const current = simpleTokens[i];

        start = i;
        switch (current.type) {
            .Character => {
                while ((i + 1) < simpleTokens.len and simpleTokens[i + 1].type == .Character)
                    i += 1;

                try tokens.append(.{
                    .range = .{
                        .start = start,
                        .end = i + 1,
                    },

                    .data = .{ .Word = input[start..i + 1] },
                });
            },
            .Space => {
                while ((i + 1) < simpleTokens.len and simpleTokens[i + 1].type == .Space)
                    i += 1;

                try tokens.append(.{
                    .range = .{
                        .start = start,
                        .end = i + 1,
                    },

                    .data = .{ .Space = @truncate(u32, i - start + 1), },
                });
            },
            .Newline => {
                var is_paragraph_break: bool = (i + 1) < simpleTokens.len and simpleTokens[i + 1].type == .Newline;

                if (is_paragraph_break)
                    i += 1;

                try tokens.append(.{
                    .range = .{
                        .start = start,
                        .end = i + 1,
                    },

                    .data = if (is_paragraph_break) .ParagraphBreak else .SoftBreak,
                });
            },
            else => {},
        }
    }

    return tokens.toOwnedSlice();
}

test "Parse sample text" {
    const input = 
    \\What's up
    \\beijing.
    ;

    const simpleTokens = try tokenizer.tokenize(testing.allocator, input);
    const tokens = try parse(testing.allocator, input, simpleTokens);

    // TODO: fix test

    testing.allocator.free(simpleTokens);
    testing.allocator.free(tokens);
}
