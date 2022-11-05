/// A struct designed to efficiently iterate over a structure of items
const std = @import("std");

pub fn TokenIterator(comptime Token: type, comptime TokenType: type) type {
    if (!@hasField(Token, "type"))
        @compileError("Token struct must have a `type` field!");

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

        pub fn current(self: Self) ?Token {
            if (self.index == 0)
                return null;

            return self.container[self.index - 1];
        }

        pub fn next(self: *Self) ?Token {
            if (self.index >= self.container.len)
                return null;

            defer self.index += 1;
            return self.container[self.index];
        }

        pub fn nextWithType(self: *Self, tokenType: TokenType) ?Token {
            if (self.peekNext()) |nextToken| {
                return if (nextToken.type == tokenType) self.next() else null;
            } else return null;
        }

        pub fn peekNext(self: Self) ?Token {
            return if (self.index < self.container.len) self.container[self.index] else null;
        }

        pub fn peekPrev(self: Self) ?Token {
            return if (self.index > 1) self.container[self.index - 2] else null;
        }

        pub fn rest(self: Self) []Token {
            return self.container[self.index..];
        }

        pub fn container(self: Self) []Token {
            return self.container;
        }

        pub fn position(self: Self) u64 {
            return if (self.index == 0) 0 else self.index - 1;
        }
    };
}
