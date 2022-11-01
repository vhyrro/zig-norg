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
        content: []const u8,
    },
    AttachedModifier: AttachedModifier,
};

pub const ParseError = error{NeedsMoreData};

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

    var is_on_new_line: bool = true;

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

                    .data = .{ .Word = input[start .. i + 1] },
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

                    .data = .{
                        .Space = @truncate(u32, i - start + 1),
                    },
                });
            },
            .Newline => {
                var is_paragraph_break: bool = (i + 1) < simpleTokens.len and simpleTokens[i + 1].type == .Newline;

                if (is_paragraph_break) {
                    i += 1;

                    // Go through every attached modifier and clear it.
                    var attachedModIterator = unclosedAttachedModifierMap.iterator();

                    while (attachedModIterator.next()) |kv|
                        kv.value_ptr.clearAndFree();
                }

                try tokens.append(.{
                    .range = .{
                        .start = start,
                        .end = i + 1,
                    },

                    .data = if (is_paragraph_break) .ParagraphBreak else .SoftBreak,
                });

                is_on_new_line = true;
                continue;
            },
            .Special => {
                // Check for attached modifiers
                const can_be_attached_modifier: bool = b: {
                    if (i + 1 < simpleTokens.len)
                        break :b simpleTokens[i + 1].char != current.char
                    else
                        break :b true;
                };

                const can_be_opening_modifier: bool = b: {
                    if (i == 0)
                        break :b true
                    else {
                        const prev = simpleTokens[i - 1];
                        break :b prev.type == .Space or prev.type == .Newline or utils.isPunctuation(prev.char);
                    }
                };

                const can_be_closing_modifier: bool = b: {
                    if (i + 1 < simpleTokens.len) {
                        const next = simpleTokens[i + 1];
                        break :b (next.type == .Space or next.type == .Newline or utils.isPunctuation(next.char));
                    } else break :b true;
                };

                var unclosedAttachedMods = (try unclosedAttachedModifierMap.getOrPutValue(current.char, std.ArrayList(UnclosedAttachedModifier).init(allocator))).value_ptr;

                if (can_be_attached_modifier and can_be_opening_modifier)
                    try unclosedAttachedMods.append(.{
                        .attachedModifier = .{
                            .char = current.char,
                            .type = .Bold, // TODO: Make dynamic
                            .content = undefined,
                        },
                        .index = tokens.items.len,
                        .start = start,
                    })
                else if (can_be_attached_modifier and can_be_closing_modifier and unclosedAttachedMods.items.len > 0) {
                    var attached_modifier_opener = unclosedAttachedMods.orderedRemove(0);
                    var attached_modifier_content = try allocator.alloc(Token, tokens.items.len - attached_modifier_opener.index);
                    std.mem.copy(Token, attached_modifier_content, tokens.items[attached_modifier_opener.index..tokens.items.len]);

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
                }
            },
            else => {},
        }

        is_on_new_line = false;
    }

    var iter = unclosedAttachedModifierMap.iterator();

    while (iter.next()) |kv| {
        for (kv.value_ptr.items) |unclosedModifier|
            tokens.items[unclosedModifier.index].data = .{ .Word = &.{unclosedModifier.attachedModifier.char} };

        kv.value_ptr.deinit();
    }

    return tokens.toOwnedSlice();
}

test "Parse sample text" {
    // TODO: `,*up*` doesn't work because `,` is unclosed.
    // TODO: Test */this/*.
    // TODO: *Hello World!* doesn't work
    const input =
        \\What's *up
        \\
        \\beijing*.
        \\*Hi world*.
    ;

    const simpleTokens = try tokenizer.tokenize(testing.allocator, input);
    defer testing.allocator.free(simpleTokens);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tokens = try parse(&arena, input, simpleTokens);

    for (tokens) |token|
        switch (token.data) {
            .AttachedModifier => |data| std.debug.print("{any}\n\n", .{data.content}),
            else => {},
        };

    std.debug.print("{any}\n\n", .{tokens});
}
