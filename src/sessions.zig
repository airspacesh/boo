//! The sessions in a socket directory, as `pane ls` lists them. Each
//! session's daemon is asked for its info, and the table shows what they
//! said.

const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");
const claimpkg = @import("claim.zig");
const client = @import("client.zig");
const paths = @import("paths.zig");

/// How long a listing waits for each session's daemon before listing the
/// session as busy.
pub const info_timeout_ms = 1000;

pub const SessionInfo = struct {
    /// Full info payload: name \t Attached|Detached \t idle_ms \t
    /// out_idle_ms \t unread \t bell_idle_ms \t pid \t client \t
    /// status \t title.
    text: []u8,
    attached: bool,
    idle_ms: i64,
    /// Time since the window last produced output; drives wait --idle.
    out_idle_ms: i64,
    /// Output arrived while no client was attached.
    unread: bool,
    /// Milliseconds since the last bell that rang while you were away,
    /// or -1 for none. A bell is an explicit "your turn" request.
    bell_idle_ms: i64,
    /// The session command's pid, or -1 once it has exited.
    pid: posix.pid_t,
    /// The path of the attached client's terminal, empty when none is
    /// attached; slices into `text`.
    client: []const u8,
    /// The body of the program's status report (OSC 7501), empty when
    /// it has none; slices into `text`. Read it with `Listing.status`.
    status: []const u8,
    /// Window title; slices into `text`.
    title: []const u8,
};

/// What a session's daemon did with a control command.
pub const ControlReply = union(enum) {
    result: client.ControlResult,
    /// The daemon holds the session's name but did not take the command
    /// in time.
    busy,
    /// No daemon holds the name, and its socket, if any, is deleted.
    gone,
};

/// Run a control command against a session, telling a daemon that is
/// gone from one that is slow. A non-null `timeout_ms` bounds the round
/// trip so a slow daemon cannot hang the caller.
pub fn controlSession(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    argv: []const []const u8,
    timeout_ms: ?u32,
) !ControlReply {
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    const result = client.control(alloc, sock, argv, timeout_ms) catch |err| switch (err) {
        error.Timeout => return .busy,
        // A daemon refuses connections while its backlog is full, and an
        // EOF may mean it died before replying, so only a free lock shows
        // that it is gone.
        error.FileNotFound, error.ConnectionRefused, error.ConnectionLost => {
            const stale = try claimpkg.removeStale(alloc, dir, name);
            return if (stale) .gone else .busy;
        },
        else => return err,
    };
    return .{ .result = result };
}

/// What a session's daemon said when asked for its info.
pub const InfoReply = union(enum) {
    info: SessionInfo,
    busy,
    gone,
};

