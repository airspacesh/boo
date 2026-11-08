//! The session daemon: owns the window (PTY + libghostty terminal
//! state), accepts client connections on a Unix socket, routes
//! input/output, and executes control commands.
//!
//! Single-threaded poll(2) loop. One client may be attached at a time
//! (attaching steals); any number of transient control connections
//! may come and go.
//!
//! Client sockets are non-blocking and per-connection output is queued
//! and flushed on POLLOUT, so a client that reads slowly never blocks
//! the loop. A blocking write here would stall the PTY and every other
//! client until the slow reader caught up.

const std = @import("std");
const posix = std.posix;

const claimpkg = @import("claim.zig");
const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
const copymode = @import("copymode.zig");
const altscreen = @import("altscreen.zig");
const paths = @import("paths.zig");
const reap = @import("reap.zig");
const windowpkg = @import("window.zig");
const Window = windowpkg.Window;

const log = std.log.scoped(.daemon);

pub const Options = struct {
    name: []const u8,
    argv: []const []const u8,
    rows: u16 = 24,
    cols: u16 = 80,
    /// Working directory for the session command; null inherits the
    /// daemon's own directory.
    cwd: ?[]const u8 = null,
    /// A pipe the daemon closes once the session command runs, after
    /// writing the name of the error that kept it from starting, if any.
    started_fd: ?posix.fd_t = null,
};

/// How much queued-but-unsent output a connection may hold. The daemon
/// never blocks on a client write (see `Conn.flush`), so a client that
/// stops reading would otherwise grow its queue without bound. An
/// attached client this far behind stops receiving output until it has
/// read the queue, and then gets a fresh frame (see `View`). Any other
/// connection is dropped. Generous, so an ordinary burst never trips it.
const max_conn_out: usize = 8 * 1024 * 1024;

/// The largest number of rows or columns a session takes, beyond any
/// real terminal (4096 columns of 4-pixel cells overflow a 16K display).
/// The terminal's memory and the time to resize it grow with rows times
/// columns, and 65535 by 65535 wedges the daemon for minutes.
pub const max_dimension: u16 = 4096;

/// How long the daemon stops accepting after accept fails, as it does
/// with every descriptor in use. The failed connection stays in the
/// backlog, so accepting again at once would spin.
const accept_backoff_ms: i64 = 100;

/// Upper bound on how long teardown waits for queued finals to drain.
const shutdown_drain_ms: i64 = 250;

/// How an attached client's canvas relates to the window.
const View = enum {
    /// The canvas shows the window as it is. In passthrough, output
    /// keeps it that way.
    current,
    /// The canvas needs a fresh frame, which goes out once the client has
    /// read everything queued. Output is withheld until then, so a client
    /// that reads slowly gets one frame of the latest state instead of a
    /// backlog it would only see the end of.
    stale,
    /// A frame went out while the window's parser was partway through a
    /// sequence or character. The rest of it would garble the fresh
    /// canvas, so output is withheld until the parser has finished it,
    /// and then the canvas gets another frame.
    torn,
};

const Conn = struct {
    alloc: std.mem.Allocator,
    fd: posix.fd_t,
    decoder: protocol.Decoder,
    attached: bool = false,
    /// The attached client is in copy mode. Output stops passing through
    /// to it, and its keys scroll a view of the window's history.
    copy_mode: bool = false,
    view: View = .current,
    /// The connection is finished: its fd is dead or it was dropped.
    /// `sweep` closes the fd and frees it.
    closed: bool = false,
    /// A final frame (detach or exit) is queued: read no more input and
    /// close once `out` has drained, so the client still sees it.
    shutdown: bool = false,
    /// Frames queued for the client but not yet written to the socket.
    /// The socket is non-blocking, so a slow reader backs up here
    /// instead of blocking the loop. Drained on POLLOUT.
    out: std.ArrayList(u8) = .empty,
    /// Limit on `out` (see `max_conn_out`); a field so tests can shrink
    /// it.
    out_cap: usize = max_conn_out,

    /// Whether `out` has grown past `out_cap`.
    fn behind(self: *const Conn) bool {
        return self.out.items.len > self.out_cap;
    }

    /// Queue a frame and write what the socket will take right now.
    /// Never blocks: the unsent remainder waits for the next POLLOUT. A
    /// connection already `behind` is dropped rather than buffered
    /// without bound.
    fn send(self: *Conn, msg_type: protocol.MsgType, payload: []const u8) void {
        if (self.closed or self.shutdown) return;
        if (self.behind()) {
            self.drop();
            return;
        }
        protocol.appendMsg(self.alloc, &self.out, msg_type, payload) catch {
            self.drop();
            return;
        };
        self.flush();
    }

    /// Write as much of `out` as the socket accepts without blocking. A
    /// full send buffer (WouldBlock) just leaves the remainder for the
    /// next POLLOUT; any other error drops the connection.
    fn flush(self: *Conn) void {
        if (self.closed) return;
        var off: usize = 0;
        while (off < self.out.items.len) {
            const n = posix.write(self.fd, self.out.items[off..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.drop();
                    return;
                },
            };
            if (n == 0) break;
            off += n;
        }
        if (off == self.out.items.len) {
            self.out.clearRetainingCapacity();
        } else if (off > 0) {
            const remaining = self.out.items.len - off;
            std.mem.copyForwards(u8, self.out.items[0..remaining], self.out.items[off..]);
            self.out.shrinkRetainingCapacity(remaining);
        }
    }

    /// Discard queued output and mark the connection dead.
    fn drop(self: *Conn) void {
        self.closed = true;
        self.out.clearRetainingCapacity();
    }

    fn deinit(self: *Conn) void {
        self.out.deinit(self.alloc);
        self.decoder.deinit();
    }
};

