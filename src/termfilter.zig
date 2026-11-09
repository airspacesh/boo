//! Filtering of the sequences a client's terminal does not take out of
//! what the client writes to it.
//!
//! A session's programs pick their protocols from the terminal they
//! started under, or from pane's own emulator when they start detached,
//! and the daemon replays the modes they set whenever it repaints. A
//! client can attach from a terminal that lacks some of those protocols,
//! and some terminals print a sequence they do not know as text instead
//! of ignoring it. VTE 0.52, which CentOS 7's terminals use, prints
//! program status reports, kitty keyboard sequences and modifyOtherKeys
//! sequences. The client asks its terminal at attach which of these it
//! takes, and filters out the rest.
//!
//! The filter follows the byte stream with the window parser's state
//! table, so a sequence ends where the parser ends it.

const std = @import("std");
const vt = @import("ghostty-vt");
const altscreen = @import("altscreen.zig");

const State = vt.Parser.State;

/// The protocols a terminal takes, of those a session may use that some
/// terminals print as text.
pub const Supports = struct {
    /// Program status reports (OSC 7501).
    program_status: bool = false,
    /// The kitty keyboard protocol: `CSI = flags ; mode u`, and the push,
    /// pop and query forms `CSI > u`, `CSI < u` and `CSI ? u`.
    kitty_keyboard: bool = false,
    /// xterm's modifyOtherKeys: `CSI > Pp ; Pv m`, and its query
    /// `CSI ? Pp m`.
    modify_other_keys: bool = false,
};

/// How every status report begins.
const status_introducer = "\x1b]7501;";

/// Room for a held sequence. Those the filter removes take under 16
/// bytes, so a longer one passes through.
const held_capacity = 32;

/// Incremental scanner that copies input to a writer, removing the
/// sequences of protocols the terminal does not take. A sequence that
/// may be one of them is held, across feeds if it is split, until it
/// shows whether it is.
pub const Filter = struct {
    supports: Supports,
    /// The parser's state after the bytes scanned so far.
    state: State = .ground,
    /// The sequence being held, from its ESC. Empty while there is none.
    held: [held_capacity]u8 = undefined,
    held_len: usize = 0,
    /// Inside a status report, whose bytes are dropped.
    dropping: bool = false,
    /// The held ESC ended a status report, so a `\` after it completes
    /// the report's ST and is dropped too.
    st_pending: bool = false,

    /// What a byte does to the held sequence.
    const Step = enum {
        /// The byte joins the held sequence.
        hold,
        /// The held sequence is not one to remove, so it passes through,
        /// and the byte is scanned afresh.
        release,
        /// The byte ends a sequence to remove.
        remove,
        /// The byte completes the start of a status report, which is
        /// removed up to its end.
        drop_report,
    };

    /// Scan `input`, writing everything but the removed sequences to
    /// `writer`.
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
                    self.held[0] = byte;
                    self.held_len = 1;
                    self.st_pending = true;
                }
                continue;
            }

            if (self.held_len > 0) {
                const st_pending = self.st_pending;
                self.st_pending = false;
                const next: Step = if (st_pending and byte == '\\') .remove else self.step(byte, t);
                switch (next) {
                    .hold => {
                        self.held[self.held_len] = byte;
                        self.held_len += 1;
                        self.state = t.state;
                        i += 1;
                        run_start = i;
                        continue;
                    },
                    .remove, .drop_report => {
                        self.held_len = 0;
                        self.dropping = next == .drop_report;
                        self.state = t.state;
                        i += 1;
                        run_start = i;
                        continue;
                    },
                    .release => {
                        try writer.writeAll(self.held[0..self.held_len]);
                        self.held_len = 0;
                        run_start = i;
                    },
                }
            }

            self.state = t.state;
            i += 1;
            if (t.state == .escape) {
                try writer.writeAll(input[run_start .. i - 1]);
                run_start = i;
                self.held[0] = byte;
                self.held_len = 1;
            }
        }
        try writer.writeAll(input[run_start..]);
    }

    fn step(self: *const Filter, byte: u8, t: altscreen.Transition) Step {
        const held = self.held[0..self.held_len];
        if (held.len == held_capacity) return .release;
        if (held.len == 1) return switch (byte) {
            ']' => if (self.supports.program_status) .release else .hold,
            '[' => if (self.supports.kitty_keyboard and self.supports.modify_other_keys) .release else .hold,
            else => .release,
        };
        if (held[1] == ']') {
            if (status_introducer[held.len] != byte) return .release;
            return if (held.len + 1 == status_introducer.len) .drop_report else .hold;
        }
        // A CSI. Only one with a private marker may be removed.
        if (held.len == 2) return if (std.mem.indexOfScalar(u8, "<=>?", byte) != null) .hold else .release;
        if (t.action == .csi_dispatch) return if (self.removes(held[2], byte)) .remove else .release;
        if (t.action != .execute and (t.state == .csi_param or t.state == .csi_intermediate)) return .hold;
        return .release;
    }

    /// Whether the CSI with private marker `marker` and final byte
    /// `final` belongs to a protocol the terminal does not take.
    fn removes(self: *const Filter, marker: u8, final: u8) bool {
        return switch (final) {
            'u' => !self.supports.kitty_keyboard,
            'm' => (marker == '>' or marker == '?') and !self.supports.modify_other_keys,
            else => false,
        };
    }
};

