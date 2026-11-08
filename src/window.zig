//! A window: one PTY-attached child process and its libghostty terminal
//! state. All child output is parsed through ghostty-vt so the full screen
//! (including scrollback, styles, modes, and cursor) can be rehydrated at
//! any time for attach, window switching, and hardcopy.

const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");
const altscreen = @import("altscreen.zig");
const oscquery = @import("oscquery.zig");
const ptypkg = @import("pty.zig");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.window);

/// Ghostty's own default scrollback-limit. The terminal allocates
/// history pages as output fills them, so a quiet session stays small.
const max_scrollback_bytes = 10_000_000;

pub const Window = struct {
    alloc: std.mem.Allocator,

    /// PTY master; -1 once the child is gone.
    pty_fd: posix.fd_t,
    child_pid: posix.pid_t,
    dead: bool = false,

    /// The child rang the terminal bell since the daemon last serviced
    /// this window. The parser sets this only on a real BEL, never on
    /// the BEL that terminates an OSC string (so a title update cannot
    /// trip it). The daemon reads and clears the latch each service
    /// cycle.
    bell: bool = false,

    /// Fallback title: the command that was launched.
    command_title: []const u8,

    /// Wall-clock time (milliseconds) of the most recent child output,
    /// maintained by the daemon. Drives `wait --idle`.
    last_output_ms: i64,

    /// True while this window is the active window of an attached client.
    /// Controls whether query responses (DSR, DA, ...) are answered by
    /// the daemon or left to the client's real terminal.
    passthrough: bool = false,

    /// True while feeding bytes whose passthrough copy was discarded
    /// (see `feedDiscarded`); forces daemon-side query responses even
    /// when passing through.
    feeding_discarded: bool = false,

    /// Background color of the real terminal, reported by an attached
    /// client. Lets the daemon answer OSC 11 background queries and the
    /// color-scheme DSR from inside the session, where the application
    /// can no longer reach the real terminal. Null until a client
    /// reports it.
    term_bg: ?protocol.RgbPayload = null,
    /// An OSC 11 background query arrived before any client had reported
    /// a background color. Answered as soon as one is reported, so a
    /// session that queries the theme the instant it starts still gets
    /// an answer once the attaching client probes its terminal.
    bg_query_pending: bool = false,
    /// Strips OSC 11 background queries from the child's output so the
    /// daemon answers each exactly once (see oscquery.zig).
    color_filter: oscquery.Filter = .{},

    /// Strips alternate-screen toggles from passthrough output; the
    /// daemon repaints from terminal state on screen switches instead.
    alt_filter: altscreen.Filter = .{},

    term: vt.Terminal,
    stream: Stream,

    pub const Stream = vt.TerminalStream;

    /// Window is heap-allocated and pinned: the stream handler keeps a
    /// pointer to `term` and effects callbacks recover the Window with
    /// @fieldParentPtr.
    pub fn create(
        alloc: std.mem.Allocator,
        argv: []const []const u8,
        env: *std.process.EnvMap,
        rows: u16,
        cols: u16,
        cwd: ?[]const u8,
    ) !*Window {
        const self = try alloc.create(Window);
        errdefer alloc.destroy(self);

        const spawned = try ptypkg.spawnInPty(alloc, .{
            .argv = argv,
            .env = env,
            .size = ptypkg.makeWinsize(rows, cols),
            .cwd = cwd,
        });
        errdefer posix.close(spawned.master);

        self.* = .{
            .alloc = alloc,
            .pty_fd = spawned.master,
            .child_pid = spawned.pid,
            .command_title = try alloc.dupe(u8, argv[0]),
            .last_output_ms = std.time.milliTimestamp(),
            .term = undefined,
            .stream = undefined,
        };
        errdefer alloc.free(self.command_title);

        self.term = try vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = max_scrollback_bytes,
        });
        errdefer self.term.deinit(alloc);

        var handler: Stream.Handler = .init(&self.term);
        handler.effects = .{
            .write_pty = effectWritePty,
            .bell = effectBell,
            .color_scheme = effectColorScheme,
            .device_attributes = effectDeviceAttributes,
            .enquiry = null,
            .size = effectSize,
            .title_changed = null,
            .pwd_changed = null,
            .xtversion = effectXtversion,
        };
        self.stream = .initAlloc(alloc, handler);

        return self;
    }

    pub fn destroy(self: *Window) void {
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.alloc.free(self.command_title);
        if (self.pty_fd >= 0) posix.close(self.pty_fd);
        self.alloc.destroy(self);
    }

    fn fromHandler(handler: *Stream.Handler) *Window {
        const stream: *Stream = @alignCast(@fieldParentPtr("handler", handler));
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// Query responses generated by the terminal (DSR, DECRQM, OSC color
    /// queries, ...). When a client is attached and this window is being
    /// passed through raw, the client's real terminal sees the query and
    /// answers it, so the daemon stays quiet to avoid double responses.
    /// Bytes the passthrough discarded never reach that terminal, so
    /// queries among them are answered here after all.
    fn effectWritePty(handler: *Stream.Handler, data: [:0]const u8) void {
        const self = fromHandler(handler);
        if (self.passthrough and !self.feeding_discarded) return;
        if (self.pty_fd < 0) return;
        protocol.writeAll(self.pty_fd, data) catch |err| {
            log.warn("window: failed writing query response: {}", .{err});
        };
    }

    // The device attributes response type is not re-exported by the
    // ghostty-vt root, so derive it from the effects callback signature.
    const DeviceAttributes = EffectReturn("device_attributes");

    // The color scheme effect returns an optional ColorScheme; recover
    // the enum the same way as the device attributes type above.
    const ColorScheme = @typeInfo(EffectReturn("color_scheme")).optional.child;

    fn EffectReturn(comptime field_name: []const u8) type {
        const Effects = Stream.Handler.Effects;
        const field = std.meta.fieldInfo(
            Effects,
            @field(std.meta.FieldEnum(Effects), field_name),
        );
        const Fn = @typeInfo(field.type).optional.child;
        return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    }

    fn effectBell(handler: *Stream.Handler) void {
        fromHandler(handler).bell = true;
    }

    fn effectDeviceAttributes(handler: *Stream.Handler) DeviceAttributes {
        _ = handler;
        return .{};
    }

    /// Answer the color-scheme DSR (CSI ? 996 n) from the reported
    /// background's luminance. Returns null (no reply) until a client
    /// reports a background, matching ghostty-vt's behavior for an
    /// unknown color scheme.
    fn effectColorScheme(handler: *Stream.Handler) ?ColorScheme {
        const self = fromHandler(handler);
        const bg = self.term_bg orelse return null;
        return if (bg.isDark()) .dark else .light;
    }

    fn effectSize(handler: *Stream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = 8,
            .cell_height = 16,
        };
    }

    fn effectXtversion(handler: *Stream.Handler) []const u8 {
        _ = handler;
        return "boo " ++ @import("main.zig").version;
    }

    /// Feed child output into the terminal emulator.
    pub fn feed(self: *Window, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    /// Feed child output that was dropped from the passthrough stream
    /// because a repaint will cover it. The client's real terminal never
    /// sees these bytes, so queries in them must be answered by the daemon
    /// or the application blocks waiting for a response that nobody sends.
    pub fn feedDiscarded(self: *Window, bytes: []const u8) void {
        self.feeding_discarded = true;
        defer self.feeding_discarded = false;
        self.stream.nextSlice(bytes);
    }

    /// Whether the parser has finished every sequence and character fed so
    /// far. Until it has, the rest of one is still to come, and those bytes
    /// would garble a canvas that a repaint has just drawn fresh.
    pub fn atGround(self: *const Window) bool {
        // The UTF-8 decoder's state is 0 between characters.
        return self.stream.parser.state == .ground and self.stream.utf8decoder.state == 0;
    }

    pub fn writeInput(self: *Window, bytes: []const u8) !void {
        if (self.pty_fd < 0) return error.WindowDead;
        try protocol.writeAll(self.pty_fd, bytes);
    }

    /// Copy `input` to `writer` with OSC 11 background queries removed,
    /// answering each one. The query is answered with the background a
    /// client reported; until one is known the query is recorded and
    /// answered later by `setBackground`. Removing the query keeps it
    /// from also reaching an attached client's real terminal, which
    /// would answer it a second time.
    pub fn filterColorQueries(
        self: *Window,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const result = try self.color_filter.feed(input, writer);
        for (0..result.background_queries) |_| self.answerBackgroundQuery();
    }

    fn answerBackgroundQuery(self: *Window) void {
        const bg = self.term_bg orelse {
            self.bg_query_pending = true;
            return;
        };
        self.writeBackgroundReply(bg);
    }

    /// Record the real terminal's background color and answer any query
    /// that arrived before it was known.
    pub fn setBackground(self: *Window, bg: protocol.RgbPayload) void {
        self.term_bg = bg;
        if (self.bg_query_pending) {
            self.bg_query_pending = false;
            self.writeBackgroundReply(bg);
        }
    }

    fn writeBackgroundReply(self: *Window, bg: protocol.RgbPayload) void {
        if (self.pty_fd < 0) return;
        var buf: [40]u8 = undefined;
        const reply = std.fmt.bufPrint(
            &buf,
            "\x1b]11;rgb:{x:0>4}/{x:0>4}/{x:0>4}\x07",
            .{ bg.r, bg.g, bg.b },
        ) catch return;
        protocol.writeAll(self.pty_fd, reply) catch |err| {
            log.warn("window: failed writing OSC 11 reply: {}", .{err});
        };
    }

    pub fn resize(self: *Window, rows: u16, cols: u16) !void {
        try self.term.resize(self.alloc, cols, rows);
        if (self.pty_fd >= 0) {
            try ptypkg.Pty.setSize(self.pty_fd, ptypkg.makeWinsize(rows, cols));
        }
    }

    pub fn title(self: *Window) []const u8 {
        if (self.term.getTitle()) |t| {
            if (t.len > 0) return t;
        }
        return self.command_title;
    }

    /// Whether the active screen has any kitty keyboard protocol
    /// flags enabled. While attached, the user's terminal mirrors
    /// this state, so the C-a prefix arrives CSI-u encoded.
    pub fn kittyKeysActive(self: *Window) bool {
        return self.term.screens.active.kitty_keyboard.current().int() != 0;
    }

    /// Whether the application has xterm modifyOtherKeys mode 2 set.
    /// While attached, the user's terminal mirrors this state (the
    /// repaint's keyboard extra replays CSI > 4 ; 2 m), so the C-a
    /// prefix may arrive as CSI 27;5;97~ on xterm-faithful terminals.
    pub fn modifyKeysActive(self: *Window) bool {
        return self.term.flags.modify_other_keys_2;
    }

    /// Plain-text dump of the live screen for peek. It reads the active
    /// area, not the viewport that copy mode scrolls into the history.
    pub fn plainScreen(self: *Window, alloc: std.mem.Allocator) ![]const u8 {
        return self.term.screens.active.dumpStringAlloc(alloc, .{ .active = .{} });
    }

    /// Plain-text dump including the full scrollback history.
    pub fn plainScrollback(self: *Window, alloc: std.mem.Allocator) ![]const u8 {
        return self.term.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    }

    /// VT bytes that reproduce this window's visible screen on a
    /// freshly sanitized terminal: contents, styles, cursor, and modes.
    pub fn repaint(self: *Window, alloc: std.mem.Allocator) ![]u8 {
        var raw: std.Io.Writer.Allocating = .init(alloc);
        defer raw.deinit();

        var formatter: vt.formatter.TerminalFormatter = .init(&self.term, .{ .emit = .vt });
        // Repaint the visible screen only. The client canvas drops
        // scrolled-off rows (attached clients render in the user
        // terminal's alternate screen), and the formatter always trims
        // trailing blank rows from its dump. Including history scrolls
        // the canvas, so whenever the screen ends in blank rows the
        // content lands shifted up by the trimmed count and the cursor
        // restore below points at the wrong row; every relative redraw
        // the application makes after that corrupts the client's view.
        formatter.content = .{ .selection = self.areaSelection(.active) };
        formatter.extra = .{
            // Keep the client's own palette: colors are emitted as
            // palette references, not redefined.
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = false,
            .keyboard = true,
            .screen = .none,
        };
        try raw.writer.print("{f}", .{formatter});

        // Scrolling-region and tabstop rehydration moved the cursor, so the
        // cursor is placed after them. Its pen and the screen's other state
        // come last, so the glyph that restores a pending wrap prints in
        // its cell's own style and the default character set.
        const screen = self.term.screens.active;
        if (screen.cursor.pending_wrap) {
            try self.writePendingWrap(&raw.writer);
        } else {
            try self.writeCursorPos(&raw.writer, screen.cursor.x, screen.cursor.y);
        }
        var screen_formatter: vt.formatter.ScreenFormatter = .init(screen, .{ .emit = .vt });
        screen_formatter.content = .none;
        screen_formatter.extra = .all;
        screen_formatter.extra.cursor = false;
        try raw.writer.print("{f}", .{screen_formatter});
        try self.writeCursorShape(&raw.writer);

        // The formatter re-emits alternate-screen modes when the window
        // is on the alt screen, but the client canvas always shows the
        // active screen, so screen toggles must never reach it.
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(begin_sync ++ sanitize_sequence);
        // The formatter does not emit the title, so without this the
        // client terminal's title would go stale across reattach and
        // window switches.
        try writeTitle(self.title(), &out.writer);
        var filter: altscreen.Filter = .{};
        var rest = raw.writer.buffered();
        while (rest.len > 0) rest = rest[(try filter.feed(rest, &out.writer)).consumed..];
        try out.writer.writeAll(end_sync);

        return alloc.dupe(u8, out.writer.buffered());
    }

    /// VT bytes that show copy mode's viewport on a freshly sanitized
    /// terminal, with the cursor hidden. A tag at the top right shows how
    /// many rows the viewport is scrolled back, out of the rows of
    /// history.
    pub fn copyModeFrame(self: *Window, alloc: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(begin_sync ++ sanitize_sequence ++ "\x1b[?25l");

        var formatter: vt.formatter.TerminalFormatter = .init(&self.term, .{ .emit = .vt });
        formatter.content = .{ .selection = self.areaSelection(.viewport) };
        formatter.extra = .none;
        try out.writer.print("{f}", .{formatter});

        const bar = self.term.screens.active.pages.scrollbar();
        const history_rows = bar.total - bar.len;
        var tag_buf: [48]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tag_buf, "[{d}/{d}]", .{
            history_rows - bar.offset,
            history_rows,
        });
        // Clipped to the row, so a narrow canvas does not wrap the tag
        // onto the next one.
        const shown = tag[0..@min(tag.len, self.term.cols)];
        const tag_col = self.term.cols - shown.len + 1;
        try out.writer.print("\x1b[0m\x1b[1;{d}H\x1b[7m{s}\x1b[0m", .{ tag_col, shown });
        try out.writer.writeAll(end_sync);

        return alloc.dupe(u8, out.writer.buffered());
    }

    /// Selection spanning the rows of `area` on the active terminal
    /// screen. `.active` is the live screen without the history above
    /// it, and `.viewport` is the rows copy mode has scrolled to. Null
    /// (the formatter's dump-everything default) only if the pins cannot
    /// resolve, which a sized terminal never produces.
    fn areaSelection(self: *Window, comptime area: vt.point.Tag) ?vt.Selection {
        const pages = &self.term.screens.active.pages;
        const tl = pages.pin(@unionInit(vt.Point, @tagName(area), .{
            .x = 0,
            .y = 0,
        })) orelse return null;
        const br = pages.pin(@unionInit(vt.Point, @tagName(area), .{
            .x = self.term.cols - 1,
            .y = self.term.rows - 1,
        })) orelse return null;
        return vt.Selection.init(tl, br, false);
    }

    fn writeCursorPos(self: *Window, writer: *std.Io.Writer, x: usize, y: usize) !void {
        var row = y;
        var col = x;
        // CUP is relative to the scrolling region in origin mode.
        if (self.term.modes.get(.origin)) {
            row -|= self.term.scrolling_region.top;
            col -|= self.term.scrolling_region.left;
        }
        try writer.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    /// Reprint the glyph the cursor sits on at the right margin. A cursor
    /// position cannot express that the next character wraps first, but
    /// printing the glyph there sets that pending wrap, as it did for the
    /// window.
    fn writePendingWrap(self: *Window, writer: *std.Io.Writer) !void {
        const screen = self.term.screens.active;
        const cursor = &screen.cursor;
        // Under the cursor is the spacer of a wide glyph that starts a
        // column to the left.
        const x = if (cursor.page_cell.wide == .spacer_tail) cursor.x - 1 else cursor.x;
        try self.writeCursorPos(writer, x, cursor.y);
        // The formatter leaves out an empty cell, so a blank stands in.
        if (cursor.page_cell.isEmpty()) return writer.writeAll("\x1b[0m ");

        var formatter: vt.formatter.ScreenFormatter = .init(screen, .{ .emit = .vt });
        formatter.content = .{ .selection = vt.Selection.init(
            screen.pages.pin(.{ .active = .{ .x = x, .y = cursor.y } }).?,
            screen.pages.pin(.{ .active = .{ .x = cursor.x, .y = cursor.y } }).?,
            false,
        ) };
        try writer.print("{f}", .{formatter});
    }

    /// DECSCUSR for the cursor shape the application set. For an
    /// application that set none, the sanitize sequence has already
    /// restored the client terminal's default.
    fn writeCursorShape(self: *Window, writer: *std.Io.Writer) !void {
        if (self.stream.handler.default_cursor) return;
        const shape: u8 = switch (self.term.screens.active.cursor.cursor_style) {
            .block, .block_hollow => 1,
            .underline => 3,
            .bar => 5,
        };
        // Each shape's steady form is one past its blinking form.
        const steady = !self.term.modes.get(.cursor_blinking);
        try writer.print("\x1b[{d} q", .{shape + @intFromBool(steady)});
    }
};