fn monotonicMs() i64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch unreachable;
    return ts.sec * std.time.ms_per_s + @divTrunc(ts.nsec, std.time.ns_per_ms);
}

/// Append the UTF-8 `text` without the control characters a terminal
/// acts on: C0, DEL, and C1, which some terminals take as ESC
/// sequences. ls prints the result, so a bad byte would reach the
/// user's terminal. Bytes that are not UTF-8 are dropped too.
fn appendPrintable(alloc: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        const end = @min(i + len, text.len);
        const char = text[i..end];
        i = end;
        const cp = std.unicode.utf8Decode(char) catch continue;
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) continue;
        try out.appendSlice(alloc, char);
    }
}

var sigchld_pipe: posix.fd_t = -1;

fn handleSigchld(_: c_int) callconv(.c) void {
    if (sigchld_pipe >= 0) {
        _ = posix.write(sigchld_pipe, "c") catch {};
    }
}

pub const Daemon = struct {
    alloc: std.mem.Allocator,
    opts: Options,

    win: ?*Window = null,

    conns: std.ArrayList(*Conn) = .empty,
    key_parser: keys.Parser = .{},
    /// Runs from the key parser's latest input, so a key it holds
    /// resolves once `keys.hold_timeout_ms` pass without more.
    key_input_timer: std.time.Timer,

    /// Owned replacement for opts.name after a rename. The startup
    /// value is borrowed from the caller.
    owned_name: ?[]u8 = null,
    /// The name this daemon serves, or null once it has stopped
    /// accepting clients.
    claim: ?claimpkg.Claim,

    rows: u16,
    cols: u16,

    /// Wall-clock time (milliseconds) of the most recent window output
    /// or client input; reported as session idle time.
    last_activity_ms: i64 = 0,

    /// Output arrived while no client was attached: the session has
    /// activity you have not seen. `ls` reports it; attaching clears it.
    unread: bool = false,

    /// Wall-clock time (milliseconds) of the last bell that rang while
    /// no client was attached, or 0 for none since you last looked. A
    /// bell is an explicit "your turn" request; the info reply reports
    /// it as an age so callers can combine it with output idle time.
    /// Attaching clears it.
    last_bell_ms: i64 = 0,

    sig_read: posix.fd_t = -1,
    quitting: bool = false,

    /// Monotonic time (milliseconds) before which the loop does not
    /// accept, after accept failed.
    accept_resume_ms: i64 = 0,

    /// Serve the session until it ends, then release `claim`.
    pub fn run(alloc: std.mem.Allocator, claim: claimpkg.Claim, opts: Options) !void {
        var self: Daemon = .{
            .alloc = alloc,
            .opts = opts,
            .claim = claim,
            .rows = opts.rows,
            .cols = opts.cols,
            .last_activity_ms = std.time.milliTimestamp(),
            .key_input_timer = try std.time.Timer.start(),
        };
        defer self.deinit();

        // Reap children via the self-pipe trick.
        const pipe_fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        self.sig_read = pipe_fds[0];
        sigchld_pipe = pipe_fds[1];
        posix.sigaction(posix.SIG.CHLD, &.{
            .handler = .{ .handler = handleSigchld },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART | posix.SA.NOCLDSTOP,
        }, null);

        // A dying client must never kill the session.
        posix.sigaction(posix.SIG.PIPE, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        posix.sigaction(posix.SIG.HUP, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);

        self.win = createWindow(self.alloc, opts.name, opts.argv, self.rows, self.cols, opts.cwd) catch |err| {
            if (opts.started_fd) |fd| {
                protocol.writeAll(fd, @errorName(err)) catch {};
                posix.close(fd);
            }
            return err;
        };
        if (opts.started_fd) |fd| posix.close(fd);

        try self.loop();
    }

    fn deinit(self: *Daemon) void {
        if (self.win) |w| w.destroy();
        for (self.conns.items) |c| {
            posix.close(c.fd);
            c.deinit();
            self.alloc.destroy(c);
        }
        self.conns.deinit(self.alloc);
        self.retireListener();
        if (self.owned_name) |n| self.alloc.free(n);
        if (self.sig_read >= 0) posix.close(self.sig_read);
        if (sigchld_pipe >= 0) posix.close(sigchld_pipe);
    }

    /// Give up the session's name. Its socket goes, so new clients
    /// resolve "no session" instead of connecting to a dying daemon and
    /// reading EOF, and a new session may take the name.
    fn retireListener(self: *Daemon) void {
        const claim = self.claim orelse return;
        claim.release(self.alloc);
        self.claim = null;
    }

    fn loop(self: *Daemon) !void {
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.alloc);

        // Parallel array describing what each pollfd refers to.
        const Ref = union(enum) {
            listen,
            sigchld,
            conn: *Conn,
            window: *Window,
        };
        var refs: std.ArrayList(Ref) = .empty;
        defer refs.deinit(self.alloc);

        var buf: [32 * 1024]u8 = undefined;

        while (!self.quitting) {
            fds.clearRetainingCapacity();
            refs.clearRetainingCapacity();

            // poll skips a negative fd, so a retired or paused listener
            // needs no special case.
            const now_ms = monotonicMs();
            const accepting = now_ms >= self.accept_resume_ms;
            const listen_fd = if (self.claim != null and accepting) self.claim.?.listen_fd else -1;
            try fds.append(self.alloc, .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 });
            try refs.append(self.alloc, .listen);
            try fds.append(self.alloc, .{ .fd = self.sig_read, .events = posix.POLL.IN, .revents = 0 });
            try refs.append(self.alloc, .sigchld);
            for (self.conns.items) |c| {
                if (c.closed) continue;
                // A connection whose final frame has drained is done;
                // close it so sweep can free it this cycle.
                if (c.shutdown and c.out.items.len == 0) {
                    c.closed = true;
                    continue;
                }
                var events: i16 = 0;
                // Read input until shutdown; a shutdown conn only
                // drains its queued tail.
                if (!c.shutdown) events |= posix.POLL.IN;
                // Watch for writability whenever output is queued.
                if (c.out.items.len > 0) events |= posix.POLL.OUT;
                try fds.append(self.alloc, .{ .fd = c.fd, .events = events, .revents = 0 });
                try refs.append(self.alloc, .{ .conn = c });
            }
            if (self.liveWindow()) |w| {
                if (w.pty_fd >= 0) {
                    try fds.append(self.alloc, .{ .fd = w.pty_fd, .events = posix.POLL.IN, .revents = 0 });
                    try refs.append(self.alloc, .{ .window = w });
                }
            }

            const key_wait_ms = self.heldKeyTimeoutMs();
            const accept_wait_ms: i32 = if (accepting) -1 else @intCast(self.accept_resume_ms - now_ms);
            // A wait of -1 has no end, so poll waits for the earlier of
            // the two that has one.
            const poll_timeout_ms = if (key_wait_ms < 0)
                accept_wait_ms
            else if (accept_wait_ms < 0)
                key_wait_ms
            else
                @min(key_wait_ms, accept_wait_ms);
            _ = try posix.poll(fds.items, poll_timeout_ms);

            for (fds.items, refs.items) |pfd, ref| {
                if (pfd.revents == 0) continue;
                switch (ref) {
                    .listen => self.acceptConns(),
                    .sigchld => self.reapChildren(&buf),
                    .conn => |c| {
                        // Drain queued output first so a writable socket
                        // makes room before any new input is handled.
                        if ((pfd.revents & posix.POLL.OUT) != 0) c.flush();
                        if (!c.closed and !c.shutdown and
                            (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0)
                        {
                            self.serviceConn(c, &buf);
                        }
                    },
                    .window => |w| self.serviceWindow(w, &buf),
                }
                if (self.quitting) break;
            }
            if (self.heldKeyTimeoutMs() == 0) self.resolveHeldKey();

            // Frames go out once per pass, so everything that invalidated
            // the view in this pass costs one frame.
            if (self.attachedConn()) |c| self.sendFrame(c);
            self.sweep();
            if (self.liveWindow() == null) {
                self.broadcastExit("command exited");
                break;
            }
        }

        // Give queued finals (detach, exit, command replies) a bounded
        // chance to reach clients before the fds close in deinit.
        self.drainOutbound();
    }

    /// Accept every connection waiting in the backlog, so a burst of
    /// clients cannot fill it while the loop serves one per pass.
    fn acceptConns(self: *Daemon) void {
        const listen_fd = self.claim.?.listen_fd;
        while (true) {
            // Non-blocking so the daemon's writes to this client never
            // block the loop; output the socket cannot take yet is queued
            // on the Conn and flushed on POLLOUT.
            const fd = posix.accept(listen_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                error.ConnectionAborted => continue,
                else => {
                    log.warn("accept failed, pausing for {d} ms: {}", .{ accept_backoff_ms, err });
                    self.accept_resume_ms = monotonicMs() + accept_backoff_ms;
                    return;
                },
            };
            const conn = self.alloc.create(Conn) catch {
                posix.close(fd);
                return;
            };
            conn.* = .{ .alloc = self.alloc, .fd = fd, .decoder = .init(self.alloc) };
            self.conns.append(self.alloc, conn) catch {
                posix.close(fd);
                self.alloc.destroy(conn);
                return;
            };
        }
    }

    fn reapChildren(self: *Daemon, buf: []u8) void {
        _ = posix.read(self.sig_read, buf) catch {};
        // Window teardown happens via PTY EOF, which arrives after all
        // remaining output has been drained; this only reaps zombies.
        var status: c_int = undefined;
        while (std.c.waitpid(-1, &status, std.c.W.NOHANG) > 0) {}
    }

    fn serviceConn(self: *Daemon, conn: *Conn, buf: []u8) void {
        const n = posix.read(conn.fd, buf) catch |err| switch (err) {
            // A POLLOUT-only wake (or spurious readiness) has nothing
            // to read yet; that is not an EOF.
            error.WouldBlock => return,
            else => {
                conn.closed = true;
                return;
            },
        };
        if (n == 0) {
            conn.closed = true;
            return;
        }
        conn.decoder.feed(buf[0..n]) catch {
            conn.closed = true;
            return;
        };
        while (true) {
            const msg = conn.decoder.next() catch {
                conn.closed = true;
                return;
            } orelse break;
            self.handleMsg(conn, msg) catch |err| {
                log.warn("error handling message: {}", .{err});
                conn.closed = true;
                return;
            };
            if (self.quitting or conn.closed) break;
        }
    }

    fn handleMsg(self: *Daemon, conn: *Conn, msg: protocol.Msg) !void {
        switch (msg.type) {
            .bg_color => {
                // The client probed its real terminal's background and
                // reported it; the window uses it to answer OSC 11
                // queries and the color-scheme DSR from the session.
                const bg = protocol.RgbPayload.decode(msg.payload) catch return;
                if (self.liveWindow()) |w| w.setBackground(bg);
            },

            .attach => {
                const request = try protocol.AttachPayload.decode(msg.payload);
                // A client running inside this session would draw the
                // session into itself, and stealing it would leave the
                // user's own view detached.
                if (self.liveWindow()) |w| if (w.tty_device == request.tty_device) {
                    conn.send(.detached, "nested");
                    conn.shutdown = true;
                    return;
                };
                const size = request.size;
                // Steal from any previously attached client.
                for (self.conns.items) |other| {
                    if (other != conn and other.attached) {
                        other.send(.detached, "stolen");
                        other.attached = false;
                        // Let the steal notice drain before closing.
                        other.shutdown = true;
                    }
                }
                conn.attached = true;
                // Attaching is viewing, so the session's output is no
                // longer unseen.
                self.unread = false;
                self.last_bell_ms = 0;
                self.key_parser = .{};
                self.resizeWindow(size.rows, size.cols);
                self.updatePassthrough();
                conn.view = .stale;
            },

            .input => {
                if (!conn.attached) return;
                self.last_activity_ms = std.time.milliTimestamp();
                self.key_input_timer.reset();
                // When the window runs the kitty keyboard protocol
                // or modifyOtherKeys, the client's terminal mirrors
                // it and sends the prefix key encoded.
                // A copy mode frame resets the client's keyboard modes.
                const prot: keys.Protocols = if (conn.copy_mode) .{} else if (self.liveWindow()) |w| .{
                    .kitty = w.kittyKeysActive(),
                    .modify = w.modifyKeysActive(),
                } else .{};
                try self.key_parser.feed(msg.payload, prot, KeyHandler{ .daemon = self, .conn = conn });
            },

            .resize => {
                if (!conn.attached) return;
                const size = try protocol.SizePayload.decode(msg.payload);
                self.resizeWindow(size.rows, size.cols);
                // The client's terminal and the window each fit the old
                // screen to the new size in their own way, so the canvas
                // is repainted to match the window.
                conn.view = .stale;
            },

            .detach_req => {
                if (!conn.attached) return;
                self.detachConn(conn, "detached");
            },

            .command => try self.handleCommand(conn, msg.payload),

            else => {},
        }
    }

    fn handleKeyCommand(self: *Daemon, conn: *Conn, cmd: keys.Command) !void {
        // A detach earlier in the same input batch ended the
        // attachment. Bytes after the detach key (auto-repeats of a
        // held C-d arriving coalesced, or keys typed during the
        // detach round trip) belong to no window; forwarding them
        // would EOF or garble the program the user just left.
        if (!conn.attached) return;
        switch (cmd) {
            .forward => |bytes| {
                const window_bytes = if (conn.copy_mode) self.copyModeInput(conn, bytes) else bytes;
                if (self.liveWindow()) |w| w.writeInput(window_bytes) catch {};
            },
            .detach => |byte| self.detachConn(
                conn,
                // A C-d triggered detach warns the client that the
                // user may be holding the byte that EOFs shells.
                if (byte == 0x04) "detached-eof" else "detached",
            ),
            .redraw => conn.view = .stale,
            .copy_mode => self.enterCopyMode(conn),
            .unknown => |byte| if (std.ascii.isPrint(byte))
                self.message(conn, "unknown key: ^A {c}", .{byte})
            else
                self.message(conn, "unknown key: ^A ^{c}", .{byte ^ 0x40}),
        }
    }

    const KeyHandler = struct {
        daemon: *Daemon,
        conn: *Conn,

        pub fn command(h: KeyHandler, cmd: keys.Command) !void {
            try h.daemon.handleKeyCommand(h.conn, cmd);
        }
    };

    /// How long poll may wait before a key the parser holds resolves.
    /// It is 0 once the key is due, and -1, which waits indefinitely,
    /// when the parser holds none.
    fn heldKeyTimeoutMs(self: *Daemon) i32 {
        if (!self.key_parser.holding()) return -1;
        const waited_ms = self.key_input_timer.read() / std.time.ns_per_ms;
        return @intCast(keys.hold_timeout_ms -| waited_ms);
    }

    /// No more input arrived for the key the parser holds, so its held
    /// bytes are the whole key.
    fn resolveHeldKey(self: *Daemon) void {
        const conn = self.attachedConn() orelse {
            // The client that sent the bytes has gone.
            self.key_parser = .{};
            return;
        };
        self.key_parser.flushHeld(KeyHandler{ .daemon = self, .conn = conn }) catch |err| {
            log.warn("error handling held key: {}", .{err});
            conn.closed = true;
        };
    }

    fn handleCommand(self: *Daemon, conn: *Conn, payload: []const u8) !void {
        const argv = try protocol.decodeArgv(self.alloc, payload);
        defer self.alloc.free(argv);
        if (argv.len == 0) {
            conn.send(.err, "empty command");
            return;
        }

        const now = std.time.milliTimestamp();
        const cmd = argv[0];
        if (std.mem.eql(u8, cmd, "send")) {
            if (argv.len != 2) {
                conn.send(.err, "usage: send <bytes>");
                return;
            }
            if (self.liveWindow()) |w| {
                w.writeInput(argv[1]) catch {
                    conn.send(.err, "window write failed");
                    return;
                };
                self.last_activity_ms = now;
                conn.send(.ok, "");
            } else conn.send(.err, "no window");
        } else if (std.mem.eql(u8, cmd, "peek")) {
            const scrollback = argv.len > 1 and std.mem.eql(u8, argv[1], "scrollback");
            if (self.liveWindow()) |w| {
                const text = if (scrollback)
                    try w.plainScrollback(self.alloc)
                else
                    try w.plainScreen(self.alloc);
                defer self.alloc.free(text);
                // Header line with window metadata, then the dump. The
                // title is sanitized so it cannot contain the newline
                // that terminates the header.
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(self.alloc);
                const cursor = &w.term.screens.active.cursor;
                try out.print(self.alloc, "{d}\t{d}\t{d}\t{d}\t", .{
                    self.rows,
                    self.cols,
                    cursor.y + 1,
                    cursor.x + 1,
                });
                try appendPrintable(self.alloc, &out, w.title());
                try out.append(self.alloc, '\n');
                try out.appendSlice(self.alloc, text);
                conn.send(.ok, out.items);
            } else conn.send(.err, "no window");
        } else if (std.mem.eql(u8, cmd, "info")) {
            var attached = false;
            for (self.conns.items) |c| {
                if (c.attached and !c.closed) attached = true;
            }
            const idle: i64 = @max(0, now - self.last_activity_ms);
            const out_idle: i64 = if (self.liveWindow()) |w|
                @max(0, now - w.last_output_ms)
            else
                0;
            // Age of the last bell that rang while you were away, or -1
            // for none. Reported against the same `now` as out_idle so
            // callers can compare the two.
            const bell_idle: i64 = if (self.last_bell_ms != 0)
                @max(0, now - self.last_bell_ms)
            else
                -1;
            // The session command's pid, or -1 once it has exited.
            const pid: posix.pid_t = if (self.liveWindow()) |w| w.child_pid else -1;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.alloc);
            try out.print(self.alloc, "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t", .{
                self.opts.name,
                if (attached) "Attached" else "Detached",
                idle,
                out_idle,
                @intFromBool(self.unread),
                bell_idle,
                pid,
            });
            // Window title last; sanitized, so it cannot contain the
            // tabs that separate the fields.
            if (self.liveWindow()) |w| {
                try appendPrintable(self.alloc, &out, w.title());
            }
            conn.send(.ok, out.items);
        } else if (std.mem.eql(u8, cmd, "rename")) {
            if (argv.len != 2) {
                conn.send(.err, "usage: rename <new-name>");
                return;
            }
            self.rename(conn, argv[1]);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            // Retire the listener before acking: by the time the kill
            // client sees the reply, the socket file is gone, so a
            // follow-up command resolves "no session" instead of
            // connecting to the dying daemon and reading EOF.
            self.retireListener();
            conn.send(.ok, "");
            // Tell attached clients the session ended and flush those
            // notices (and the ack above) before the teardown, so the
            // kill returns and clients learn the outcome without waiting
            // on a stubborn descendant's grace period.
            self.broadcastExit("session terminated");
            self.drainOutbound();
            // End the whole tree the session started, not just the shell,
            // so a grandchild that ignores the hangup or escaped into its
            // own process group cannot outlive the session and keep its
            // resources (the bug in issue #97).
            if (self.win) |w| reap.terminateTree(self.alloc, w.child_pid);
        } else {
            conn.send(.err, "unknown command");
        }
    }

    /// Move the session to a new name by claiming the new name and
    /// retiring the old one. Established connections survive, and new
    /// clients find the session under the new name. The claim refuses a
    /// name that a live session holds. A fresh bind also keeps
    /// /proc/net/unix naming the socket's real path, which
    /// systemd-tmpfiles checks before it ages a socket out of /tmp.
    fn rename(self: *Daemon, conn: *Conn, new_name: []const u8) void {
        paths.validateName(new_name) catch {
            conn.send(.err, "invalid session name");
            return;
        };
        if (std.mem.eql(u8, new_name, self.opts.name)) {
            conn.send(.ok, "");
            return;
        }

        const dir = std.fs.path.dirname(self.claim.?.socket_path) orelse ".";
        const new_owned_name = self.alloc.dupe(u8, new_name) catch {
            conn.send(.err, "rename failed");
            return;
        };
        const claimed = claimpkg.claim(self.alloc, dir, new_name) catch {
            self.alloc.free(new_owned_name);
            conn.send(.err, "rename failed");
            return;
        };
        const new_claim = claimed orelse {
            self.alloc.free(new_owned_name);
            conn.send(.err, "a session with that name already exists");
            return;
        };
        self.retireListener();
        self.claim = new_claim;

        if (self.owned_name) |n| self.alloc.free(n);
        self.owned_name = new_owned_name;
        self.opts.name = new_owned_name;
        log.info("renamed to {s}", .{new_name});
        conn.send(.ok, "");
    }

    fn serviceWindow(self: *Daemon, win: *Window, buf: []u8) void {
        const n = posix.read(win.pty_fd, buf) catch |err| n: {
            // EIO means the slave side is fully closed: window is done.
            if (err != error.InputOutput) {
                log.warn("window read error: {}", .{err});
            }
            break :n 0;
        };
        if (n == 0) {
            win.dead = true;
            return;
        }
        const chunk = buf[0..n];
        const now = std.time.milliTimestamp();
        win.last_output_ms = now;
        self.last_activity_ms = now;
        // Output produced while nothing is attached marks the session
        // unread, so `ls` can flag activity since you last looked.
        // Attaching clears it.
        const detached = self.attachedConn() == null;
        if (detached) self.unread = true;

        // Strip OSC 11 background queries up front and answer them from
        // the reported terminal background. They must not also reach an
        // attached client's real terminal, which would answer them a
        // second time, so this runs before any passthrough forwarding.
        // The filter only removes bytes, so the cleaned copy never
        // outgrows the chunk; on the impossible overflow, fall back to
        // the raw chunk rather than dropping output.
        var clean_buf: [32 * 1024]u8 = undefined;
        var clean_writer = std.Io.Writer.fixed(&clean_buf);
        const cleaned = cleaned: {
            win.filterColorQueries(chunk, &clean_writer) catch break :cleaned chunk;
            break :cleaned clean_writer.buffered();
        };

        const conn = (if (win.passthrough) self.attachedConn() else null) orelse {
            // Not passed through: the window answers queries itself.
            win.feed(cleaned);
            self.noteBell(win, detached, now);
            // Copy mode shows the output's effect. At the bottom of the
            // history its viewport follows the output. Scrolled up, the
            // viewport stays on the rows it shows, but the tag's counts
            // change, and the history may drop those rows.
            const viewer = self.attachedConn() orelse return;
            if (viewer.copy_mode) viewer.view = .stale;
            return;
        };

        // A client this far behind gets a frame once it has caught up,
        // instead of more output.
        if (conn.behind()) conn.view = .stale;
        if (conn.view != .current) {
            win.feedDiscarded(cleaned);
            self.noteBell(win, detached, now);
            return;
        }

        // Forward raw bytes, minus screen switches: the client canvas
        // cannot switch screens. When the window may have switched, the
        // view goes stale, and the rest of the chunk is withheld for the
        // repaint to cover.
        var out_buf: [32 * 1024 + altscreen.held_capacity]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buf);
        // out_buf holds the whole chunk and the bytes the filter held over
        // from the last one.
        const result = win.alt_filter.feed(cleaned, &writer) catch unreachable;

        // Bytes up to the toggle reach the client's real terminal, which
        // answers any queries among them. The repaint covers the rest, but
        // it cannot answer queries, so the window must.
        win.feed(cleaned[0..result.consumed]);
        win.feedDiscarded(cleaned[result.consumed..]);
        self.noteBell(win, detached, now);

        const filtered = writer.buffered();
        if (filtered.len > 0) conn.send(.output, filtered);
        if (result.switched) conn.view = .stale;
    }

    /// Consume the window's bell latch. A bell that rang while no client
    /// was attached records the time as an explicit "your turn" signal;
    /// a bell seen while attached already reached the client's terminal,
    /// so it is only cleared.
    fn noteBell(self: *Daemon, win: *Window, detached: bool, now: i64) void {
        if (!win.bell) return;
        win.bell = false;
        if (detached) self.last_bell_ms = now;
    }

    /// Remove closed conns. Runs after every poll dispatch so
    /// iteration above never sees mutation.
    fn sweep(self: *Daemon) void {
        var removed = false;
        var ci: usize = 0;
        while (ci < self.conns.items.len) {
            const c = self.conns.items[ci];
            if (!c.closed) {
                ci += 1;
                continue;
            }
            posix.close(c.fd);
            c.deinit();
            self.alloc.destroy(c);
            _ = self.conns.swapRemove(ci);
            removed = true;
        }
        // A dropped or abruptly closed client may have been the
        // attached view; recompute passthrough so the window resumes
        // answering its own queries once no client remains, instead of
        // staying silent waiting for a terminal that is gone.
        if (removed) self.updatePassthrough();
    }

    // -- Window management ------------------------------------------------

    fn createWindow(
        alloc: std.mem.Allocator,
        session_name: []const u8,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
        cwd_opt: ?[]const u8,
    ) !*Window {
        var env = try std.process.getEnvMap(alloc);
        defer env.deinit();
        try env.put("TERM", "xterm-256color");
        try env.put("BOO", session_name);

        var default_argv: [1][]const u8 = .{env.get("SHELL") orelse "/bin/sh"};
        const child_argv: []const []const u8 = if (argv.len > 0) argv else &default_argv;

        return Window.create(alloc, child_argv, &env, rows, cols, cwd_opt);
    }

    fn liveWindow(self: *Daemon) ?*Window {
        const w = self.win orelse return null;
        if (w.dead) return null;
        return w;
    }

    fn attachedConn(self: *Daemon) ?*Conn {
        for (self.conns.items) |c| {
            if (c.attached and !c.closed) return c;
        }
        return null;
    }

    fn updatePassthrough(self: *Daemon) void {
        const passing = if (self.attachedConn()) |conn| !conn.copy_mode else false;
        if (self.liveWindow()) |w| w.passthrough = passing;
    }

    fn resizeWindow(self: *Daemon, rows: u16, cols: u16) void {
        if (rows == 0 or cols == 0) return;
        // A client reports its terminal's real size, so a size past the
        // limit is capped rather than refused.
        self.rows = @min(rows, max_dimension);
        self.cols = @min(cols, max_dimension);
        if (self.liveWindow()) |w| {
            w.resize(self.rows, self.cols) catch |err| {
                log.warn("resize window failed: {}", .{err});
            };
        }
    }

    /// Start copy mode at the bottom of the history. The window stops
    /// passing output through, so it answers terminal queries itself.
    fn enterCopyMode(self: *Daemon, conn: *Conn) void {
        const win = self.liveWindow() orelse return;
        win.term.scrollViewport(.bottom);
        conn.copy_mode = true;
        self.updatePassthrough();
        conn.view = .stale;
    }

    fn leaveCopyMode(self: *Daemon, conn: *Conn) void {
        const win = self.liveWindow() orelse return;
        win.term.scrollViewport(.bottom);
        conn.copy_mode = false;
        self.updatePassthrough();
        conn.view = .stale;
    }

    /// Scroll copy mode's view by the keys in `input`. Returns the bytes
    /// after a key that leaves copy mode, which are the window's input.
    fn copyModeInput(self: *Daemon, conn: *Conn, input: []const u8) []const u8 {
        const win = self.liveWindow() orelse return "";
        var rest = input;
        while (rest.len > 0) {
            const key = copymode.decodeKey(rest);
            rest = rest[key.len..];
            const action = key.action orelse continue;
            if (action == .exit) {
                self.leaveCopyMode(conn);
                return rest;
            }
            win.term.scrollViewport(copymode.viewportScroll(action, win.term.rows));
        }
        conn.view = .stale;
        return "";
    }

    /// Send a stale or torn canvas its fresh frame once it is due (see
    /// `View`): a repaint, or in copy mode the viewport.
    fn sendFrame(self: *Daemon, conn: *Conn) void {
        if (conn.out.items.len > 0) return;
        const win = self.liveWindow() orelse return;
        switch (conn.view) {
            .current => return,
            .stale => {},
            .torn => if (!win.atGround()) return,
        }

        const bytes = (if (conn.copy_mode)
            win.copyModeFrame(self.alloc)
        else
            win.repaint(self.alloc)) catch |err| {
            log.warn("rendering a frame for the client failed: {}", .{err});
            return;
        };
        defer self.alloc.free(bytes);
        // The frame covers everything fed so far, so passthrough resumes
        // from a clean slate.
        win.alt_filter.reset();
        conn.view = if (win.atGround()) .current else .torn;
        conn.send(.output, bytes);
    }

    fn detachConn(self: *Daemon, conn: *Conn, reason: []const u8) void {
        conn.send(.detached, reason);
        conn.attached = false;
        // Close once the detach notice has drained, not before, so the
        // client still receives it.
        conn.shutdown = true;
        self.updatePassthrough();
    }

    fn broadcastExit(self: *Daemon, reason: []const u8) void {
        for (self.conns.items) |c| {
            if (c.closed or c.shutdown) continue;
            c.send(.exit, reason);
            // Drain the exit notice before closing (see drainOutbound).
            c.shutdown = true;
        }
        self.quitting = true;
    }

    /// Best-effort flush of every connection's queued output before
    /// teardown, so a final frame (detach, exit, command reply) still
    /// reaches a client that is reading. Bounded by `shutdown_drain_ms`
    /// so a client that stopped reading cannot delay shutdown.
    fn drainOutbound(self: *Daemon) void {
        const deadline = std.time.milliTimestamp() + shutdown_drain_ms;
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.alloc);
        while (true) {
            fds.clearRetainingCapacity();
            for (self.conns.items) |c| {
                if (c.closed) continue;
                c.flush();
                if (!c.closed and c.out.items.len > 0) {
                    fds.append(self.alloc, .{
                        .fd = c.fd,
                        .events = posix.POLL.OUT,
                        .revents = 0,
                    }) catch {};
                }
            }
            if (fds.items.len == 0) break;
            const now = std.time.milliTimestamp();
            if (now >= deadline) break;
            _ = posix.poll(fds.items, @intCast(deadline - now)) catch break;
        }
    }

    fn message(self: *Daemon, conn: *Conn, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(text);
        // Single-line status message at the bottom of the screen,
        // preserving cursor position.
        const flat = std.mem.replaceOwned(u8, self.alloc, text, "\n", " | ") catch return;
        defer self.alloc.free(flat);
        const seq = std.fmt.allocPrint(
            self.alloc,
            "\x1b7\x1b[{d};1H\x1b[0m\x1b[7m {s} \x1b[0m\x1b[K\x1b8",
            .{ self.rows, flat },
        ) catch return;
        defer self.alloc.free(seq);
        conn.send(.output, seq);
    }
};

