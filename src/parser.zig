const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");

const tokenizer = @import("tokenizer.zig");
const TokenIterator = @import("token_iterator.zig").TokenIterator(tokenizer.SimpleToken, tokenizer.SimpleTokenType);

pub const Token = struct {
    range: struct {
        start: u64,
        end: u64,
    },

    type: TokenType,
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

pub const TokenType = union(enum) {
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

fn parseConsecutiveTokens(iterator: *TokenIterator, targetType: tokenizer.SimpleTokenType) Token {
    const start = iterator.position();

    while (iterator.nextWithType(targetType)) |_| {}

    return .{
        .range = .{
            .start = start,
            .end = start + (iterator.position() - start) + 1,
        },

        .type = undefined,
    };
}

fn parseWord(iterator: *TokenIterator, input: []const u8) Token {
    var token = parseConsecutiveTokens(iterator, .Character);

    token.type = .{
        .Word = input[token.range.start..token.range.end],
    };

    return token;
}

fn parseWhitespace(iterator: *TokenIterator) Token {
    var token = parseConsecutiveTokens(iterator, .Space);
    token.type = .Space;

    return token;
}

fn oneOrTwo(iterator: *TokenIterator, oneType: TokenType, twoType: TokenType) Token {
    const begin = iterator.position();
    const typeToMatch = iterator.current().?.type;

    const has_second_match: bool = if (iterator.nextWithType(typeToMatch)) |_| true else false;

    return .{
        .range = .{
            .start = begin,
            .end = begin + (iterator.position() - begin) + 1,
        },

        .type = if (has_second_match) twoType else oneType,
    };
}

fn parseNewline(iterator: *TokenIterator, unclosedAttachedModifierMap: *std.AutoHashMap(u8, std.ArrayList(u64))) Token {
    const result = oneOrTwo(iterator, .SoftBreak, .ParagraphBreak);

    // If we parsed a paragraph break then clear all attached modifiers
    if (result.type == .ParagraphBreak) {
        var iter = unclosedAttachedModifierMap.iterator();

        while (iter.next()) |kv|
            kv.value_ptr.clearAndFree();
    }

    return result;
}

fn parseAttachedModifier(iterator: *TokenIterator, unclosedAttachedModifierMap: *std.AutoHashMap(u8, std.ArrayList(u64)), items: []Token) !?Token {
    const current = iterator.current().?;

    // Check for attached modifiers
    const can_be_attached_modifier: bool = if (iterator.peekNext()) |next| next.char != current.char else true;

    const can_be_opening_modifier: bool = cond: {
        const prev = iterator.peekPrev() orelse break :cond true;
        const next = iterator.peekNext() orelse break :cond true;

        break :cond (prev.type == .Space or prev.type == .Newline or utils.isPunctuation(prev.char)) and next.type == .Character;
    };

    const can_be_closing_modifier: bool = cond: {
        const prev = iterator.peekPrev() orelse break :cond true;
        const next = iterator.peekNext() orelse break :cond true;

        break :cond (next.type == .Space or next.type == .Newline or utils.isPunctuation(next.char)) and prev.type == .Character;
    };

    var unclosedAttachedMods = (try unclosedAttachedModifierMap.getOrPutValue(current.char, std.ArrayList(u64).init(unclosedAttachedModifierMap.allocator))).value_ptr;

    if (can_be_attached_modifier and can_be_opening_modifier) {
        try unclosedAttachedMods.append(items.len);

        return .{
            .range = .{
                .start = iterator.position(),
                .end = iterator.position() + 1,
            },
            .type = .{
                .AttachedModifier = .{
                    .isOpening = true,
                    .closingModifierIndex = null,
                    .char = current.char,
                },
            },
        };
    } else if (can_be_attached_modifier and can_be_closing_modifier) {
        const attachedModifierIndex = if (unclosedAttachedMods.items.len > 0) unclosedAttachedMods.orderedRemove(0) else null;

        return .{
            .range = .{
                .start = iterator.position(),
                .end = iterator.position() + 1,
            },

            .type = .{
                .AttachedModifier = .{
                    .isOpening = false,
                    .closingModifierIndex = attachedModifierIndex,
                    .char = current.char,
                },
            },
        };
    } else return null;
}

pub fn parse(alloc: *std.heap.ArenaAllocator, input: []const u8, simpleTokens: []tokenizer.SimpleToken) ![]Token {
    var allocator = alloc.allocator();

    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    // A hashmap of a character -> indexes into the simpleTokens slice
    var unclosedAttachedModifierMap = std.AutoHashMap(u8, std.ArrayList(u64)).init(allocator);
    defer {
        var iter = unclosedAttachedModifierMap.iterator();

        while (iter.next()) |kv|
            kv.value_ptr.deinit();

        unclosedAttachedModifierMap.deinit();
    }

    var iterator = TokenIterator.from(simpleTokens);

    while (iterator.next()) |current| {
        try tokens.append(switch (current.type) {
            .Character => parseWord(&iterator, input),
            .Space => parseWhitespace(&iterator),
            .Newline => parseNewline(&iterator, &unclosedAttachedModifierMap),
            .Special => try parseAttachedModifier(&iterator, &unclosedAttachedModifierMap, tokens.items) orelse b: {
                // If the thing cannot be an attached mod then try merge it with the previous word
                // or create a new Word object
                var prev = &tokens.items[tokens.items.len - 1];

                switch (prev.type) {
                    .Word => |*word| {
                        prev.range.end += 1;
                        word.* = input[prev.range.start..prev.range.end];
                        continue;
                    },
                    else => {
                        break :b Token{
                            .range = .{
                                .start = iterator.position(),
                                .end = iterator.position() + 1,
                            },

                            .type = .{
                                .Word = input[iterator.position() .. iterator.position() + 1],
                            },
                        };
                    },
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

    if (tokens.len < size) {
        std.debug.print("Not enough tokens were produced! :: {any}\n", .{tokens});
        return error.TestingUnexpectedResult;
    }

    var i: u64 = 0;

    while (i < size) : (i += 1) {
        var in = tokens[i];
        var exp = expected[i];

        testing.expect(in.range.start == exp.range.start) catch |err| {
            std.debug.print("Start ranges do not match at index {}. Expected {}, got {}.\n", .{ i, exp.range.start, in.range.start });
            return err;
        };

        testing.expect(in.range.end == exp.range.end) catch |err| {
            std.debug.print("End ranges do not match at index {}. Expected {}, got {}.\n", .{ i, exp.range.end, in.range.end });
            return err;
        };

        // TODO: Fix
        // try testing.expect(@typeName(@TypeOf(in.type)) == @typeName(@TypeOf(exp.type)));
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
            .type = .{
                .Word = "Hello",
            },
        },
        .{
            .range = .{
                .start = 5,
                .end = 7,
            },
            .type = .ParagraphBreak,
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
            .type = .{
                .Word = "Hello",
            },
        },
        .{
            .range = .{
                .start = 5,
                .end = 6,
            },
            .type = .SoftBreak,
        },
        .{
            .range = .{
                .start = 6,
                .end = 11,
            },
            .type = .{
                .Word = "world",
            },
        },
        .{
            .range = .{
                .start = 11,
                .end = 12,
            },
            .type = .{
                .AttachedModifier = .{
                    .isOpening = false,
                    .closingModifierIndex = null,
                    .char = '!',
                },
            },
        },
    });
}

// TODO: Tests for attached modifiers
