const std = @import("std");
const testing = std.testing;
const tokenizer = @import("tokenizer.zig");
const utils = @import("utils.zig");

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
    Underline,
    Superscript,
    Subscript,
    Strikethrough,
    Comment,
    Spoiler,
};

pub const AttachedModifier = struct {
    char: u8,
    type: AttachedModifierType,
    content: []Token,
};

pub const TokenData = union(enum) {
    Word: []const u8,
    Space,
    SoftBreak,
    ParagraphBreak,
    Link: struct {
        type: LinkType,
        content: []Token,
    },
    AttachedModifier: struct {
        isOpening: bool,
        closingModifierIndex: ?u64,
        char: u8,
    },
};

pub const NeedsMoreData = error{UnclosedLink};

// ---------------------------------------------------------------------------------------------------------------

fn parseConsecutiveTokens(increment: *u64, simpleTokens: []tokenizer.SimpleToken, targetType: tokenizer.SimpleTokenType) Token {
    const start = increment.*;

    while ((increment.* + 1) < simpleTokens.len and simpleTokens[increment.* + 1].type == targetType)
        increment.* += 1;

    return .{
        .range = .{
            .start = start,
            .end = increment.* + 1,
        },

        .data = undefined,
    };
}

fn parseWord(increment: *u64, simpleTokens: []tokenizer.SimpleToken, input: []const u8) Token {
    var token = parseConsecutiveTokens(increment, simpleTokens, .Character);

    token.data = .{
        .Word = input[token.range.start..token.range.end],
    };

    return token;
}

fn parseWhitespace(increment: *u64, simpleTokens: []tokenizer.SimpleToken) Token {
    var token = parseConsecutiveTokens(increment, simpleTokens, .Space);
    token.data = .Space;

    return token;
}

fn oneOrTwo(increment: *u64, simpleTokens: []tokenizer.SimpleToken, typeToMatch: tokenizer.SimpleTokenType, oneType: TokenData, twoType: TokenData) Token {
    const has_second_match: bool = (increment.* + 1) < simpleTokens.len and simpleTokens[increment.* + 1].type == toTypeMatch;

    if (has_second_match)
        increment.* += 1;

    return .{
        .range = .{
            .start = start,
            .end = increment.* + 1,
        },

        .data = if (has_second_match) oneType else twoType,
    };
}

