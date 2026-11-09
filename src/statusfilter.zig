//! Filtering of program status reports (OSC 7501) out of what an
//! attached client writes to a terminal that does not take them.
//!
//! The daemon keeps each session's program status, for `pane ls` and the
//! session menu, and sends it on to the attached client. The client asks
//! its terminal whether it takes status reports when it attaches. A
//! terminal that does not answer gets them filtered out, because some
//! print a status report as text instead of ignoring it. VTE 0.52, which
//! CentOS 7's terminals use, is one.
//!
//! Like the alternate-screen filter, this one follows the byte stream
//! with the window parser's state table, so a report ends where the
//! parser ends it: at BEL, at the ESC of an ST or of another sequence, or
//! at CAN or SUB.

const std = @import("std");
const vt = @import("ghostty-vt");
const altscreen = @import("altscreen.zig");

const State = vt.Parser.State;

/// How every status report begins.
const introducer = "\x1b]7501;";

/// Incremental scanner that copies input to a writer, removing every
/// status report. The start of an OSC that may be one is held, across
/// feeds if it is split, until it shows whether it is.
pub const Filter = struct {
    /// The parser's state after the bytes scanned so far.
    state: State = .ground,
    /// How much of `introducer` is held: the start of a sequence that may
    /// be a status report. Zero while there is none.
    held_len: usize = 0,
    /// Inside a status report, whose bytes are dropped.
    dropping: bool = false,
    /// The held ESC ended a report, so a `\` after it completes the
    /// report's ST and is dropped too.
    st_pending: bool = false,

    /// Scan `input`, writing everything but status reports to `writer`.
    pub fn feed(
        self: *Filter,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        // Start of the bytes that pass through as they are.
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            const byte = input[i];
            const t = altscreen.transition(self.state, byte);

            if (self.dropping) {
                self.state = t.state;
                i += 1;
                run_start = i;
                if (t.state == .osc_string) continue;
                self.dropping = false;
                // An ESC ends the report, and starts its ST or another
                // sequence.
                if (t.state == .escape) {
                    self.held_len = 1;
                    self.st_pending = true;
                }
                continue;
            }

            if (self.held_len > 0) {
                const st_pending = self.st_pending;
                self.st_pending = false;
                if (st_pending and byte == '\\') {
                    self.held_len = 0;
                    self.state = t.state;
                    i += 1;
                    run_start = i;
                    continue;
                }
                if (introducer[self.held_len] == byte) {
                    self.state = t.state;
                    i += 1;
                    run_start = i;
                    self.held_len += 1;
                    if (self.held_len == introducer.len) {
                        self.held_len = 0;
                        self.dropping = true;
                    }
                    continue;
                }
                // Not a report: the held bytes pass through, and this
                // byte is scanned afresh.
                try writer.writeAll(introducer[0..self.held_len]);
                self.held_len = 0;
                run_start = i;
            }

            self.state = t.state;
            i += 1;
            if (t.state == .escape) {
                try writer.writeAll(input[run_start .. i - 1]);
                run_start = i;
                self.held_len = 1;
            }
        }
        try writer.writeAll(input[run_start..]);
    }
};

fn testFeed(filter: *Filter, input: []const u8, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try filter.feed(input, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "reports are removed whichever way they end" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b]7501;state=working:app=claude-code\x07b", "ab");
    try testFeed(&f, "a\x1b]7501;state=done\x1b\\b", "ab");
    try testFeed(&f, "a\x1b]7501;state=done\x18b", "ab");
}

test "an ESC that cuts a report short starts the next sequence" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b]7501;state=working\x1b[1mx", "\x1b[1mx");
    try testFeed(&f, "\x1b]7501;state=working\x1b]7501;state=done\x07x", "x");
}

test "a report split across feeds is removed" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b]75", "a");
    try testFeed(&f, "01;state=work", "");
    try testFeed(&f, "ing\x1b", "");
    try testFeed(&f, "\\b", "b");
}

test "other sequences and text pass through" {
    var f: Filter = .{};
    const other = "\x1b]2;title\x07\x1b]75010;x\x07\x1b]750;x\x07\x1b[31m\x1b\x1b]11;?\x07text";
    try testFeed(&f, other, other);
}

test "a held prefix that turns out ordinary passes through in order" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b]750", "a");
    try testFeed(&f, "9;x\x07b", "\x1b]7509;x\x07b");
}