/// OSC 2: set the client terminal's window title. Control bytes are
/// dropped so the title text cannot terminate or corrupt the sequence.
fn writeTitle(title: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1b]2;");
    for (title) |byte| {
        if (byte < 0x20 or byte == 0x7f) continue;
        try writer.writeByte(byte);
    }
    try writer.writeByte(0x07);
}

/// Resets every piece of terminal state a window's repaint or
/// passthrough may have changed, without touching the screen choice or
/// the saved cursor. DECSTR is deliberately avoided: it clears the
/// cursor position that `1049h` saved, which the client needs intact
/// for the final `1049l` restore on detach.
pub const reset_state_sequence =
    "\x0f\x1b(B" ++ // locking shift and G0 charset to ASCII
    "\x1b[0m" ++ // SGR reset
    "\x1b[0 q" ++ // default cursor style
    "\x1b[?1l\x1b[?5l\x1b[?6l\x1b[?7h" ++ // cursor keys, reverse video, origin, autowrap
    "\x1b[4l" ++ // insert mode off
    "\x1b[r\x1b[?69l" ++ // scrolling margins reset
    "\x1b[?25h" ++ // cursor visible
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l" ++ // mouse off
    "\x1b[?2004l" ++ // bracketed paste off
    "\x1b[?1004l" ++ // focus reporting off
    "\x1b[>4;0m" ++ // modifyOtherKeys off
    "\x1b[=0;1u"; // kitty keyboard flags cleared

