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

pub const StructuralDetachedModifierType = enum {
    Heading,
};

pub const EscapeSequenceType = union(enum) {
    Regular: u8,
    TrailingModifier,
};

pub const TokenType = union(enum) {
    Word: []const u8,
    Space,
    SoftBreak,
    ParagraphBreak,
    // TODO: Implement this behaviour
    Link: struct {
        type: LinkType,
    },
    AttachedModifier: struct {
        isOpening: bool,
        closingModifierIndex: ?u64,
        char: u8,
    },

    StructuralDetachedModifier: struct {
        type: StructuralDetachedModifierType,
        level: u16,
    },
    EscapeSequence: EscapeSequenceType,
};

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

fn parseStructuralDetachedModifier(iterator: *TokenIterator) ?Token {
    if (!iterator.isNewLine)
        return null;

    // TODO: At some distant point in the future prevent backtracking from this restore point
    // and implement an O(n) recovery system
    const restorePoint = iterator.index;

    const currentType = iterator.current().?.type;

    var level: u16 = 1;

    while (iterator.nextWithType(currentType)) |_|
        level += 1;

    const next = iterator.peekNext() orelse {
        iterator.index = restorePoint;
        return null;
    };

    if (next.type == .Space) {
        return .{
            .range = .{
                .start = if (restorePoint == 0) restorePoint else restorePoint - 1,
                    .end = iterator.index,
            },

            .type = .{
                .StructuralDetachedModifier = .{
                    .type = .Heading, // TODO: Don't hardcode this
                    .level = level,
                },
            },
        };
    } else {
        iterator.index = restorePoint;
        return null;
    }
}

fn parseEscapeSequence(iterator: *TokenIterator) !Token {
    const start = iterator.position();
    const next = iterator.next() orelse return NeedsMoreData.MissingCharAfterBackslash;

    return .{
        .range = .{
            .start = start,
            .end = iterator.position() + 1,
        },

        .type = .{
            .EscapeSequence = if (next.type == .Newline) .TrailingModifier else .{
                .Regular = next.char,
            },
        },
    };
}

pub const NeedsMoreData = error {
    MissingCharAfterBackslash
};

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
            .Escape => try parseEscapeSequence(&iterator),
            .Special =>
            parseStructuralDetachedModifier(&iterator)
            orelse try parseAttachedModifier(&iterator, &unclosedAttachedModifierMap, tokens.items)
            orelse b: {
                const currentChar = iterator.current().?.char;
                const start = iterator.position();

                while (iterator.nextWithChar(currentChar)) |_| {}

                const end = start + (iterator.position() - start) + 1;

                break :b Token{
                    .range = .{
                        .start = start,
                        .end = end,
                    },

                    .type = .{
                        .Word = input[start .. end],
                    },
                };
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
            std.debug.print("Start ranges do not match at index {}. Expected {}, got {}.\nReceived token: {any}\n", .{ i, exp.range.start, in.range.start, in });
            return err;
        };

        testing.expect(in.range.end == exp.range.end) catch |err| {
            std.debug.print("End ranges do not match at index {}. Expected {}, got {}.\nReceived token: {any}\n", .{ i, exp.range.end, in.range.end, in });
            return err;
        };

        // TODO: Why is this erroring on two identical strings?
        // testing.expectEqual(in.type, exp.type) catch |err| {
        //     std.debug.print("Structs do not match at index {}. Expected {any}, got {any}.\n", .{ i, exp.type, in.type });
        //     return err;
        // };
    }
}

fn t(comptime start: u64, comptime end: u64, comptime tokenType: TokenType) Token {
    return .{
        .range = .{
            .start = start,
            .end = end,
        },

        .type = tokenType,
    };
}

fn word(comptime start: u64, comptime end: u64, comptime content: []const u8) Token {
    return t(start, end, .{ .Word = content });
}

fn space(comptime start: u64, comptime end: u64) Token {
    return t(start, end, .Space);
}

fn attMod(comptime start: u64, comptime opening: bool, comptime char: u8) Token {
    return t(start, start + 1, .{
        .AttachedModifier = .{
            .isOpening = opening,
            .closingModifierIndex = null,
            .char = char,
        },
    });
}

fn esc(comptime start: u64, comptime escapedChar: u8) Token {
    return t(start, start + 2, .{
        .EscapeSequence = if (escapedChar == '\n') .TrailingModifier else .{
            .Regular = escapedChar,
        },
    });
}

test "Parse regular sample text" {
    const input = "Hello\n\n";

    try testInput(input, 2, [2]Token{
        word(0, 5, "Hello"),
        t(5, 7, .ParagraphBreak),
    });
}

test "Parse multi-line text" {
    const input =
        \\Hello
        \\world!
    ;

    try testInput(input, 4, [4]Token{
        word(0, 5, "Hello"),
        t(5, 6, .SoftBreak),
        word(6, 11, "world"),
        attMod(11, true, '!'),
    });
}

test "Headings" {
    const input =
        \\ * Hello World
    ;

    try testInput(input, 6, [6]Token{
        space(0, 1),
        t(1, 2, .{
            .StructuralDetachedModifier = .{
                .type = .Heading,
                .level = 1,
            },
        }),
        space(2, 3),
        word(3, 8, "Hello"),
        space(8, 9),
        word(9, 14, "world"),
    });
}

test "Headings after paragraphs" {
    const input =
        \\Some text!
        \\* Hello World
        \\  Content.
    ;

    try testInput(input, 13, [13]Token{
        word(0, 4, "Some"),
        space(4, 5),
        word(5, 9, "text"),
        attMod(9, true, '!'),
        t(10, 11, .SoftBreak),
        t(11, 12, .{
            .StructuralDetachedModifier = .{
                .type = .Heading,
                .level = 1,
            },
        }),
        space(12, 13),
        word(13, 18, "Hello"),
        space(18, 19),
        word(19, 24, "world"),
        t(24, 25, .SoftBreak),
        space(25, 27),
        word(27, 35, "Content."),
    });
}

test "Multi-level headings" {
    const input =
        \\** Nested
        \\******** Loooong
    ;

    try testInput(input, 7, [7]Token{
        t(0, 2, .{
            .StructuralDetachedModifier = .{
                .type = .Heading,
                .level = 2,
            },
        }),
        space(2, 3),
        word(3, 9, "Nested"),
        t(9, 10, .SoftBreak),
        t(10, 18, .{
            .StructuralDetachedModifier = .{
                .type = .Heading,
                .level = 8,
            },
        }),
        space(18, 19),
        word(19, 26, "Loooong"),
    });
}

test "Escape Sequences" {
    const input =
        \\Some \text.
        \\\* NotAHeading
        \\***\ AlsoNotAHeading
    ;

    try testInput(input, 12, [12]Token{
        word(0, 4, "Some"),
        space(4, 5),
        esc(5, 't'),
        word(7, 11, "ext."),
        t(11, 12, .SoftBreak),
        esc(12, '*'),
        space(14, 15),
        word(15, 26, "NotAHeading"),
        t(26, 27, .SoftBreak),
        word(27, 30, "***"),
        esc(30, ' '),
        word(32, 47, "AlsoNotAHeading"),
    });
}

// TODO: Tests for attached modifiers
