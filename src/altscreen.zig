//! Filtering of alternate-screen switches out of passthrough output.
//!
//! The attached client's view lives inside the user terminal's own
//! alternate screen, so a window's switches between its screens must
//! never reach the client: the terminal cannot nest alternate screens,
//! and a raw `1049l` would dump the client onto the user's shell view.
//! Like screen and tmux, the daemon tracks screen state in the terminal
//! emulator, strips the switches from the byte stream, and repaints the
//! client from terminal state whenever the active screen may have
//! changed.
//!
//! The filter follows the byte stream with the state table of the
//! window's own parser, so a control byte, DEL or C1 byte inside a
//! sequence affects the filter exactly as it affects the parser.

const std = @import("std");
const vt = @import("ghostty-vt");

const State = vt.Parser.State;
pub const Transition = vt.parse_table.Transition;

/// Room for a held sequence. A screen switch takes under 20 bytes. A
/// longer private-mode sequence is stripped and repainted, because it
/// cannot be held whole until its final byte shows whether it switches.
pub const held_capacity = 64;

/// Modes that switch between the primary and alternate screen.
fn isAltScreenMode(param: u16) bool {
    return param == 47 or param == 1047 or param == 1049;
}

/// The parser's transition on `byte` from `state`. In ground the
/// window's stream decodes UTF-8 before the parser sees a byte, so only
/// ESC starts a sequence there and C1 bytes are not controls.
pub fn transition(state: State, byte: u8) Transition {
    if (state == .ground) return .{
        .state = if (byte == 0x1b) .escape else .ground,
        .action = .none,
    };
    return vt.parse_table.table[byte][@intFromEnum(state)];
}