/// Repaint preamble: reset state, then clear the client canvas. The
/// canvas is the client terminal's own alternate screen, so no screen
/// toggles belong here.
pub const sanitize_sequence = reset_state_sequence ++ "\x1b[H\x1b[2J";

/// Synchronized output (mode 2026) around a frame: the client terminal
/// shows the frame only once it is complete, so the clear that starts
/// it never flashes on screen.
const begin_sync = "\x1b[?2026h";
const end_sync = "\x1b[?2026l";

test "window state machine without a child" {
    // Exercise the terminal+stream wiring directly (no PTY): construct
    // the pieces the same way Window.create does.
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("hello \x1b[1;31mred\x1b[0m\r\nline2");

    const plain = try term.plainString(alloc);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "hello red") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "line2") != null);

    // Styled repaint contains the bold+red SGR introducer and content.
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var formatter: vt.formatter.TerminalFormatter = .init(&term, .{ .emit = .vt });
    formatter.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false,
        .pwd = false,
        .keyboard = true,
        .screen = .all,
    };
    try out.writer.print("{f}", .{formatter});
    const repainted = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, repainted, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, repainted, "\x1b[") != null);
}

/// A childless window of the given size, whose output a test feeds.
fn testWindow(alloc: std.mem.Allocator, rows: u16, cols: u16) !*Window {
    const win = try alloc.create(Window);
    win.* = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = -1,
        .command_title = try alloc.dupe(u8, "test"),
        .last_output_ms = 0,
        .term = try vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 512 * 1024,
        }),
        .stream = undefined,
    };
    win.stream = .initAlloc(alloc, .init(&win.term));
    return win;
}

