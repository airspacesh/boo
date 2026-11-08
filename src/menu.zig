//! The session menu that `C-a m` opens, which is the table `pane ls`
//! prints with a cursor on the session to switch to. The client draws
//! the menu and reads its keys while the session's daemon holds back the
//! session's output. The keys are copy mode's, plus Enter to switch.

const std = @import("std");
const copymode = @import("copymode.zig");
const sessions = @import("sessions.zig");
const window = @import("window.zig");

/// The rows around the entries, which hold the header above and the hint
/// below.
const chrome_rows = 2;

const hint = "Enter switches, Esc cancels, arrows or j/k move";

pub const Menu = struct {
    listing: sessions.Listing,
    /// The entry the cursor is on.
    selected: usize,
    /// The first entry on screen, when there are more than fit.
    top: usize = 0,

    pub const Choice = union(enum) {
        /// Keep the menu open.
        stay,
        /// Close the menu and stay on this session.
        cancel,
        /// Switch to the named session.
        pick: []const u8,
    };

    /// List the sessions in `dir`, with the cursor on `current`.
    pub fn open(alloc: std.mem.Allocator, dir: []const u8, current: []const u8) !Menu {
        const listing: sessions.Listing = try .init(alloc, dir);
        var selected: usize = 0;
        for (listing.entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, current)) selected = i;
        }
        return .{ .listing = listing, .selected = selected };
    }

    pub fn deinit(self: *Menu) void {
        self.listing.deinit();
    }

    fn entryRows(rows: u16) usize {
        return @max(1, rows -| chrome_rows);
    }

    /// Act on the keys in `input`, on a terminal `rows` tall, until one
    /// closes the menu. Keys after that one are dropped.
    pub fn handleInput(self: *Menu, input: []const u8, rows: u16) Choice {
        var rest = input;
        while (rest.len > 0) {
            if (rest[0] == '\r') {
                if (self.listing.entries.len == 0) return .cancel;
                return .{ .pick = self.listing.entries[self.selected].name };
            }
            const key = copymode.decodeKey(rest);
            rest = rest[key.len..];
            const action = key.action orelse continue;
            if (action == .exit) return .cancel;
            self.move(action, entryRows(rows));
        }
        return .stay;
    }

    fn move(self: *Menu, action: copymode.Action, page: usize) void {
        const last = self.listing.entries.len -| 1;
        const half_page = @max(1, page / 2);
        self.selected = switch (action) {
            .line_up => self.selected -| 1,
            .line_down => @min(last, self.selected + 1),
            .half_page_up => self.selected -| half_page,
            .half_page_down => @min(last, self.selected + half_page),
            .page_up => self.selected -| page,
            .page_down => @min(last, self.selected + page),
            .top => 0,
            .bottom => last,
            .exit => unreachable,
        };
    }

    /// VT bytes that draw the menu on a terminal `rows` tall, scrolled so
    /// the cursor's entry shows.
    pub fn frame(self: *Menu, alloc: std.mem.Allocator, rows: u16) ![]u8 {
        const visible = entryRows(rows);
        if (self.selected < self.top) self.top = self.selected;
        if (self.selected >= self.top + visible) self.top = self.selected + 1 - visible;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        // Resetting the terminal's keyboard modes makes keys arrive as
        // copy mode decodes them. With autowrap off, a row wider than the
        // terminal is cut off instead of wrapping onto the next.
        try out.appendSlice(alloc, window.begin_sync ++ window.sanitize_sequence ++ "\x1b[?25l\x1b[?7l");
        try out.appendSlice(alloc, "\x1b[1m");
        try self.listing.appendHeader(&out);
        try out.appendSlice(alloc, "\x1b[0m");
        const end = @min(self.listing.entries.len, self.top + visible);
        for (self.listing.entries[self.top..end], self.top..) |entry, i| {
            try out.print(alloc, "\x1b[{d};1H", .{i - self.top + 2});
            if (i == self.selected) try out.appendSlice(alloc, "\x1b[7m");
            try self.listing.appendRow(&out, entry);
            try out.appendSlice(alloc, "\x1b[0m");
        }
        try out.print(alloc, "\x1b[{d};1H\x1b[2m" ++ hint ++ "\x1b[0m", .{rows});
        try out.appendSlice(alloc, window.end_sync);
        return out.toOwnedSlice(alloc);
    }
};