pub fn parse(alloc: *std.heap.ArenaAllocator, input: []const u8, simpleTokens: []tokenizer.SimpleToken) ![]Token {
    var allocator = alloc.allocator();

    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: u64 = 0;
    var start: u64 = 0;

    // A hashmap of a character -> indexes into the simpleTokens slice
    var unclosedAttachedModifierMap = std.AutoHashMap(u8, std.ArrayList(u64)).init(allocator);
    defer {
        var iter = unclosedAttachedModifierMap.iterator();

        while (iter.next()) |kv|
            kv.value_ptr.deinit();

        unclosedAttachedModifierMap.deinit();
    }

    while (i < simpleTokens.len) : (i += 1) {
        const current = simpleTokens[i];

        start = i;

        try tokens.append(switch (current.type) {
            // TODO(vhyrro): Instead of passing &i create a custom iterator class that implements
            // peek() functions etc.
            .Character => parseWord(&i, simpleTokens, input),
            .Space => parseWhitespace(&i, simpleTokens),
            .Newline => b: {
                const token = oneOrTwo(&i, simpleTokens, .Newline, .SoftBreak, .ParagraphBreak);

                if (token.type == .ParagraphBreak) {
                    // Go through every attached modifier and clear it.
                    var attachedModIterator = unclosedAttachedModifierMap.iterator();

                    while (attachedModIterator.next()) |kv|
                        kv.value_ptr.clearAndFree();
                }

                break :b token;
            },
            .Special => b: {
                // Check for attached modifiers
                const can_be_attached_modifier: bool = cond: {
                    if (i + 1 < simpleTokens.len)
                        break :cond simpleTokens[i + 1].char != current.char
                    else
                        break :cond true;
                };

                const can_be_opening_modifier: bool = cond: {
                    if (i == 0)
                        break :cond true
                    else {
                        const prev = simpleTokens[i - 1];
                        break :cond (prev.type == .Space or prev.type == .Newline or utils.isPunctuation(prev.char)) and (i + 1 < simpleTokens.len and simpleTokens[i + 1].type == .Character);
                    }
                };

                const can_be_closing_modifier: bool = cond: {
                    if (i + 1 < simpleTokens.len) {
                        const next = simpleTokens[i + 1];
                        break :cond (next.type == .Space or next.type == .Newline or utils.isPunctuation(next.char)) and (i > 0 and simpleTokens[i - 1].type == .Character);
                    } else break :cond true;
                };

                var unclosedAttachedMods = (try unclosedAttachedModifierMap.getOrPutValue(current.char, std.ArrayList(u64).init(allocator))).value_ptr;

                if (can_be_attached_modifier and can_be_opening_modifier) {
                    try unclosedAttachedMods.append(tokens.items.len);

                    break :b Token{
                        .range = .{
                            .start = start,
                            .end = start + 1,
                        },
                        .data = .{
                            .AttachedModifier = .{
                                .isOpening = true,
                                .closingModifierIndex = null,
                                .char = current.char,
                            },
                        },
                    };
                } else if (can_be_attached_modifier and can_be_closing_modifier) {
                    const attachedModifierIndex = if (unclosedAttachedMods.items.len > 0) unclosedAttachedMods.orderedRemove(0) else null;

                    break :b Token{
                        .range = .{
                            .start = start,
                            .end = start + 1,
                        },

                        .data = .{
                            .AttachedModifier = .{
                                .isOpening = false,
                                .closingModifierIndex = attachedModifierIndex,
                                .char = current.char,
                            },
                        },
                    };
                } else { // TODO: verify if this is even needed
                    // If the thing cannot be an attached mod then try merge it with the previous word
                    // or create a new Word object
                    var prev = &tokens.items[tokens.items.len - 1];

                    switch (prev.data) {
                        .Word => |*word| {
                            prev.range.end += 1;
                            word.* = input[prev.range.start..prev.range.end];
                            continue;
                        },
                        else => {
                            break :b Token{
                                .range = .{
                                    .start = start,
                                    .end = start + 1,
                                },

                                .data = .{
                                    .Word = input[start .. start + 1],
                                },
                            };
                        },
                    }
                }
            },

            else => continue,
        });
    }
    return tokens.toOwnedSlice();
}

// -------------------------------------------------------------------------------------------------

fn testInput(input: []const u8, comptime size: comptime_int, comptime expected: [size]Token) !void {
    const simpleTokens = try tokenizer.tokenize(testing.allocator, input);
    defer testing.allocator.free(simpleTokens);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tokens = try parse(&arena, input, simpleTokens);

    var i: u64 = 0;

    while (i < size) : (i += 1) {
        var in = tokens[i];
        var exp = expected[i];

        try testing.expect(in.range.start == exp.range.start);
        try testing.expect(in.range.end == exp.range.end);
        try testing.expect(@typeName(@TypeOf(in.data)) == @typeName(@TypeOf(exp.data)));
    }
}

test "Parse regular sample text" {
    const input = "Hello\n\n";

    try testInput(input, 2, [2]Token{
        .{
            .range = .{
                .start = 0,
                .end = 5,
            },
            .data = .{
                .Word = "Hello",
            },
        },
        .{
            .range = .{
                .start = 5,
                .end = 7,
            },
            .data = .ParagraphBreak,
        },
    });
}

test "Parse multi-line text" {
    const input =
        \\Hello
        \\world!
    ;

    try testInput(input, 4, [4]Token{
        .{
            .range = .{
                .start = 0,
                .end = 5,
            },
            .data = .{
                .Word = "Hello",
            },
        },
        .{
            .range = .{
                .start = 5,
                .end = 6,
            },
            .data = .SoftBreak,
        },
        .{
            .range = .{
                .start = 6,
                .end = 11,
            },
            .data = .{
                .Word = "world",
            },
        },
        .{
            .range = .{
                .start = 11,
                .end = 12,
            },
            .data = .{
                .AttachedModifier = .{
                    .isOpening = false,
                    .closingModifierIndex = null,
                    .char = '!',
                },
            },
        },
    });
}