test "repaint reproduces the screen once output has scrolled" {
    // The shape every frame-based TUI leaves behind (Claude Code's
    // idle prompt is the motivating case): output has scrolled into
    // history, the application then redraws a short frame at the top
    // and erases the rest, leaving trailing blank rows below the
    // cursor. The repaint must land every row and the cursor exactly
    // where the emulator has them, or every subsequent relative
    // redraw by the application corrupts the client's view.
    const alloc = std.testing.allocator;
    const win = try testWindow(alloc, 5, 20);
    defer win.destroy();

    // Eight lines scroll three into history, then a two-row frame
    // is drawn and everything below it erased: the screen is
    // L4, "boo>", and three blank rows, cursor after the "boo>".
    win.feed("L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7\r\nL8");
    win.feed("\x1b[2;1Hboo>\x1b[0J");

    const bytes = try win.repaint(alloc);
    defer alloc.free(bytes);

    // Replay on a fresh terminal of the same size, standing in for
    // an attached client's alternate-screen canvas.
    var canvas = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer canvas.deinit(alloc);
    var canvas_stream = canvas.vtStream();
    defer canvas_stream.deinit();
    canvas_stream.nextSlice(bytes);

    const want = try win.term.plainString(alloc);
    defer alloc.free(want);
    const got = try canvas.plainString(alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(want, got);

    const want_cursor = win.term.screens.active.cursor;
    const got_cursor = canvas.screens.active.cursor;
    try std.testing.expectEqual(want_cursor.y, got_cursor.y);
    try std.testing.expectEqual(want_cursor.x, got_cursor.x);
}

test "repaint keeps the cursor's pending wrap, pen and shape" {
    const alloc = std.testing.allocator;
    // Each line ends at the right margin, so the next character wraps: a
    // narrow glyph, a wide one, one in a style the pen does not keep, one
    // the pen keeps the style of, and a blank.
    const lines = [_][]const u8{
        "0123456789",
        "01234567\u{4e2d}",
        "012345678\x1b[1;31m9\x1b[0m",
        "\x1b[4m0123456789",
        "\x1b[10G\x1b[42m \x1b[0m",
    };
    for (lines) |line| {
        const win = try testWindow(alloc, 5, 10);
        defer win.destroy();
        win.feed("\x1b[6 q");
        win.feed(line);
        try std.testing.expect(win.term.screens.active.cursor.pending_wrap);

        const bytes = try win.repaint(alloc);
        defer alloc.free(bytes);
        var canvas = try vt.Terminal.init(alloc, .{ .cols = 10, .rows = 5 });
        defer canvas.deinit(alloc);
        var canvas_stream = canvas.vtStream();
        defer canvas_stream.deinit();
        canvas_stream.nextSlice(bytes);

        const want = win.term.screens.active.cursor;
        const got = canvas.screens.active.cursor;
        try std.testing.expect(got.pending_wrap);
        try std.testing.expect(got.style.eql(want.style));
        try std.testing.expectEqual(vt.CursorStyle.bar, got.cursor_style);
        try std.testing.expect(!canvas.modes.get(.cursor_blinking));

        // The next character wraps onto the next row on both.
        win.feed("X");
        canvas_stream.nextSlice("X");
        const want_text = try win.term.plainString(alloc);
        defer alloc.free(want_text);
        const got_text = try canvas.plainString(alloc);
        defer alloc.free(got_text);
        try std.testing.expectEqualStrings(want_text, got_text);
        try std.testing.expectEqual(win.term.screens.active.cursor.x, canvas.screens.active.cursor.x);
        try std.testing.expectEqual(win.term.screens.active.cursor.y, canvas.screens.active.cursor.y);
    }
}

test "title set via OSC is tracked and emitted sanitized" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]2;my title\x07");
    try std.testing.expectEqualStrings("my title", term.getTitle().?);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTitle(term.getTitle().?, &writer);
    try std.testing.expectEqualStrings("\x1b]2;my title\x07", writer.buffered());

    // Control bytes in a title cannot break out of the sequence.
    writer = std.Io.Writer.fixed(&buf);
    try writeTitle("a\x1b\x07b\x7f!", &writer);
    try std.testing.expectEqualStrings("\x1b]2;ab!\x07", writer.buffered());
}