/// Incremental scanner that copies input to a writer, removing every
/// sequence that may switch the active screen: RIS (`ESC c`), and a
/// private mode set, reset or restore (`CSI ? Pm h|l|r`) that names
/// 47, 1047 or 1049. Other sequences and all text pass through
/// unchanged. A sequence that may yet be one of these is held, across
/// feeds if it is split, until its final byte decides.
pub const Filter = struct {
    /// The parser's state after the bytes scanned so far.
    state: State = .ground,
    /// The sequence being held: an escape, a CSI introducer, or a private
    /// CSI. Empty while none is.
    held: [held_capacity]u8 = undefined,
    held_len: usize = 0,
    /// The held CSI's parameter being read, saturating as the parser's
    /// does.
    param: u16 = 0,
    /// A finished parameter of the held CSI names an alternate-screen
    /// mode.
    names_alt: bool = false,

    pub const Result = struct {
        /// How much of the input was scanned: all of it, or up to the end
        /// of a removed sequence.
        consumed: usize,
        /// The scan stopped at a removed sequence, so the active screen
        /// may have changed and the client needs a repaint.
        switched: bool = false,
    };

    /// What a byte does to the held sequence.
    const Step = enum {
        /// The byte joins the held sequence.
        hold,
        /// A control executed inside the sequence. It passes through on
        /// its own, as executing it before the sequence ends has the same
        /// effect.
        execute,
        /// The byte completes a sequence that may switch screens.
        switch_screen,
        /// The byte shows the held sequence cannot switch screens, so it
        /// passes through, and the byte is scanned afresh.
        release,
    };

    /// Scan `input`, writing passthrough bytes to `writer`, until the end
    /// of the input or of the first sequence that may switch screens,
    /// which is removed.
    pub fn feed(
        self: *Filter,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!Result {
        // Start of the bytes that pass through as they are.
        var run_start: usize = 0;
        for (input, 0..) |byte, i| {
            const t = transition(self.state, byte);
            if (self.held_len > 0) {
                var next = self.step(byte, t);
                // A sequence too long to hold whole may still switch
                // screens, so it is stripped too.
                if (next == .hold and self.held_len == held_capacity) next = .switch_screen;
                switch (next) {
                    .hold => {
                        self.hold(byte, t);
                        self.state = t.state;
                        continue;
                    },
                    .execute => {
                        try writer.writeByte(byte);
                        continue;
                    },
                    .switch_screen => {
                        self.held_len = 0;
                        self.state = t.state;
                        return .{ .consumed = i + 1, .switched = true };
                    },
                    .release => {
                        try writer.writeAll(self.held[0..self.held_len]);
                        self.held_len = 0;
                        run_start = i;
                    },
                }
            }

            self.state = t.state;
            if (t.state == .escape or t.state == .csi_entry) {
                try writer.writeAll(input[run_start..i]);
                run_start = i + 1;
                self.param = 0;
                self.names_alt = false;
                self.hold(byte, t);
            }
        }
        if (self.held_len == 0) try writer.writeAll(input[run_start..]);
        return .{ .consumed = input.len };
    }

    /// Forget held bytes and scanning state. Used when a repaint replaces
    /// the passthrough stream, which the parser has finished every
    /// sequence of.
    pub fn reset(self: *Filter) void {
        self.state = .ground;
        self.held_len = 0;
    }

    /// A byte that leaves the parser in the same state, like DEL or a
    /// repeated ESC, is held, since holding a byte only delays it.
    fn step(self: *const Filter, byte: u8, t: Transition) Step {
        if (t.action == .execute and t.state == self.state) return .execute;
        return switch (self.state) {
            .escape => if (byte == '[' and t.state == .csi_entry)
                .hold
            else if (byte == 'c' and t.action == .esc_dispatch)
                .switch_screen
            else if (t.state == .escape)
                .hold
            else
                .release,
            .csi_entry => if (byte == '?' or t.state == .csi_entry) .hold else .release,
            // Only a private CSI is held this far.
            .csi_param, .csi_intermediate => if (t.action == .csi_dispatch)
                if (self.switchesScreen(byte)) .switch_screen else .release
            else if (t.state == .csi_param or t.state == .csi_intermediate)
                .hold
            else
                .release,
            else => unreachable,
        };
    }

    /// Whether the held private CSI, ended by `final`, may switch screens.
    /// A set, reset or restore of several modes counts if any is an
    /// alternate-screen mode. The repaint that follows its removal
    /// re-emits the other modes from terminal state.
    fn switchesScreen(self: *const Filter, final: u8) bool {
        if (final != 'h' and final != 'l' and final != 'r') return false;
        return self.names_alt or isAltScreenMode(self.param);
    }

    fn hold(self: *Filter, byte: u8, t: Transition) void {
        self.held[self.held_len] = byte;
        self.held_len += 1;
        if (t.action != .param) return;
        switch (byte) {
            '0'...'9' => self.param = self.param *| 10 +| (byte - '0'),
            else => {
                if (isAltScreenMode(self.param)) self.names_alt = true;
                self.param = 0;
            },
        }
    }
};

/// Feed `input` through the filter until it is all consumed, and expect
/// the passthrough bytes and the number of sequences removed.
fn testFeed(filter: *Filter, input: []const u8, expected: []const u8, switches: usize) !void {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    var rest = input;
    var got_switches: usize = 0;
    while (rest.len > 0) {
        const result = try filter.feed(rest, &writer);
        if (result.switched) got_switches += 1;
        rest = rest[result.consumed..];
    }
    try std.testing.expectEqualStrings(expected, writer.buffered());
    try std.testing.expectEqual(switches, got_switches);
}

test "plain text and ordinary sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "hello \x1b[2J\x1b[1;5H\x1b[31mworld", "hello \x1b[2J\x1b[1;5H\x1b[31mworld", 0);
    try testFeed(&f, "\x1b]0;title\x07\x1b7\x1b8\x1b]8;;x\x1b\\", "\x1b]0;title\x07\x1b7\x1b8\x1b]8;;x\x1b\\", 0);
}

test "non-screen private modes pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?25l\x1b[?2004h\x1b[?1000h", "\x1b[?25l\x1b[?2004h\x1b[?1000h", 0);
}

test "alt screen toggles are removed" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1b[?1049hb", "ab", 1);
    try testFeed(&f, "c\x1b[?1049ld", "cd", 1);
    try testFeed(&f, "\x1b[?47h\x1b[?1047l", "", 2);
}

test "mixed parameter list containing alt mode is removed" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?25;1049h", "", 1);
    try testFeed(&f, "\x1b[?1049;25l", "", 1);
}

test "sequence split across feeds" {
    var f: Filter = .{};
    try testFeed(&f, "x\x1b[?10", "x", 0);
    try testFeed(&f, "49h y", " y", 1);
    try testFeed(&f, "\x1b", "", 0);
    try testFeed(&f, "[?25h", "\x1b[?25h", 0);
}

test "a scan stops at the end of a removed sequence" {
    var f: Filter = .{};
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    // "before" is 6 bytes and the toggle 8 more.
    const result = try f.feed("before\x1b[?1049hafter", &writer);
    try std.testing.expectEqualStrings("before", writer.buffered());
    try std.testing.expectEqual(Filter.Result{ .consumed = 14, .switched = true }, result);
}

test "a control byte inside a toggle passes through and the toggle is still removed" {
    // The parser executes C0 controls inside a sequence and ignores DEL.
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?10\n49h", "\n", 1);
    try testFeed(&f, "\x1b\r[?1049l", "\r", 1);
    try testFeed(&f, "\x1b[?10\x7f49h", "", 1);
}

test "CAN or a new ESC abandons a held sequence as the parser does" {
    var f: Filter = .{};
    // After CAN, "49h" is text, so nothing switches.
    try testFeed(&f, "\x1b[?10\x1849h", "\x1b[?10\x1849h", 0);
    try testFeed(&f, "\x1b[?1\x1b[?1049h", "\x1b[?1", 1);
}

test "8-bit CSI starts a toggle inside a sequence but is text in ground" {
    var f: Filter = .{};
    // Inside a DCS, 0x9b enters CSI, as it does for the parser.
    try testFeed(&f, "\x1bP\x9b?1049h", "\x1bP", 1);
    f.reset();
    // In ground the parser decodes 0x9b as part of UTF-8, not as CSI.
    try testFeed(&f, "\x9b?1049h", "\x9b?1049h", 0);
}

test "a full reset is removed, even inside a string" {
    var f: Filter = .{};
    try testFeed(&f, "a\x1bcb", "ab", 1);
    try testFeed(&f, "\x1b]0;t\x1bcx", "\x1b]0;tx", 1);
}

test "restoring an alt screen mode is removed, saving it is not" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?1049s", "\x1b[?1049s", 0);
    try testFeed(&f, "\x1b[?1049r", "", 1);
}

test "a long private sequence without an alt mode passes through" {
    var f: Filter = .{};
    const long = "\x1b[?1;2;3;4;5;6;7;8;9;10;11;12h";
    try testFeed(&f, long, long, 0);
}

test "a private sequence too long to hold is stripped" {
    var f: Filter = .{};
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const long = "a\x1b[?" ++ "1;" ** 40 ++ "1049h";
    const result = try f.feed(long, &writer);
    try std.testing.expectEqualStrings("a", writer.buffered());
    try std.testing.expect(result.switched);
    try std.testing.expectEqual(1 + held_capacity + 1, result.consumed);
}

test "DECRQM style sequences pass through" {
    var f: Filter = .{};
    try testFeed(&f, "\x1b[?1049$p", "\x1b[?1049$p", 0);
}

test "random streams: no switch passes through, and every switch is reported" {
    const alloc = std.testing.allocator;
    // Whole switches, and fragments of them and of the controls that
    // interrupt them.
    const fragments = [_][]const u8{
        "\x1b[?1049h", "\x1b[?1049l", "\x1b[?1049s", "\x1b[?1049r", "\x1b[?47h",
        "\x1b[?1047l", "\x1bc",       "\x1b",        "[",           "?",
        "47",          "1047",        "1049",        "25",          ";",
        ":",           "h",           "l",           "r",           "s",
        "c",           "$",           "p",           "\n",          "\x18",
        "\x1a",        "\x7f",        "\x9b",        "\x9c",        "\x90",
        "P",           "]",           "\x07",        "\\",          "x",
        "\xe2",        "\x94",        "\x80",
    };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();

    var input: [256]u8 = undefined;
    var out_buf: [256 + held_capacity]u8 = undefined;
    for (0..2_000) |_| {
        // The session's terminal, and the client's, which sees only what
        // the filter passes.
        var session = try vt.Terminal.init(alloc, .{ .cols = 10, .rows = 4 });
        defer session.deinit(alloc);
        var session_stream = session.vtStream();
        defer session_stream.deinit();
        var client = try vt.Terminal.init(alloc, .{ .cols = 10, .rows = 4 });
        defer client.deinit(alloc);
        var client_stream = client.vtStream();
        defer client_stream.deinit();

        var len: usize = 0;
        while (true) {
            const fragment = fragments[random.uintLessThan(usize, fragments.len)];
            if (len + fragment.len > input.len) break;
            @memcpy(input[len..][0..fragment.len], fragment);
            len += fragment.len;
        }

        var filter: Filter = .{};
        var rest = input[0..len];
        while (rest.len > 0) {
            // Feed in pieces, as reads from the PTY arrive.
            const piece = rest[0..@min(rest.len, 1 + random.uintLessThan(usize, 12))];
            var writer = std.Io.Writer.fixed(&out_buf);
            const result = try filter.feed(piece, &writer);
            const was = session.screens.active_key;
            session_stream.nextSlice(piece[0..result.consumed]);
            if (session.screens.active_key != was and !result.switched) {
                std.debug.print("unreported switch in {any}\n", .{input[0..len]});
                return error.TestUnexpectedResult;
            }
            client_stream.nextSlice(writer.buffered());
            if (client.screens.active_key != .primary) {
                std.debug.print("switch passed through in {any}\n", .{input[0..len]});
                return error.TestUnexpectedResult;
            }
            rest = rest[result.consumed..];
        }
    }
}