fn testFeed(filter: *Filter, input: []const u8, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try filter.feed(input, &writer);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "status reports are removed whichever way they end" {
    var f: Filter = .{ .supports = .{} };
    try testFeed(&f, "a\x1b]7501;state=working:app=claude-code\x07b", "ab");
    try testFeed(&f, "a\x1b]7501;state=done\x1b\\b", "ab");
    try testFeed(&f, "a\x1b]7501;state=done\x18b", "ab");
}

test "an ESC that cuts a status report short starts the next sequence" {
    var f: Filter = .{ .supports = .{ .kitty_keyboard = true, .modify_other_keys = true } };
    try testFeed(&f, "\x1b]7501;state=working\x1b[1mx", "\x1b[1mx");
    try testFeed(&f, "\x1b]7501;state=working\x1b]7501;state=done\x07x", "x");
}

test "a status report split across feeds is removed" {
    var f: Filter = .{ .supports = .{} };
    try testFeed(&f, "a\x1b]75", "a");
    try testFeed(&f, "01;state=work", "");
    try testFeed(&f, "ing\x1b", "");
    try testFeed(&f, "\\b", "b");
}

test "kitty keyboard and modifyOtherKeys sequences are removed" {
    var f: Filter = .{ .supports = .{} };
    try testFeed(&f, "a\x1b[=5;1u\x1b[<u\x1b[>5u\x1b[?u\x1b[>4;2m\x1b[?4mb", "ab");
    // Split inside the parameters.
    try testFeed(&f, "a\x1b[>4", "a");
    try testFeed(&f, ";2mb", "b");
}

test "other sequences and text pass through" {
    var f: Filter = .{ .supports = .{} };
    const other = "\x1b]2;title\x07\x1b]75010;x\x07\x1b[31m\x1b[?2004h\x1b[?25l\x1b[2 q\x1b[>0q\x1b[5u\x1b\x1b]11;?\x07text";
    try testFeed(&f, other, other);
}

test "a terminal that takes every protocol gets every sequence" {
    var f: Filter = .{ .supports = .{ .program_status = true, .kitty_keyboard = true, .modify_other_keys = true } };
    const all = "\x1b]7501;state=done\x07\x1b[=5;1u\x1b[>4;2mx";
    try testFeed(&f, all, all);
}

test "a terminal with the kitty protocol keeps it, and loses modifyOtherKeys" {
    var f: Filter = .{ .supports = .{ .kitty_keyboard = true } };
    try testFeed(&f, "\x1b[=5;1u\x1b[>4;2mx", "\x1b[=5;1ux");
}

test "a held prefix that turns out ordinary passes through in order" {
    var f: Filter = .{ .supports = .{} };
    try testFeed(&f, "a\x1b]750", "a");
    try testFeed(&f, "9;x\x07b", "\x1b]7509;x\x07b");
    try testFeed(&f, "a\x1b[>", "a");
    try testFeed(&f, "0qb", "\x1b[>0qb");
}