/// Build a childless window whose PTY master is the write end of a pipe,
/// so a test can read back whatever the window writes to the child.
fn testWindowWithPipe(alloc: std.mem.Allocator, read_fd: *posix.fd_t) !Window {
    const fds = try posix.pipe();
    read_fd.* = fds[0];
    return .{
        .alloc = alloc,
        .pty_fd = fds[1],
        .child_pid = -1,
        .command_title = "test",
        .last_output_ms = 0,
        .term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 5 }),
        .stream = undefined,
    };
}

test "OSC 11 background query is answered from the reported background" {
    const alloc = std.testing.allocator;
    var read_fd: posix.fd_t = undefined;
    var win = try testWindowWithPipe(alloc, &read_fd);
    defer posix.close(read_fd);
    defer posix.close(win.pty_fd);
    defer win.term.deinit(alloc);

    // A query before any background is known is deferred, not dropped.
    var sink: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&sink);
    try win.filterColorQueries("\x1b]11;?\x07", &w);
    try std.testing.expectEqualStrings("", w.buffered()); // query stripped
    try std.testing.expect(win.bg_query_pending);

    // Learning the background answers the pending query.
    win.setBackground(.{ .r = 0xffff, .g = 0xffff, .b = 0xffff });
    try std.testing.expect(!win.bg_query_pending);
    var buf: [64]u8 = undefined;
    const n = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b]11;rgb:ffff/ffff/ffff\x07", buf[0..n]);

    // A later query is answered immediately, now that the color is known.
    w = std.Io.Writer.fixed(&sink);
    try win.filterColorQueries("\x1b]11;?\x07", &w);
    const n2 = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b]11;rgb:ffff/ffff/ffff\x07", buf[0..n2]);
}