/// Query a session daemon, deleting the socket when the daemon is gone.
pub fn sessionInfo(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, timeout_ms: u32) !InfoReply {
    const result = switch (try controlSession(alloc, dir, name, &.{"info"}, timeout_ms)) {
        .result => |result| result,
        .busy => return .busy,
        .gone => return .gone,
    };
    errdefer alloc.free(result.text);
    if (!result.ok) return error.BadResponse;

    var it = std.mem.splitScalar(u8, result.text, '\t');
    _ = it.next() orelse return error.BadResponse; // name
    const attached = std.mem.eql(u8, it.next() orelse return error.BadResponse, "Attached");
    const idle_ms = std.fmt.parseInt(i64, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const out_idle_ms = std.fmt.parseInt(i64, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const unread = std.mem.eql(u8, it.next() orelse return error.BadResponse, "1");
    const bell_idle_ms = std.fmt.parseInt(i64, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const pid = std.fmt.parseInt(posix.pid_t, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const client_tty = it.next() orelse return error.BadResponse;
    const status = it.next() orelse return error.BadResponse;
    return .{
        .info = .{
            .text = result.text,
            .attached = attached,
            .idle_ms = idle_ms,
            .out_idle_ms = out_idle_ms,
            .unread = unread,
            .bell_idle_ms = bell_idle_ms,
            .pid = pid,
            .client = client_tty,
            .status = status,
            // The daemon strips control bytes from the title, so it holds no
            // tab and runs to the end of the payload.
            .title = it.rest(),
        },
    };
}

fn appendPadded(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !void {
    try out.appendSlice(alloc, text);
    var i = text.len;
    while (i < width) : (i += 1) try out.append(alloc, ' ');
}

/// Human idle durations for `ls`: 12s, 5m, 3h.
fn fmtIdle(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(@max(0, ms), std.time.ms_per_s);
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(s, 60)}) catch "?";
    return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(s, 3600)}) catch "?";
}

pub const StatusReport = vt.osc.Command.ProgramStatus.Report;

/// Every session in a directory, by name, with what its daemon said.
/// Sessions whose daemon is gone are left out.
pub const Listing = struct {
    alloc: std.mem.Allocator,
    /// Every session name found, which the entries point into.
    names: [][]u8,
    entries: []Entry,
    /// The width of the name column, which fits every name and the
    /// header.
    name_width: usize,
    /// Reads the program status bodies the daemons report.
    status_parser: vt.osc.Parser,

    pub const Entry = struct {
        name: []const u8,
        reply: InfoReply,
    };

    pub fn init(alloc: std.mem.Allocator, dir: []const u8) !Listing {
        const names = try paths.listSessions(alloc, dir);
        errdefer freeNames(alloc, names);
        std.mem.sort([]u8, names, {}, lessThan);

        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| freeReply(alloc, entry.reply);
            entries.deinit(alloc);
        }
        var name_width: usize = "NAME".len;
        for (names) |name| {
            const reply = sessionInfo(alloc, dir, name, info_timeout_ms) catch continue;
            if (reply == .gone) continue;
            errdefer freeReply(alloc, reply);
            try entries.append(alloc, .{ .name = name, .reply = reply });
            name_width = @max(name_width, name.len);
        }
        return .{
            .alloc = alloc,
            .names = names,
            .entries = try entries.toOwnedSlice(alloc),
            .name_width = name_width,
            .status_parser = .init(alloc),
        };
    }

    pub fn deinit(self: *Listing) void {
        for (self.entries) |entry| freeReply(self.alloc, entry.reply);
        self.alloc.free(self.entries);
        freeNames(self.alloc, self.names);
        self.status_parser.deinit();
    }

    fn lessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn freeNames(alloc: std.mem.Allocator, names: [][]u8) void {
        for (names) |name| alloc.free(name);
        alloc.free(names);
    }

    fn freeReply(alloc: std.mem.Allocator, reply: InfoReply) void {
        switch (reply) {
            .info => |info| alloc.free(info.text),
            .busy, .gone => {},
        }
    }

    /// The session's program status, or null when it has none. The
    /// report is valid until the next call.
    pub fn status(self: *Listing, info: SessionInfo) ?StatusReport {
        if (info.status.len == 0) return null;
        const parser = &self.status_parser;
        parser.reset();
        parser.nextSlice("7501;");
        parser.nextSlice(info.status);
        const command = parser.end(0x1b) orelse return null;
        return command.program_status.report;
    }

    /// The table's header row, without a line ending.
    pub fn appendHeader(self: *const Listing, out: *std.ArrayList(u8)) !void {
        try appendPadded(self.alloc, out, "NAME", self.name_width);
        try out.appendSlice(self.alloc, "  STATE     IDLE  STATUS   TITLE");
    }

    /// The entry's row of the table, without a line ending.
    pub fn appendRow(self: *Listing, out: *std.ArrayList(u8), entry: Entry) !void {
        try appendPadded(self.alloc, out, entry.name, self.name_width);
        const info = switch (entry.reply) {
            .info => |info| info,
            .busy => return out.appendSlice(self.alloc, "  busy      -"),
            .gone => unreachable,
        };
        var idle_buf: [32]u8 = undefined;
        const report = self.status(info);
        try out.print(self.alloc, "  {s: <8}  {s: <4}  {s: <7}  {s}", .{
            if (info.attached) "attached" else "detached",
            fmtIdle(&idle_buf, info.idle_ms),
            if (report) |r| @tagName(r.state) else "-",
            info.title,
        });
    }
};

test "fmtIdle" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0s", fmtIdle(&buf, 400));
    try std.testing.expectEqualStrings("12s", fmtIdle(&buf, 12_500));
    try std.testing.expectEqualStrings("5m", fmtIdle(&buf, 5 * 60_000));
    try std.testing.expectEqualStrings("2h", fmtIdle(&buf, 2 * 3_600_000));
}
