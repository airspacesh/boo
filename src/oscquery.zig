//! Filtering of the queries the daemon answers itself out of a window's
//! output stream.
//!
//! Applications detect the terminal's light/dark theme by querying the
//! background color with OSC 11 (`ESC ] 11 ; ? BEL`). Inside a pane
//! session the real terminal is not reachable: a `pane attach` strips the
//! query along with the alternate-screen tail it rides behind. The
//! daemon therefore answers these queries itself from the background a
//! client reported (see `window.zig`).
//!
//! Programs ask whether the terminal keeps their status with the OSC
//! 7501 support query (`ESC ] 7501 ; ? ESC \`). The daemon keeps it,
//! whatever terminal a client attaches from, so it answers that query
//! too.
//!
//! For each answer to be the only one, the query must not also reach the
//! real terminal, or an attached client would see a duplicate reply land
//! in its input. This filter removes the queries from the passthrough
//! stream and reports each removal so the caller can produce exactly one
//! reply. OSC 10/12 queries and every other sequence pass through
//! unchanged. Candidate sequences split across feeds are carried over to
//! the next call.

const std = @import("std");

/// A query the daemon answers, in each encoding it may arrive in:
/// BEL-terminated (what nvim and most apps send) and ST-terminated
/// (`ESC \`). The reply ends with the query's own terminator.
pub const Query = enum {
    background_bel,
    background_st,
    program_status_bel,
    program_status_st,

    fn bytes(self: Query) []const u8 {
        return switch (self) {
            .background_bel => "\x1b]11;?\x07",
            .background_st => "\x1b]11;?\x1b\\",
            .program_status_bel => "\x1b]7501;?\x07",
            .program_status_st => "\x1b]7501;?\x1b\\",
        };
    }
};

/// How many of each query a feed removed.
pub const Result = std.EnumArray(Query, usize);

const Match = union(enum) { no, partial, complete: Query };

/// Classify `bytes` against every query. An exact match is `complete`,
/// a strict prefix of any is `partial`, and anything else is `no`. No
/// query is a prefix of another.
fn classify(bytes: []const u8) Match {
    var partial = false;
    for (std.enums.values(Query)) |query| {
        const target = query.bytes();
        if (bytes.len > target.len) continue;
        if (!std.mem.eql(u8, target[0..bytes.len], bytes)) continue;
        if (bytes.len == target.len) return .{ .complete = query };
        partial = true;
    }
    return if (partial) .partial else .no;
}

/// Incremental scanner that copies input to a writer, removing every
/// query. Held candidate bytes persist across feeds so a query split over
/// reads is still recognized.
pub const Filter = struct {
    /// Held candidate bytes, always a strict prefix of a query. Empty
    /// when not mid-candidate. The longest prefix is
    /// `ESC ] 7 5 0 1 ; ? ESC` (9 bytes, awaiting the ST `\`).
    buf: [16]u8 = undefined,
    len: usize = 0,

    /// Scan `input`, writing passthrough bytes to `writer` and removing
    /// queries. Reports how many of each were removed.
    pub fn feed(
        self: *Filter,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!Result {
        var result: Result = .initFill(0);
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            const byte = input[i];
            if (self.len == 0) {
                // Ground: only ESC can begin a query candidate.
                if (byte == 0x1b) {
                    try writer.writeAll(input[run_start..i]);
                    self.hold(byte);
                }
                i += 1;
                continue;
            }

            // Mid-candidate: try to extend the held prefix by one byte.
            self.buf[self.len] = byte;
            switch (classify(self.buf[0 .. self.len + 1])) {
                .partial => {
                    self.len += 1;
                    i += 1;
                },
                .complete => |query| {
                    // A full query: drop it. The daemon answers it.
                    self.len = 0;
                    result.getPtr(query).* += 1;
                    i += 1;
                    run_start = i;
                },
                .no => {
                    // The held prefix was ordinary output after all, so
                    // emit it verbatim and reconsider the current byte.
                    // The ESC that ends a prefix like `ESC ] 1 1 ; ? ESC`
                    // may begin the next query instead, so it stays held.
                    const ends_in_esc = self.len > 1 and self.buf[self.len - 1] == 0x1b;
                    const emit_len = if (ends_in_esc) self.len - 1 else self.len;
                    try writer.writeAll(self.buf[0..emit_len]);
                    self.len = 0;
                    if (ends_in_esc) self.hold(0x1b);
                    run_start = i;
                },
            }
        }
        if (self.len == 0) {
            try writer.writeAll(input[run_start..]);
        }
        return result;
    }

    fn hold(self: *Filter, byte: u8) void {
        self.buf[self.len] = byte;
        self.len += 1;
    }
};