test "color-scheme DSR answered from background luminance" {
    const alloc = std.testing.allocator;
    var read_fd: posix.fd_t = undefined;
    var win = try testWindowWithPipe(alloc, &read_fd);
    defer posix.close(read_fd);
    defer posix.close(win.pty_fd);
    defer win.term.deinit(alloc);

    // Wire the real handler so CSI ? 996 n routes through effectColorScheme.
    var handler: Window.Stream.Handler = .init(&win.term);
    handler.effects = .{
        .write_pty = Window.effectWritePty,
        .bell = null,
        .color_scheme = Window.effectColorScheme,
        .device_attributes = null,
        .enquiry = null,
        .size = null,
        .title_changed = null,
        .pwd_changed = null,
        .xtversion = null,
    };
    win.stream = .initAlloc(alloc, handler);
    defer win.stream.deinit();

    // A light background reports color scheme 2 (light).
    win.setBackground(.{ .r = 0xffff, .g = 0xffff, .b = 0xffff });
    win.feed("\x1b[?996n");
    var buf: [32]u8 = undefined;
    const n = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b[?997;2n", buf[0..n]);

    // A dark background reports color scheme 1 (dark).
    win.setBackground(.{ .r = 0x1e1e, .g = 0x1e1e, .b = 0x2222 });
    win.feed("\x1b[?996n");
    const n2 = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b[?997;1n", buf[0..n2]);
}
