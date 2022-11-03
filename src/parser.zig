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
    Space: u32,
    SoftBreak,
    ParagraphBreak,
    Link: struct {
        type: LinkType,
        content: []Token,
    },
    UnclosedAttachedModifier: struct {
        isOpening: bool,
        char: u8,
    },
    AttachedModifier: AttachedModifier,
};

pub const NeedsMoreData = error{UnclosedLink};

pub fn parse(alloc: *std.heap.ArenaAllocator, input: []const u8, simpleTokens: []tokenizer.SimpleToken) ![]Token {
    var allocator = alloc.allocator();

    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: u64 = 0;
    var start: u64 = 0;

    const UnclosedAttachedModifier = struct {
        attachedModifier: AttachedModifier,
        index: u64,
        start: u64,
    };

    var unclosedAttachedModifierMap = std.AutoHashMap(u8, std.ArrayList(UnclosedAttachedModifier)).init(allocator);
    defer unclosedAttachedModifierMap.deinit();

    while (i < simpleTokens.len) : (i += 1) {
        const current = simpleTokens[i];

        start = i;

        try tokens.append(switch (current.type) {
            .Character => b: {
                // Count for as long as we encounter other characters
                while ((i + 1) < simpleTokens.len and simpleTokens[i + 1].type == .Character)
                    i += 1;

                break :b Token{
                    .range = .{
                        .start = start,
                        .end = i + 1, // Indexing is end-exclusive, hence the `+ 1`
                    },

                    .data = .{ .Word = input[start .. i + 1] },
                };
            },
            .Space => b: {
                while ((i + 1) < simpleTokens.len and simpleTokens[i + 1].type == .Space)
                    i += 1;

                break :b Token{
                    .range = .{
                        .start = start,
                        .end = i + 1,
                    },

                    .data = .{
                        .Space = @truncate(u32, i - start + 1),
                    },
                };
            },
            .Newline => b: {
                var is_paragraph_break: bool = (i + 1) < simpleTokens.len and simpleTokens[i + 1].type == .Newline;

                if (is_paragraph_break) {
                    i += 1;

                    // Go through every attached modifier and clear it.
                    var attachedModIterator = unclosedAttachedModifierMap.iterator();

                    while (attachedModIterator.next()) |kv|
                        kv.value_ptr.clearAndFree();
                }

                break :b Token{
                    .range = .{
                        .start = start,
                        .end = i + 1,
                    },

                    .data = if (is_paragraph_break) .ParagraphBreak else .SoftBreak,
                };
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

                var unclosedAttachedMods = (try unclosedAttachedModifierMap.getOrPutValue(current.char, std.ArrayList(UnclosedAttachedModifier).init(allocator))).value_ptr;

                if (can_be_attached_modifier and can_be_opening_modifier) {
                    try unclosedAttachedMods.append(.{
                        .attachedModifier = .{
                            .char = current.char,
                            .type = .Bold, // TODO: Make dynamic
                            .content = undefined,
                        },
                        .index = tokens.items.len,
                        .start = start,
                    });

                    break :b Token{
                        .range = .{
                            .start = start,
                            .end = start + 1,
                        },
                        .data = .{
                            .UnclosedAttachedModifier = .{
                                .isOpening = true,
                                .char = current.char,
                            },
                        },
                    };
                } else if (can_be_attached_modifier and can_be_closing_modifier and unclosedAttachedMods.items.len > 0) {
                    var attached_modifier_opener = unclosedAttachedMods.orderedRemove(0);
                    var attached_modifier_content = try allocator.alloc(Token, tokens.items.len - attached_modifier_opener.index - 1);
                    std.mem.copy(Token, attached_modifier_content, tokens.items[attached_modifier_opener.index + 1 .. tokens.items.len]);

                    try tokens.replaceRange(attached_modifier_opener.index, tokens.items.len - attached_modifier_opener.index, &[_]Token{
                        Token{
                            .range = .{
                                .start = attached_modifier_opener.start,
                                .end = i,
                            },
                            .data = .{
                                .AttachedModifier = .{
                                    .char = current.char,
                                    .type = .Bold, // TODO: make this dynamic
                                    .content = attached_modifier_content,
                                },
                            },
                        },
                    });
                } else {
                    // If the thing cannot be an attached mod then try merge it with the previous word
                    // or create a new Word object
                    var prev = &tokens.items[tokens.items.len - 1];

                    switch (prev.data) {
                        .Word => |*word| {
                            prev.range.end += 1;
                            word.* = input[prev.range.start..prev.range.end];
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

                continue;
            },

            else => continue,
        });
    }

    var iter = unclosedAttachedModifierMap.iterator();

    while (iter.next()) |kv|
        kv.value_ptr.deinit();

    return tokens.toOwnedSlice();
}

// -----------------------------------------------------------------------

fn testInput(input: []const u8, comptime size: comptime_int, comptime expected: [size]Token) !void {
    const simpleTokens = try tokenizer.tokenize(testing.allocator, input);
    defer testing.allocator.free(simpleTokens);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tokens = try parse(&arena, input, simpleTokens);

    var i: u64 = 0;

    while (i < tokens.len) : (i += 1) {
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