fn testFeed(filter: *Filter, input: []const u8, expected: []const u8, queries: usize) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const got = try filter.feed(input, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
    var removed: usize = 0;
    for (got.values) |count| removed += count;
    try std.testing.expectEqual(queries, removed);
}

test "plain text and ordinary sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "hello \x1b[2J\x1b[1;5H\x1b[31mworld", "hello \x1b[2J\x1b[1;5H\x1b[31mworld", 0);
}

test "OSC 11 background query (BEL) is removed" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b]11;?\x07b", "ab", 1);
}

test "OSC 11 background query (ST) is removed" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b]11;?\x1b\\b", "ab", 1);
}

test "query right after an alt-screen switch is removed" {
    // The exact shape nvim/helix emit: enter alt screen, clear, query.
    var f: Filter = .{};
    try testFeed(
        &f,
        "\x1b[?1049h\x1b[H\x1b[2J\x1b]11;?\x07rest",
        "\x1b[?1049h\x1b[H\x1b[2Jrest",
        1,
    );
}

test "OSC 11 set (not a query) passes through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]11;rgb:1234/5678/9abc\x07", "\x1b]11;rgb:1234/5678/9abc\x07", 0);
}

test "OSC 10 and 12 queries pass through" {
    // Only the background query is stripped; foreground/cursor are left
    // for the real terminal to answer as before.
    var f: Filter = .{};
    try testFeed(&f, "\x1b]10;?\x07\x1b]12;?\x07", "\x1b]10;?\x07\x1b]12;?\x07", 0);
}

test "other OSC sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]2;a title\x07text", "\x1b]2;a title\x07text", 0);
}

test "back-to-back queries are both removed" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]11;?\x07\x1b]11;?\x07x", "x", 2);
}

test "query split across feeds is still removed" {
    var f: Filter = .{};
    try testFeed(&f, "before\x1b]11", "before", 0);
    try testFeed(&f, ";?\x07after", "after", 1);
}

test "ST query split before the backslash is still removed" {
    var f: Filter = .{};
    try testFeed(&f, "x\x1b]11;?\x1b", "x", 0);
    try testFeed(&f, "\\y", "y", 1);
}

test "near-miss prefix is emitted verbatim" {
    var f: Filter = .{};
    // ESC ] 1 1 ; X is not a query; nothing is dropped.
    try testFeed(&f, "\x1b]11;X\x07", "\x1b]11;X\x07", 0);
}

test "query right after an unterminated query is removed" {
    // The first query's ST is cut short by the ESC that begins the
    // second, which must not reach the client's terminal.
    var f: Filter = .{};
    try testFeed(&f, "\x1b]11;?\x1b]11;?\x07x", "\x1b]11;?x", 1);
    try testFeed(&f, "\x1b]11;?", "", 0);
    try testFeed(&f, "\x1b]11;?\x07y", "\x1b]11;?y", 1);
}

test "lone ESC then ordinary bytes pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1bMtext", "\x1bMtext", 0);
}

test "OSC 7501 support queries are removed and counted by terminator" {
    var f: Filter = .{};
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const got = try f.feed("a\x1b]7501;?\x1b\\b\x1b]7501;?\x07c\x1b]11;?\x07", &writer);
    try std.testing.expectEqualStrings("abc", writer.buffered());
    try std.testing.expectEqual(1, got.get(.program_status_st));
    try std.testing.expectEqual(1, got.get(.program_status_bel));
    try std.testing.expectEqual(1, got.get(.background_bel));
}

test "OSC 7501 reports pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]7501;state=working\x1b\\", "\x1b]7501;state=working\x1b\\", 0);
}

test "OSC 7501 query split before the backslash is still removed" {
    var f: Filter = .{};
    try testFeed(&f, "x\x1b]7501;?\x1b", "x", 0);
    try testFeed(&f, "\\y", "y", 1);
}
