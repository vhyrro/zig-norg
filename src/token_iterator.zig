/// A struct designed to efficiently iterate over a structure of items
const std = @import("std");

pub fn TokenIterator(Token: type) type {
    if (comptime std.meta.hasField(Token, "type"))
        @compileError("What");

    const TokenType: type = @TypeOf(Token.type);

    return struct {
        container: []Token,
        index: u64,

        const Self = @This();

        pub fn from(tokens: []Token) Self {
            return .{
                .container = tokens,
                .index = 0,
            };
        }

        pub fn current(self: Self) Token {
            if (self.index >= self.container.len)
                @panic("Index value for iterator exceeds the length of the container. Did you manually mutate the value?");

            return self.container[self.index];
        }

        pub fn next(self: Self) ?Token {
            if (self.index >= self.container.len)
                return null;

            defer self.index += 1;
            return self.container[self.index];
        }

        pub fn nextWithType(self: Self, tokenType: TokenType) ?Token {
            if (self.next()) |next| {
                return if (next.type == tokenType) next else null;
            } else return null;
        }

        pub fn peek(self: Self) ?Token {
            return if (self.index + 1 < self.container.len) self.container[self.index + 1] else null;
        }

        pub fn rest(self: Self) []Token {
            return self.container[self.index..];
        }

        pub fn container(self: Self) []Token {
            return self.container;
        }
    };
}
