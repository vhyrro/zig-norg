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

pub fn parse(allocator: std.mem.Allocator, input: []const u8, simpleTokens: []tokenizer.SimpleToken) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: u64 = 0;
    var start: u64 = 0;

    const UnclosedAttachedModifier = struct {
        attachedModifier: AttachedModifier,
        index: u64,
        start: u64,
    };

    var states = std.AutoHashMap(u8, std.ArrayList(UnclosedAttachedModifier)).init(allocator);
    defer states.deinit();

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

                if (is_paragraph_break)
                    i += 1;

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
                const can_be_attached_modifier: bool = (i + 1 < simpleTokens.len) and (simpleTokens[i + 1].char != current.char);
                const can_be_opening_modifier: bool = i > 0 and (simpleTokens[i - 1].type == .Space or simpleTokens[i - 1].type == .Newline);
                const can_be_closing_modifier: bool = i + 1 < simpleTokens.len and (simpleTokens[i + 1].type == .Space or simpleTokens[i + 1].type == .Newline);

                var unclosedAttachedMods = (try states.getOrPutValue(current.char, std.ArrayList(UnclosedAttachedModifier).init(allocator))).value_ptr;

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
                    var attached_modifier_content = tokens.items[attached_modifier_opener.index..tokens.items.len];

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
                                    .content = attached_modifier_content, // <- Does this work? Or does the memory get freed?
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

    var iter = states.iterator();

    while (iter.next()) |kv| {
        for (kv.value_ptr.items) |unclosedModifier|
            tokens.items[unclosedModifier.index].data = .{ .Word = &.{unclosedModifier.attachedModifier.char} };

        kv.value_ptr.deinit();
    }

    return tokens.toOwnedSlice();
}

test "Parse sample text" {
    const input =
        \\What's *up*
        \\beijing.
    ;

    const simpleTokens = try tokenizer.tokenize(testing.allocator, input);
    const tokens = try parse(testing.allocator, input, simpleTokens);

    // TODO: fix test
    std.debug.print("{any}\n\n", .{tokens});

    testing.allocator.free(simpleTokens);
    testing.allocator.free(tokens);
}