test "appendPrintable drops C0, DEL, C1, and bytes that are not UTF-8" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendPrintable(alloc, &out, "a\tb\x7fc\u{9b}2J\xffd\u{e9}\u{1f47b}");
    try std.testing.expectEqualStrings("abc2Jd\u{e9}\u{1f47b}", out.items);
}

test "Conn.send queues output without blocking and flushes in order" {
    const alloc = std.testing.allocator;

    // A non-blocking pipe stands in for the client socket: writing to a
    // full pipe yields WouldBlock just as a full socket send buffer
    // does, so this exercises the queue/flush path without a client.
    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);

    var conn: Conn = .{ .alloc = alloc, .fd = fds[1], .decoder = .init(alloc) };
    defer {
        posix.close(fds[1]);
        conn.deinit();
    }

    const payload = "x" ** 1024;
    const frame_count: usize = 1000;

    // Nothing reads during this loop, so the pipe fills and the surplus
    // must land in conn.out rather than block the caller. (A blocking
    // write here would hang the test, which is the regression.)
    for (0..frame_count) |_| conn.send(.output, payload);
    try std.testing.expect(!conn.closed);
    try std.testing.expect(conn.out.items.len > 0);

    // Drain: flush what the pipe will take, read it back, repeat. Every
    // frame must arrive intact and in order.
    var decoder: protocol.Decoder = .init(alloc);
    defer decoder.deinit();
    var rbuf: [8192]u8 = undefined;
    var got: usize = 0;
    var guard: usize = 0;
    while (got < frame_count) {
        conn.flush();
        const n = posix.read(fds[0], &rbuf) catch |err| switch (err) {
            error.WouldBlock => {
                guard += 1;
                try std.testing.expect(guard < 1_000_000);
                continue;
            },
            else => return err,
        };
        try std.testing.expect(n != 0);
        try decoder.feed(rbuf[0..n]);
        while (try decoder.next()) |msg| {
            try std.testing.expectEqual(protocol.MsgType.output, msg.type);
            try std.testing.expectEqualStrings(payload, msg.payload);
            got += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), conn.out.items.len);
}

test "Conn.send drops a client that exceeds its output cap" {
    const alloc = std.testing.allocator;

    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);

    var conn: Conn = .{
        .alloc = alloc,
        .fd = fds[1],
        .decoder = .init(alloc),
        .out_cap = 64 * 1024,
    };
    defer {
        posix.close(fds[1]);
        conn.deinit();
    }

    // Nothing reads, so once the pipe is full the queue grows until it
    // trips out_cap and the connection is dropped instead of buffering
    // without bound. The bound on the loop keeps a regression from
    // hanging the test.
    const payload = "y" ** 4096;
    var i: usize = 0;
    while (!conn.closed and i < 10_000) : (i += 1) conn.send(.output, payload);

    try std.testing.expect(conn.closed);
    try std.testing.expectEqual(@as(usize, 0), conn.out.items.len);
}
