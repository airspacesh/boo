//! End-to-end tests that drive the real boo binary through a real
//! PTY: a test "terminal" (PTY master) hosts the attach client as
//! its controlling terminal, exactly like a user's terminal would.
//! Detached control flows go through the public subcommand CLI.

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const vt = @import("ghostty-vt");

const exe_path: []const u8 = build_options.exe_path;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;

const default_timeout_ms: u64 = 10_000;

/// Terminal ioctl request codes; Zig's std lacks the darwin set variants.
const Tio = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        const IOCSWINSZ: c_ulong = 0x80087467;
        const IOCSCTTY: c_ulong = 0x20007461;
    },
    else => struct {
        const IOCSWINSZ: c_ulong = std.c.T.IOCSWINSZ;
        const IOCSCTTY: c_ulong = std.c.T.IOCSCTTY;
    },
};

/// Per-test environment: an isolated socket directory under /tmp (kept
/// short because of sockaddr_un path limits).
const Harness = struct {
    alloc: std.mem.Allocator,
    dir: []u8,

    fn init(alloc: std.mem.Allocator) !Harness {
        var random_bytes: [6]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var suffix: [12]u8 = undefined;
        const hex = std.fmt.bufPrint(&suffix, "{x}", .{&random_bytes}) catch unreachable;
        const dir = try std.fmt.allocPrint(alloc, "/tmp/bootest-{s}", .{hex});
        errdefer alloc.free(dir);
        try std.fs.cwd().makePath(dir);
        return .{ .alloc = alloc, .dir = dir };
    }

    fn deinit(self: *Harness) void {
        // Best effort: terminate any session daemons still running.
        if (self.run(&.{ "kill", "--all" })) |result| {
            self.alloc.free(result.stdout);
            self.alloc.free(result.stderr);
        } else |_| {}
        std.Thread.sleep(50 * std.time.ns_per_ms);
        std.fs.cwd().deleteTree(self.dir) catch {};
        self.alloc.free(self.dir);
    }

    fn run(self: *Harness, argv: []const []const u8) !std.process.Child.RunResult {
        return self.runIn(null, argv);
    }

    /// Run a CLI command with an explicit working directory; cwd null
    /// inherits the test runner's directory.
    fn runIn(
        self: *Harness,
        cwd: ?[]const u8,
        argv: []const []const u8,
    ) !std.process.Child.RunResult {
        // exe_path is relative to the build root; resolve it so a
        // custom cwd does not break spawning.
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_abs = try std.fs.cwd().realpath(exe_path, &exe_buf);

        var full_argv: std.ArrayList([]const u8) = .empty;
        defer full_argv.deinit(self.alloc);
        try full_argv.append(self.alloc, exe_abs);
        try full_argv.appendSlice(self.alloc, argv);

        var env = try std.process.getEnvMap(self.alloc);
        defer env.deinit();
        try env.put("BOO_DIR", self.dir);

        return std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = full_argv.items,
            .cwd = cwd,
            .env_map = &env,
        });
    }

    /// Run a CLI command and require exit code 0.
    fn runOk(self: *Harness, argv: []const []const u8) !void {
        const result = try self.run(argv);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("boo {s} failed: {s}\n", .{ argv[0], result.stderr });
            return error.CommandFailed;
        }
    }

    /// Run a CLI command and require a specific exit code.
    fn runExit(self: *Harness, argv: []const []const u8, want: u32) !void {
        const result = try self.run(argv);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != want) {
            std.debug.print(
                "boo {s}: wanted exit {d}, got {any}: {s}\n",
                .{ argv[0], want, result.term, result.stderr },
            );
            return error.WrongExit;
        }
    }

    fn startDetached(self: *Harness, session: []const u8, cmd: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{ "new", session, "-d", "--" });
        try argv.appendSlice(self.alloc, cmd);
        const result = try self.run(argv.items);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("new -d failed: {s}\n", .{result.stderr});
            return error.StartFailed;
        }
        // The session name lands on stdout for scripts to capture.
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, session) != null);
        try self.waitSessionUp(session);
    }

    fn waitSessionUp(self: *Harness, session: []const u8) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            const result = try self.run(&.{ "peek", session });
            defer self.alloc.free(result.stdout);
            defer self.alloc.free(result.stderr);
            if (result.term == .Exited and result.term.Exited == 0) return;
            try deadline.tick("session did not come up");
        }
    }

    /// Type text into the session, followed by Enter.
    fn sendLine(self: *Harness, session: []const u8, text: []const u8) !void {
        try self.runOk(&.{ "send", session, "--text", text, "--enter" });
    }

    /// Poll the session's screen contents until `needle` shows up.
    /// Returns the matching peek output; caller frees.
    fn waitPeekContains(self: *Harness, session: []const u8, needle: []const u8) ![]u8 {
        var deadline = Deadline.init(default_timeout_ms);
        var last: ?[]u8 = null;
        errdefer if (last) |l| self.alloc.free(l);
        while (true) {
            const result = try self.run(&.{ "peek", session });
            self.alloc.free(result.stderr);
            if (last) |l| self.alloc.free(l);
            last = null;
            if (result.term == .Exited and result.term.Exited == 0) {
                last = result.stdout;
                if (std.mem.indexOf(u8, result.stdout, needle) != null) return result.stdout;
            } else {
                self.alloc.free(result.stdout);
            }
            deadline.tick("peek never contained needle") catch |err| {
                std.debug.print("--- last peek ---\n{s}\n---\n", .{last orelse "<none>"});
                return err;
            };
        }
    }

    /// Poll `ls --json` until the session's "unread" flag equals want.
    fn waitUnread(self: *Harness, session: []const u8, want: bool) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            const ls = try self.run(&.{ "ls", "--json" });
            defer self.alloc.free(ls.stdout);
            defer self.alloc.free(ls.stderr);
            if (ls.term == .Exited and ls.term.Exited == 0) {
                if (jsonUnread(self.alloc, ls.stdout, session)) |u| {
                    if (u == want) return;
                }
            }
            deadline.tick("unread flag never reached the wanted value") catch |err| {
                std.debug.print("--- last ls --json ---\n{s}\n---\n", .{ls.stdout});
                return err;
            };
        }
    }

    /// Poll `ls --json` until the session's bell ("your turn") presence
    /// matches `want`: a bell is present when bell_idle_ms is >= 0.
    fn waitBell(self: *Harness, session: []const u8, want: bool) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            const ls = try self.run(&.{ "ls", "--json" });
            defer self.alloc.free(ls.stdout);
            defer self.alloc.free(ls.stderr);
            if (ls.term == .Exited and ls.term.Exited == 0) {
                if (jsonBellIdle(self.alloc, ls.stdout, session)) |b| {
                    if ((b >= 0) == want) return;
                }
            }
            deadline.tick("bell flag never reached the wanted value") catch |err| {
                std.debug.print("--- last ls --json ---\n{s}\n---\n", .{ls.stdout});
                return err;
            };
        }
    }
};

/// The "unread" flag for `session` in a `boo ls --json` array, or null
/// when the session or field is absent or the JSON does not parse.
fn jsonUnread(alloc: std.mem.Allocator, json: []const u8, session: []const u8) ?bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return null;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return null,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, name, session)) continue;
        return switch (obj.get("unread") orelse return null) {
            .bool => |b| b,
            else => null,
        };
    }
    return null;
}

/// The "bell_idle_ms" value for `session` in a `boo ls --json` array, or
/// null when the session or field is absent or the JSON does not parse.
fn jsonBellIdle(alloc: std.mem.Allocator, json: []const u8, session: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return null;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return null,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, name, session)) continue;
        return switch (obj.get("bell_idle_ms") orelse return null) {
            .integer => |n| n,
            else => null,
        };
    }
    return null;
}

const Deadline = struct {
    end: i64,

    fn init(ms: u64) Deadline {
        return .{ .end = std.time.milliTimestamp() + @as(i64, @intCast(ms)) };
    }

    fn tick(self: *Deadline, comptime what: []const u8) !void {
        if (std.time.milliTimestamp() > self.end) {
            std.debug.print("timeout: " ++ what ++ "\n", .{});
            return error.Timeout;
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
};

/// A boo client process running on a real PTY owned by the test.
const PtyClient = struct {
    alloc: std.mem.Allocator,
    master: posix.fd_t,
    pid: posix.pid_t,
    output: std.ArrayList(u8) = .empty,
    exited: ?u32 = null,

    fn spawn(
        harness: *Harness,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
    ) !PtyClient {
        return spawnProgram(harness, exe_path, argv, rows, cols, &.{});
    }

    /// Like spawn, but runs an arbitrary program instead of the boo
    /// binary, e.g. a shell wrapping an attach the way a login shell
    /// does for a user. `env_extra` overrides or adds environment
    /// variables for the child.
    fn spawnProgram(
        harness: *Harness,
        program: []const u8,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
        env_extra: []const [2][]const u8,
    ) !PtyClient {
        const alloc = harness.alloc;

        // PTY pair.
        const master = posix_openpt(@bitCast(@as(u32, @bitCast(posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }))));
        if (master < 0) return error.OpenPtyFailed;
        errdefer posix.close(master);
        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;
        var path_buf: [128]u8 = undefined;
        if (ptsname_r(master, &path_buf, path_buf.len) != 0) return error.OpenPtyFailed;
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse return error.OpenPtyFailed;
        const slave_path = path_buf[0..path_len :0];

        // Open the slave before setting the size: macOS rejects
        // TIOCSWINSZ on the master until the slave has been opened.
        const slave = posix.openZ(slave_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0) catch return error.OpenPtyFailed;
        errdefer posix.close(slave);

        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(slave, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }

        // Exec args, prepared before fork.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const argv0 = try arena.dupeZ(u8, program);
        const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len + 1, null);
        argv_z[0] = argv0;
        for (argv, 1..) |arg, i| argv_z[i] = try arena.dupeZ(u8, arg);

        var env = try std.process.getEnvMap(arena);
        try env.put("BOO_DIR", harness.dir);
        for (env_extra) |pair| try env.put(pair[0], pair[1]);
        const envp = try std.process.createEnvironFromMap(arena, &env, .{});

        const pid = try posix.fork();
        if (pid == 0) {
            // Child: make the inherited PTY slave the controlling
            // terminal (login_tty pattern).
            _ = posix.setsid() catch posix.exit(127);
            if (ioctl(slave, Tio.IOCSCTTY, @as(c_ulong, 0)) != 0) {
                posix.exit(127);
            }
            posix.dup2(slave, 0) catch posix.exit(127);
            posix.dup2(slave, 1) catch posix.exit(127);
            posix.dup2(slave, 2) catch posix.exit(127);
            if (slave > 2) posix.close(slave);
            posix.close(master);
            const err = posix.execveZ(argv0, argv_z, envp);
            _ = err catch {};
            posix.exit(127);
        }

        posix.close(slave);
        return .{ .alloc = alloc, .master = master, .pid = pid };
    }

    fn deinit(self: *PtyClient) void {
        if (self.exited == null) {
            _ = kill(self.pid, posix.SIG.KILL);
            var status: c_int = undefined;
            _ = std.c.waitpid(self.pid, &status, 0);
        }
        posix.close(self.master);
        self.output.deinit(self.alloc);
    }

    fn send(self: *PtyClient, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) i += try posix.write(self.master, bytes[i..]);
    }

    fn setSize(self: *PtyClient, rows: u16, cols: u16) !void {
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(self.master, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
    }

    fn pump(self: *PtyClient, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{
            .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
        };
        const n = try posix.poll(&fds, timeout_ms);
        if (n == 0) return false;
        var buf: [4096]u8 = undefined;
        const got = posix.read(self.master, &buf) catch |err| switch (err) {
            error.InputOutput => return error.ClientGone,
            else => return err,
        };
        if (got == 0) return error.ClientGone;
        try self.output.appendSlice(self.alloc, buf[0..got]);
        return true;
    }

    /// Read output until `needle` appears anywhere in the accumulated
    /// stream. Fails loudly with the captured output on timeout.
    fn waitFor(self: *PtyClient, needle: []const u8) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (std.mem.indexOf(u8, self.output.items, needle) == null) {
            _ = self.pump(100) catch |err| switch (err) {
                error.ClientGone => {
                    if (std.mem.indexOf(u8, self.output.items, needle) != null) return;
                    std.debug.print(
                        "client exited; output so far:\n{s}\n",
                        .{self.output.items},
                    );
                    return err;
                },
                else => return err,
            };
            deadline.tick("waiting for output") catch |err| {
                std.debug.print(
                    "--- waiting for {s} --- captured:\n{s}\n---\n",
                    .{ needle, self.output.items },
                );
                return err;
            };
        }
    }

    /// Drop accumulated output so later waitFor calls only see new data.
    fn clearOutput(self: *PtyClient) void {
        self.output.clearRetainingCapacity();
    }

    fn waitExit(self: *PtyClient) !u32 {
        if (self.exited) |code| return code;
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            var status: c_int = undefined;
            const r = std.c.waitpid(self.pid, &status, std.c.W.NOHANG);
            if (r == self.pid) {
                const code: u32 = if (std.c.W.IFEXITED(@bitCast(status)))
                    std.c.W.EXITSTATUS(@bitCast(status))
                else
                    128;
                self.exited = code;
                return code;
            }
            // Keep draining the PTY so the client can't block on writes.
            _ = self.pump(0) catch {};
            try deadline.tick("waiting for client exit");
        }
    }
};

fn waitFileEquals(alloc: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const content = std.fs.cwd().readFileAlloc(alloc, path, 4096) catch "";
        defer if (content.len > 0) alloc.free(content);
        if (std.mem.eql(u8, content, expected)) return;
        deadline.tick("file never matched") catch |err| {
            std.debug.print("--- file {s} content: {s} (wanted {s})\n", .{ path, content, expected });
            return err;
        };
    }
}

/// Poll `path` until it holds a pid, then return it. Fails on timeout.
fn waitPidFile(alloc: std.mem.Allocator, path: []const u8) !posix.pid_t {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const content = std.fs.cwd().readFileAlloc(alloc, path, 64) catch "";
        defer if (content.len > 0) alloc.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len > 0) {
            if (std.fmt.parseInt(posix.pid_t, trimmed, 10)) |pid| return pid else |_| {}
        }
        try deadline.tick("survivor pid file never appeared");
    }
}

test "detached session: send and peek round-trip through libghostty" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t1", &.{"cat"});
    try h.sendLine("t1", "round-trip-42");

    const content = try h.waitPeekContains("t1", "round-trip-42");
    defer alloc.free(content);
}

test "vt sequences: cursor movement, SGR, and clear are emulated" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t2", &.{"cat"});
    // Paint NOISE, clear the screen, write at row 3 col 5, color a
    // word. send carries the raw ESC bytes; no escaping layer.
    try h.sendLine("t2", "NOISE\x1b[2J\x1b[3;5HPOS\x1b[1;31mRED\x1b[0m-END");

    const content = try h.waitPeekContains("t2", "POSRED-END");
    defer alloc.free(content);

    // The clear must have removed earlier output.
    try std.testing.expect(std.mem.indexOf(u8, content, "NOISE") == null);

    // Row 3 starts with 4 blank columns (cursor positioning worked and
    // the peek reflects screen geometry, not the byte stream).
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // row 1
    _ = lines.next(); // row 2
    const row3 = lines.next() orelse return error.MissingRow;
    try std.testing.expect(std.mem.startsWith(u8, row3, "    POS"));
}

test "attach over a real tty: echo, then detach with C-a d" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "t3", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("t3");

    try client.send("typed-into-tty\r");
    try client.waitFor("typed-into-tty");

    try client.send("\x01d"); // C-a d
    try client.waitFor("detached from t3");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // Session survives the detach.
    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "t3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);
}

test "reattach rehydrates the screen from terminal state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t4", &.{"cat"});
    try h.sendLine("t4", "persisted-99");
    const content = try h.waitPeekContains("t4", "persisted-99");
    alloc.free(content);

    // Reattach: the repaint must reproduce content written while detached.
    var client = try PtyClient.spawn(&h, &.{ "attach", "t4" }, 24, 80);
    defer client.deinit();
    try client.waitFor("persisted-99");

    try client.send("\x01d");
    try client.waitFor("detached from t4");
    _ = try client.waitExit();
}

test "window size: initial attach size and SIGWINCH resize reach the app" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "t5", "--", "/bin/sh" }, 12, 57);
    defer client.deinit();
    try h.waitSessionUp("t5");

    const size_file = try std.fmt.allocPrint(alloc, "{s}/size.txt", .{h.dir});
    defer alloc.free(size_file);

    const cmd1 = try std.fmt.allocPrint(alloc, "stty size > {s}", .{size_file});
    defer alloc.free(cmd1);
    try h.sendLine("t5", cmd1);
    try waitFileEquals(alloc, size_file, "12 57\n");

    // Dynamic resize: change the outer terminal size; SIGWINCH propagates
    // client -> daemon -> window PTY.
    try client.setSize(30, 90);
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        try h.sendLine("t5", cmd1);
        std.Thread.sleep(50 * std.time.ns_per_ms);
        const content = std.fs.cwd().readFileAlloc(alloc, size_file, 4096) catch "";
        defer if (content.len > 0) alloc.free(content);
        if (std.mem.eql(u8, content, "30 90\n")) break;
        try deadline.tick("resize never reached the inner tty");
    }
}

test "new --rows/--cols births the session at that size" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A detached session is never attached, so it keeps the size it was
    // born with: --rows/--cols must reach the child PTY at creation,
    // not wait for an attach handshake.
    const result = try h.run(&.{ "new", "sized", "-d", "--rows", "30", "--cols", "100", "--", "/bin/sh" });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 0);
    try h.waitSessionUp("sized");

    const size_file = try std.fmt.allocPrint(alloc, "{s}/size.txt", .{h.dir});
    defer alloc.free(size_file);
    const cmd = try std.fmt.allocPrint(alloc, "stty size > {s}", .{size_file});
    defer alloc.free(cmd);
    try h.sendLine("sized", cmd);
    try waitFileEquals(alloc, size_file, "30 100\n");
}

test "default session name comes from the working directory" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A directory whose basename is a valid session name. Living under
    // h.dir gets it cleaned up with the harness; the daemon ignores
    // non-socket entries there.
    const proj = try std.fs.path.join(alloc, &.{ h.dir, "spooky-proj" });
    defer alloc.free(proj);
    try std.fs.cwd().makePath(proj);

    const first = try h.runIn(proj, &.{ "new", "-d", "--", "cat" });
    defer alloc.free(first.stdout);
    defer alloc.free(first.stderr);
    try std.testing.expect(first.term.Exited == 0);
    try std.testing.expectEqualStrings("spooky-proj\n", first.stdout);
    try h.waitSessionUp("spooky-proj");

    // The name is taken now, so the next session falls back to the
    // creating process id.
    const second = try h.runIn(proj, &.{ "new", "-d", "--", "cat" });
    defer alloc.free(second.stdout);
    defer alloc.free(second.stderr);
    try std.testing.expect(second.term.Exited == 0);
    const pid_name = std.mem.trimRight(u8, second.stdout, "\n");
    try std.testing.expect(pid_name.len > 0);
    for (pid_name) |c| try std.testing.expect(std.ascii.isDigit(c));

    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "spooky-proj") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, pid_name) != null);
}

test "new --cwd starts the command in that directory" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const proj = try std.fs.path.join(alloc, &.{ h.dir, "wd-proj" });
    defer alloc.free(proj);
    try std.fs.cwd().makePath(proj);
    // Resolve symlinks so the comparison holds where /tmp is itself a
    // link (e.g. /private/tmp on macOS).
    const proj_real = try std.fs.cwd().realpathAlloc(alloc, proj);
    defer alloc.free(proj_real);

    // The session is created from h.dir, so a child that lands in proj
    // proves --cwd overrode the inherited directory. `pwd -P` reports
    // the real cwd rather than a possibly-stale $PWD.
    try h.runOk(&.{ "new", "wd", "-d", "--cwd", proj, "--", "sh", "-c", "pwd -P > cwd.txt; exec cat" });
    try h.waitSessionUp("wd");

    const out_file = try std.fs.path.join(alloc, &.{ proj, "cwd.txt" });
    defer alloc.free(out_file);
    const expected = try std.fmt.allocPrint(alloc, "{s}\n", .{proj_real});
    defer alloc.free(expected);
    try waitFileEquals(alloc, out_file, expected);
}

test "new --cwd rejects a missing directory" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const missing = try std.fs.path.join(alloc, &.{ h.dir, "does-not-exist" });
    defer alloc.free(missing);
    // An unusable --cwd is a runtime error (exit 1) and creates nothing.
    try h.runExit(&.{ "new", "bad", "--cwd", missing, "--", "cat" }, 1);

    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "bad") == null);
}

test "session listing shows attach state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("listed", &.{"cat"});

    const detached = try h.run(&.{"ls"});
    defer alloc.free(detached.stdout);
    defer alloc.free(detached.stderr);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "listed") != null);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "detached") != null);
    // The listing includes the session's title (the launch command
    // until the app sets one).
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "TITLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "cat") != null);

    // `at` is the documented shorthand for attach.
    var client = try PtyClient.spawn(&h, &.{ "at", "listed" }, 24, 80);
    defer client.deinit();

    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const attached = try h.run(&.{"ls"});
        defer alloc.free(attached.stdout);
        defer alloc.free(attached.stderr);
        if (std.mem.indexOf(u8, attached.stdout, "attached") != null) break;
        try deadline.tick("session never showed as attached");
    }
}

test "kill ends the session and notifies the attached client" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "t8", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("t8");

    try h.runOk(&.{ "kill", "t8" });
    try client.waitFor("session t8 ended");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The socket is gone: session commands now fail with exit 3.
    try h.runExit(&.{ "peek", "t8" }, 3);
}

test "attach without a tty fails cleanly" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t9", &.{"cat"});
    const result = try h.run(&.{ "attach", "t9" });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "requires a terminal") != null);
}

test "attached client renders inside the terminal's alternate screen" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "wrap", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("wrap");

    try client.send("inside-the-canvas\r");
    try client.waitFor("inside-the-canvas");

    // The client enters the alternate screen before any session content.
    const enter = std.mem.indexOf(u8, client.output.items, "\x1b[?1049h") orelse
        return error.MissingAltScreenEnter;
    const content = std.mem.indexOf(u8, client.output.items, "inside-the-canvas").?;
    try std.testing.expect(enter < content);

    try client.send("\x01d"); // C-a d
    try client.waitFor("detached from wrap");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // Detach leaves the alternate screen, restoring the user's shell
    // view, before the detach notice is printed.
    const leave = std.mem.lastIndexOf(u8, client.output.items, "\x1b[?1049l").?;
    const notice = std.mem.indexOf(u8, client.output.items, "detached from wrap").?;
    try std.testing.expect(leave < notice);
}

test "C-a C-d detaches like GNU screen" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "ctrld", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("ctrld");

    try client.send("\x01\x04"); // C-a C-d
    try client.waitFor("detached from ctrld");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);
}

test "auto-repeated C-a stays armed until the command key" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "rpt", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("rpt");

    // Holding the prefix key auto-repeats it: C-a C-a C-d. The
    // repeats must keep the prefix armed rather than claim the
    // command slot, or the trailing C-d leaks into the window and
    // EOFs the program.
    try client.send("\x01\x01\x04");
    try client.waitFor("detached from rpt");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The session survived: nothing reached cat.
    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "rpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);
}

/// Drive a detach with a command key that is still held while the
/// detach completes, the way a human does it over a remote link: the
/// key keeps auto-repeating until the restored screen is visible, and
/// one final repeat lands after the client has already restored. The
/// attach runs under a wrapping shell on the same tty (a login shell
/// stand-in) whose `read` exposes any input that boo leaks: leaked
/// repeats corrupt the typed probe line, and a leaked C-d (EOF) ends
/// the read prematurely, which is the SSH-session-killer variant.
fn expectNoDetachKeyLeak(
    h: *Harness,
    session: []const u8,
    key: []const u8,
    late_repeat_ms: ?i64,
) !void {
    const alloc = h.alloc;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_abs = try std.fs.cwd().realpath(exe_path, &exe_buf);
    const script = try std.fmt.allocPrint(
        alloc,
        "{s} attach {s}; IFS= read -r line; printf 'GOT[%s]\\n' \"$line\"",
        .{ exe_abs, session },
    );
    defer alloc.free(script);

    var client = try PtyClient.spawnProgram(h, "/bin/sh", &.{ "-c", script }, 24, 80, &.{});
    defer client.deinit();
    try client.waitFor("\x1b[?1049h");

    // Arm the prefix, then press the command key. The key arrives
    // with its first auto-repeat coalesced into one read, the way a
    // remote link batches keystrokes; the repeat must not be
    // forwarded into the window after the detach dispatches.
    try client.send("\x01");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const pressed_at = std.time.milliTimestamp();
    const pressed = try std.mem.concat(alloc, u8, &.{ key, key });
    defer alloc.free(pressed);
    try client.send(pressed);

    // Hold the key: auto-repeats keep arriving until the user sees
    // the restored screen.
    var deadline = Deadline.init(default_timeout_ms);
    while (std.mem.indexOf(u8, client.output.items, "\x1b[?1049l") == null) {
        try client.send(key);
        _ = try client.pump(30);
        try deadline.tick("detach restore never arrived");
    }
    // The release lags the restored screen by one repeat interval, so
    // this repeat arrives after the client's own restore write. It
    // must be absorbed before the shell regains the terminal.
    try client.send(key);

    // A keyboard with a long repeat delay sends its first repeat well
    // after the detach; the EOF guard has to outlast it. Real repeat
    // delays anchor at the press, so anchor there too: the margin to
    // the 800ms guard stays wide even on slow CI runners, while still
    // proving the 300ms short guard alone would have missed it.
    if (late_repeat_ms) |ms| {
        const elapsed = std.time.milliTimestamp() - pressed_at;
        if (elapsed < ms) {
            std.Thread.sleep(@intCast((ms - elapsed) * std.time.ns_per_ms));
        }
        try client.send(key);
    }

    // Type at the shell prompt once the key is long released. The
    // pause must outlast the client's post-detach drain window so the
    // probe reaches the shell, not the drain.
    std.Thread.sleep(1500 * std.time.ns_per_ms);
    try client.send("ok\n");
    try client.waitFor("GOT[ok]");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The detach happened and the session survived.
    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, session) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);

    // Nothing leaked into the window either: the idle cat session's
    // screen stays empty.
    const peek = try h.run(&.{ "peek", session });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "d") == null);
}

test "held C-a d: repeats do not leak into the shell after detach" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("dleak", &.{"cat"});
    try expectNoDetachKeyLeak(&h, "dleak", "d", null);
}

test "held C-a C-d: repeats do not EOF the shell after detach" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The late repeat models a keyboard with a slow repeat delay
    // (450ms after the press): past the short guard, only the long
    // EOF guard absorbs it.
    try h.startDetached("eofleak", &.{"cat"});
    try expectNoDetachKeyLeak(&h, "eofleak", "\x04", 450);
}

test "alt screen apps: toggles are filtered and screens repaint from state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("altapp", &.{"sh"});

    // Put a marker on the primary screen.
    try h.sendLine("altapp", "echo PRIMARY-MARK");
    const peeked = try h.waitPeekContains("altapp", "PRIMARY-MARK");
    alloc.free(peeked);

    var client = try PtyClient.spawn(&h, &.{ "attach", "altapp" }, 24, 80);
    defer client.deinit();
    try client.waitFor("PRIMARY-MARK");
    client.clearOutput();

    // The app enters the alternate screen. The raw toggle must never
    // reach the client (its canvas cannot switch screens); the alt
    // content arrives via a repaint instead. The echoed command line
    // also contains "ALT-MARK", so wait for the marker to show up
    // after a repaint's canvas clear specifically.
    try h.sendLine("altapp", "printf '\\033[?1049h\\033[H\\033[2JALT-MARK\\n'");
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        if (std.mem.lastIndexOf(u8, client.output.items, "\x1b[H\x1b[2J")) |clear_pos| {
            if (std.mem.indexOfPos(u8, client.output.items, clear_pos, "ALT-MARK") != null) break;
        }
        _ = try client.pump(100);
        try deadline.tick("alt screen repaint never arrived");
    }
    try std.testing.expect(
        std.mem.indexOf(u8, client.output.items, "\x1b[?1049h") == null,
    );
    client.clearOutput();

    // The app leaves the alternate screen: still no raw toggle, and
    // the primary screen content is repainted from terminal state
    // rather than left blank.
    try h.sendLine("altapp", "printf '\\033[?1049l'");
    try client.waitFor("PRIMARY-MARK");
    try std.testing.expect(
        std.mem.indexOf(u8, client.output.items, "\x1b[?1049l") == null,
    );

    try client.send("\x01d");
    try client.waitFor("detached from altapp");
    _ = try client.waitExit();
}

test "queries in a discarded passthrough span are answered" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // On a go-signal, emit an alternate-screen toggle immediately
    // followed by a cursor-position query, then block until the
    // response arrives. This mirrors shells that probe the terminal
    // at startup: the toggle flips passthrough into discard mode, so
    // the query never reaches the test terminal (which would not
    // answer anyway); only the daemon can unblock the read.
    const go_path = try std.fmt.allocPrint(alloc, "{s}/go", .{h.dir});
    defer alloc.free(go_path);
    const script = try std.fmt.allocPrint(
        alloc,
        "while [ ! -e {s} ]; do sleep 0.02; done; " ++
            "printf '\\033[?1049l\\033[6n'; " ++
            "IFS= read -rs -d R pos; " ++
            "printf 'CPR-ANSWERED\\n'; sleep 5",
        .{go_path},
    );
    defer alloc.free(script);

    var client = try PtyClient.spawn(&h, &.{ "new", "qry", "--", "bash", "-c", script }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("qry");
    // Wait for the attach repaint so the burst takes the passthrough
    // path rather than being answered as an unattached window.
    try client.waitFor("\x1b[H\x1b[2J");

    try std.fs.cwd().writeFile(.{ .sub_path = go_path, .data = "" });
    try client.waitFor("CPR-ANSWERED");
}

test "reattach restores the window title" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ttl", &.{"sh"});

    // Set the title from inside the session. The title is assembled
    // from two printf arguments so the echoed command line (which
    // ends up in the repainted screen content) never contains the
    // assembled marker.
    try h.sendLine("ttl", "printf '\\033]2;TTL-%s\\007' MARK");

    // The session listing reflects the OSC title once processed.
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const result = try h.run(&.{"ls"});
        const found = std.mem.indexOf(u8, result.stdout, "TTL-MARK") != null;
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        if (found) break;
        try deadline.tick("session title never updated");
    }

    // Reattach: the repaint must restore the title on the client's
    // terminal, not just the screen contents.
    var client = try PtyClient.spawn(&h, &.{ "attach", "ttl" }, 24, 80);
    defer client.deinit();
    try client.waitFor("\x1b]2;TTL-MARK\x07");

    try client.send("\x01d");
    try client.waitFor("detached from ttl");
    _ = try client.waitExit();
}

test "help: overview, command pages, topics, and version" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const overview = try h.run(&.{"help"});
    defer alloc.free(overview.stdout);
    defer alloc.free(overview.stderr);
    try std.testing.expect(overview.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "kill") != null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "attach, at, a <name>") != null);

    // The overview stays lean: no topics or exit-code sections (the
    // codes live on the automation page).
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "topics:") == null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "exit codes:") == null);

    const send_page = try h.run(&.{ "help", "send" });
    defer alloc.free(send_page.stdout);
    defer alloc.free(send_page.stderr);
    try std.testing.expect(send_page.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, send_page.stdout, "--enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, send_page.stdout, "--key") != null);

    const automation = try h.run(&.{ "help", "automation" });
    defer alloc.free(automation.stdout);
    defer alloc.free(automation.stderr);
    try std.testing.expect(automation.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, automation.stdout, "wait") != null);

    const all = try h.run(&.{ "help", "--all" });
    defer alloc.free(all.stdout);
    defer alloc.free(all.stderr);
    try std.testing.expect(all.term.Exited == 0);
    try std.testing.expect(all.stdout.len > overview.stdout.len);

    const ver = try h.run(&.{"version"});
    defer alloc.free(ver.stdout);
    defer alloc.free(ver.stderr);
    try std.testing.expect(std.mem.startsWith(u8, ver.stdout, "boo "));
}

test "ls emits machine-readable JSON" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("js", &.{"cat"});

    const ls = try h.run(&.{ "ls", "--json" });
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(ls.term.Exited == 0);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, ls.stdout, .{});
        defer parsed.deinit();
        const sessions = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 1), sessions.len);
        const obj = sessions[0].object;
        try std.testing.expectEqualStrings("js", obj.get("name").?.string);
        try std.testing.expectEqual(false, obj.get("attached").?.bool);
        try std.testing.expect(obj.get("idle_ms").?.integer >= 0);
        try std.testing.expectEqualStrings("cat", obj.get("title").?.string);
        // A fresh cat session has produced no output, so nothing is unread.
        try std.testing.expectEqual(false, obj.get("unread").?.bool);
        // No bell has rung, so there is no "your turn".
        try std.testing.expectEqual(@as(i64, -1), obj.get("bell_idle_ms").?.integer);
        // The pid names the running cat.
        const pid: std.posix.pid_t = @intCast(obj.get("pid").?.integer);
        try std.posix.kill(pid, 0);
    }
}

test "ls --json reports unread output, and attaching clears it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A detached session that prints (what a coding agent does when it
    // finishes a turn) then idles so the daemon stays alive.
    try h.startDetached("unr", &.{ "sh", "-c", "printf 'agent-needs-you\\n'; sleep 60" });

    // Output produced while detached flips unread on.
    try h.waitUnread("unr", true);

    // Attaching is viewing: the daemon clears unread on attach.
    var client = try PtyClient.spawn(&h, &.{ "attach", "unr" }, 24, 80);
    defer client.deinit();
    try client.waitFor("agent-needs-you");
    try h.waitUnread("unr", false);
}

test "ls --json flags a bell as your turn, and attaching clears it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A detached session that rings the bell (what an agent does to get
    // your attention) then idles so the daemon stays alive.
    try h.startDetached("bel", &.{ "sh", "-c", "printf 'ding\\a\\n'; sleep 60" });

    // The bell among detached output flips "your turn" on, and a bell is
    // output, so unread is set too.
    try h.waitBell("bel", true);
    try h.waitUnread("bel", true);

    // Attaching is viewing: the daemon clears the bell on attach.
    var client = try PtyClient.spawn(&h, &.{ "attach", "bel" }, 24, 80);
    defer client.deinit();
    try client.waitFor("ding");
    try h.waitBell("bel", false);
}

test "peek --json includes geometry, cursor, and screen content" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("pj", &.{"cat"});
    try h.sendLine("pj", "json-peek-mark");
    const content = try h.waitPeekContains("pj", "json-peek-mark");
    alloc.free(content);

    const peek = try h.run(&.{ "peek", "pj", "--json" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, peek.stdout, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("pj", obj.get("session").?.string);
    try std.testing.expect(obj.get("rows").?.integer > 0);
    try std.testing.expect(obj.get("cols").?.integer > 0);
    try std.testing.expect(obj.get("cursor").?.object.get("row").?.integer >= 1);
    try std.testing.expect(
        std.mem.indexOf(u8, obj.get("screen").?.string, "json-peek-mark") != null,
    );
}

test "send --key presses named keys" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("keys", &.{"cat"});
    // Type a line without Enter, then press Enter by name; cat only
    // echoes the line back once the key arrives.
    try h.runOk(&.{ "send", "keys", "--text", "key-mark" });
    try h.runOk(&.{ "send", "keys", "--key", "Enter" });
    const content = try h.waitPeekContains("keys", "key-mark");
    defer alloc.free(content);
}

test "wait --text and --idle observe session output" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("w1", &.{"cat"});
    try h.sendLine("w1", "wait-mark");

    // --text: returns once the text is on screen. The =value flag
    // spelling is accepted too.
    try h.runOk(&.{ "wait", "w1", "--text=wait-mark", "--timeout", "10s" });

    // --idle: cat produces no further output, so this settles once
    // the screen has been quiet for the built-in threshold.
    try h.runOk(&.{ "wait", "w1", "--idle", "--timeout", "10s" });

    // Timeout: text that never appears exits with the documented code.
    try h.runExit(&.{ "wait", "w1", "--text", "NEVER-APPEARS", "--timeout", "300ms" }, 4);
}

test "zero-arg boo prints the help overview" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const result = try h.run(&.{});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "commands:") != null);

    // Unlike earlier versions, no session is created or attached.
    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "No sessions") != null);
}

test "kill --all banishes every session" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ghost1", &.{"cat"});
    try h.startDetached("ghost2", &.{"cat"});
    try h.runOk(&.{ "kill", "--all" });

    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const result = try h.run(&.{"ls"});
        const empty = std.mem.indexOf(u8, result.stdout, "No sessions") != null;
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        if (empty) break;
        try deadline.tick("sessions survived kill --all");
    }
    try h.runExit(&.{ "peek", "ghost1" }, 3);
}

test "kill tears down the whole process tree, not just the session shell" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A survivor that escapes a shell-only hangup: it ignores SIGHUP and
    // SIGTERM and loops, so only a full-tree SIGKILL escalation can end
    // it. It records its pid so the test can follow it across the kill.
    const pid_path = try std.fmt.allocPrint(alloc, "{s}/survivor.pid", .{h.dir});
    defer alloc.free(pid_path);
    const script_path = try std.fmt.allocPrint(alloc, "{s}/survivor.sh", .{h.dir});
    defer alloc.free(script_path);
    const body = try std.fmt.allocPrint(
        alloc,
        "#!/bin/sh\necho $$ > {s}\ntrap '' HUP TERM\nwhile :; do sleep 1; done\n",
        .{pid_path},
    );
    defer alloc.free(body);
    try std.fs.cwd().writeFile(.{ .sub_path = script_path, .data = body });
    try posix.fchmodat(posix.AT.FDCWD, script_path, 0o755, 0);

    try h.startDetached("orph", &.{"sh"});

    // Launch the survivor as a grandchild of the session shell through an
    // intermediate shell that stays alive (wait), so at kill time the
    // survivor is still a descendant of the session shell rather than a
    // process that already reparented to init.
    const launch = try std.fmt.allocPrint(alloc, "sh -c '{s} & wait' &", .{script_path});
    defer alloc.free(launch);
    try h.sendLine("orph", launch);

    // Wait until the survivor is up, then read its pid.
    const survivor_pid = try waitPidFile(alloc, pid_path);
    // Safety net: never leak the survivor if the test bails out early.
    defer posix.kill(survivor_pid, posix.SIG.KILL) catch {};

    // It is really alive before the kill.
    try posix.kill(survivor_pid, 0);

    try h.runOk(&.{ "kill", "orph" });

    // The session is gone...
    try h.runExit(&.{ "peek", "orph" }, 3);

    // ...and so is the whole tree it started: the orphan is torn down
    // rather than left holding its resources. The shell-only SIGHUP of
    // the old behavior left this process alive.
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        posix.kill(survivor_pid, 0) catch break; // ESRCH: the orphan is gone
        deadline.tick("orphaned descendant survived kill") catch |err| {
            std.debug.print("survivor pid {d} still alive after kill\n", .{survivor_pid});
            return err;
        };
    }
}

test "exit codes distinguish usage, missing sessions, and ambiguity" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    try h.startDetached("alpha", &.{"cat"});
    try h.startDetached("alike", &.{"cat"});

    // Unique prefix resolves; ambiguous prefix and unknown names exit 3.
    try h.runOk(&.{ "peek", "alp" });
    try h.runExit(&.{ "peek", "al" }, 3);
    try h.runExit(&.{ "attach", "nosuchzz" }, 3);
    try h.runExit(&.{ "a", "nosuchzz" }, 3);
    try h.runExit(&.{ "kill", "nosuchzz" }, 3);

    // Session names are required; nothing is guessed.
    try h.runExit(&.{"kill"}, 2);
    try h.runExit(&.{"attach"}, 2);
    try h.runExit(&.{"a"}, 2);
    try h.runExit(&.{"peek"}, 2);

    // Usage errors exit 2.
    try h.runExit(&.{"frobnicate"}, 2);
    try h.runExit(&.{ "wait", "alpha" }, 2);
    try h.runExit(&.{ "send", "alpha", "--key", "NoSuchKey" }, 2);
    try h.runExit(&.{ "send", "alpha", "--text", "text", "--key", "Enter" }, 2);
    try h.runExit(&.{ "help", "nosuchtopic" }, 2);
    try h.runExit(&.{ "kill", "--all", "alpha" }, 2);
}

test "kitty keyboard apps: encoded C-a still detaches" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "kt", "--", "bash", "--norc" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("kt");
    try client.waitFor("\x1b[H\x1b[2J"); // attach repaint

    // The app enters the alt screen and enables kitty keyboard
    // disambiguation, like a modern TUI. The passthrough mirrors both
    // onto the client's terminal, which then encodes Ctrl+A as
    // CSI 97;5u instead of 0x01. The marker is printed after the
    // kitty enable and assembled from two printf arguments: by the
    // time it is visible the daemon has processed the enable, and the
    // echoed command line never contains the assembled marker (the
    // tty echo would otherwise satisfy the wait while the keys still
    // leak into the window).
    try client.send("printf '\\033[?1049h\\033[H\\033[2J\\033[>1uKITTY-%s\\n' APP; read x\r");
    try client.waitFor("KITTY-APP");

    // Press C-a d the way a kitty-mode terminal sends it.
    client.clearOutput();
    try client.send("\x1b[97;5u");
    try client.send("d");
    try client.waitFor("detached from kt");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The keys were intercepted, not leaked into the window.
    const peek = try h.run(&.{ "peek", "kt" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "97;5u") == null);

    // The session survives, and the kitty-encoded C-a C-d variant
    // detaches as well after a reattach.
    var second = try PtyClient.spawn(&h, &.{ "attach", "kt" }, 24, 80);
    defer second.deinit();
    try second.waitFor("KITTY-APP");
    try second.send("\x1b[97;5u\x1b[100;5u");
    try second.waitFor("detached from kt");
    try std.testing.expectEqual(@as(u32, 0), try second.waitExit());
}

test "kitty keyboard apps: auto-repeated C-a still detaches" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The session enables kitty disambiguation before any client
    // attaches, so an attaching client's terminal kitty-encodes
    // every key, including the held prefix.
    try h.startDetached("krpt", &.{
        "sh", "-c", "printf '\\033[>1uKITTY-ON\\n'; exec cat",
    });
    const seeded = try h.waitPeekContains("krpt", "KITTY-ON");
    alloc.free(seeded);

    var client = try PtyClient.spawn(&h, &.{ "attach", "krpt" }, 24, 80);
    defer client.deinit();
    try client.waitFor("KITTY-ON");

    // Holding the prefix repeats CSI 97;5u. The repeat must not be
    // taken as the command key; the C-d that follows still detaches.
    client.clearOutput();
    try client.send("\x1b[97;5u\x1b[97;5u\x1b[100;5u");
    try client.waitFor("detached from krpt");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The keys were intercepted, not leaked into the window.
    const peek = try h.run(&.{ "peek", "krpt" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "97;5u") == null);
}

test "modifyOtherKeys apps: encoded C-a still detaches" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "mok", "--", "bash", "--norc" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("mok");
    try client.waitFor("\x1b[H\x1b[2J"); // attach repaint

    // The app enables xterm modifyOtherKeys mode 2, like vim. The
    // passthrough mirrors it onto the client's terminal, which (on
    // xterm-faithful terminals) then encodes Ctrl+A as CSI 27;5;97~
    // instead of 0x01. The marker is assembled from two printf
    // arguments so the echoed command line cannot satisfy the wait.
    try client.send("printf '\\033[>4;2mMODIFY-%s\\n' APP; read x\r");
    try client.waitFor("MODIFY-APP");
    try client.waitFor("\x1b[>4;2m");

    // Press C-a d the way such a terminal sends it.
    client.clearOutput();
    try client.send("\x1b[27;5;97~");
    try client.send("d");
    try client.waitFor("detached from mok");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The keys were intercepted, not leaked into the window.
    const peek = try h.run(&.{ "peek", "mok" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "27;5;97") == null);

    // The session survives; a reattach repaint replays the mode, and
    // the fully encoded C-a C-d variant detaches as well.
    var second = try PtyClient.spawn(&h, &.{ "attach", "mok" }, 24, 80);
    defer second.deinit();
    try second.waitFor("MODIFY-APP");
    try second.waitFor("\x1b[>4;2m");
    try second.send("\x1b[27;5;97~\x1b[27;5;100~");
    try second.waitFor("detached from mok");
    try std.testing.expectEqual(@as(u32, 0), try second.waitExit());
}

test "modifyOtherKeys apps: Esc and C-a Esc act without waiting for another key" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // Under modifyOtherKeys, like vim's, the parser holds a raw ESC in
    // case it starts an encoded C-a. The app reads one raw byte and
    // prints it in hex. The marker follows the mode switches, so the
    // window has both by the time it is visible.
    const script = "stty raw -echo; printf '\\033[>4;2mMOK-%s\\r\\n' ON; " ++
        "head -c 1 | od -An -tx1; exec sleep 60";
    var client = try PtyClient.spawn(&h, &.{ "new", "mokesc", "--", "sh", "-c", script }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("mokesc");
    try client.waitFor("MOK-ON");

    // A lone Esc reaches the app once no more input follows it.
    try client.send("\x1b");
    const got = try h.waitPeekContains("mokesc", " 1b");
    alloc.free(got);

    // C-a Esc enters copy mode the same way.
    client.clearOutput();
    try client.send("\x01\x1b");
    const screen = try waitCopyFrame(alloc, &client, 24, 80);
    defer alloc.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "MOK-ON") != null);
}

test "agent loop: new, send, wait, peek, kill" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The documented automation loop, end to end, with no terminal.
    try h.startDetached("agent", &.{"sh"});
    try h.sendLine("agent", "echo result-$((40+2))");
    try h.runOk(&.{ "wait", "agent", "--text", "result-42", "--timeout", "10s" });
    try h.runOk(&.{ "wait", "agent", "--idle", "--timeout=10s" });

    const content = try h.waitPeekContains("agent", "result-42");
    defer alloc.free(content);

    try h.runOk(&.{ "kill", "agent" });
    try h.runExit(&.{ "peek", "agent" }, 3);
}

test "kill: peek immediately after kill reports no session" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // Once kill is acked the socket file is already unlinked, so a
    // back-to-back peek must deterministically resolve "no session"
    // (exit 3) and never observe EOF from the dying daemon. Repeat to
    // amplify the former race between the kill ack and teardown.
    var i: usize = 0;
    var name_buf: [16]u8 = undefined;
    while (i < 10) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "reap{d}", .{i});
        try h.startDetached(name, &.{"sh"});
        try h.runOk(&.{ "kill", name });
        try h.runExit(&.{ "peek", name }, 3);
    }
}

test "rename: moves a session to a new name" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("before", &.{"cat"});
    try h.sendLine("before", "RN-MARK");
    const seeded = try h.waitPeekContains("before", "RN-MARK");
    alloc.free(seeded);

    // The screen and the running process survive the rename.
    try h.runOk(&.{ "rename", "before", "after" });
    const content = try h.waitPeekContains("after", "RN-MARK");
    alloc.free(content);
    try h.runExit(&.{ "peek", "before" }, 3);

    // Name collisions, invalid names, and missing sessions are
    // rejected with the documented exit codes.
    try h.startDetached("other", &.{"cat"});
    try h.runExit(&.{ "rename", "after", "other" }, 1);
    try h.runExit(&.{ "rename", "after", "sp ace" }, 2);
    try h.runExit(&.{ "rename", "nosuchzz", "x" }, 3);
    try h.runExit(&.{"rename"}, 2);
    try h.runExit(&.{ "rename", "after" }, 2);
}

/// Render raw client output through a terminal emulator and return
/// the resulting screen text, one line per row. Raw byte matching
/// cannot tell whether content survives on screen (a later erase can
/// remove it); this can.
fn renderScreen(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    rows: u16,
    cols: u16,
) ![]const u8 {
    var term = try vt.Terminal.init(alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    return term.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
}

test "plain attach replays the visible screen only, never scrollback history" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // HIST-001 scrolls off the live screen. A plain attach is raw
    // passthrough to the user's real terminal, where a history dump
    // would spam their screen, so it must receive only the visible
    // screen, never the scrolled-off history.
    try h.startDetached("plain", &.{"sh"});
    try h.sendLine("plain", "i=1; while [ $i -le 60 ]; do printf 'HIST-%03d\\n' $i; i=$((i+1)); done");
    const seeded = try h.waitPeekContains("plain", "HIST-060");
    alloc.free(seeded);

    var client = try PtyClient.spawn(&h, &.{ "attach", "plain" }, 24, 80);
    defer client.deinit();
    // The repaint reproduces the visible screen, ending at HIST-060.
    try client.waitFor("HIST-060");
    // The daemon sends any history before the repaint, so if it had been
    // (wrongly) sent it would already be here alongside HIST-060. The
    // off-screen line must be absent.
    try std.testing.expect(std.mem.indexOf(u8, client.output.items, "HIST-001") == null);

    try client.send("\x01d");
    try client.waitFor("detached from plain");
    _ = try client.waitExit();
}

/// Render a copy mode frame and return its first row, which ends in the
/// viewport's place in the history. The tag closes the frame, so its
/// trailing SGR reset marks the frame as complete.
fn waitCopyFrame(alloc: std.mem.Allocator, client: *PtyClient, rows: u16, cols: u16) ![]const u8 {
    try client.waitFor("]\x1b[0m");
    return renderScreen(alloc, client.output.items, rows, cols);
}

test "copy mode scrolls the history and returns to the live screen" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("copy", &.{"sh"});
    try h.sendLine("copy", "i=1; while [ $i -le 60 ]; do printf 'HIST-%03d\\n' $i; i=$((i+1)); done");
    const seeded = try h.waitPeekContains("copy", "HIST-060");
    alloc.free(seeded);

    var client = try PtyClient.spawn(&h, &.{ "attach", "copy" }, 24, 80);
    defer client.deinit();
    try client.waitFor("HIST-060");

    // Entering copy mode shows the live screen, scrolled back 0 rows.
    client.clearOutput();
    try client.send("\x01[");
    {
        const screen = try waitCopyFrame(alloc, &client, 24, 80);
        defer alloc.free(screen);
        try std.testing.expect(std.mem.indexOf(u8, screen, "HIST-060") != null);
        try std.testing.expect(std.mem.indexOf(u8, screen, "[0/") != null);
    }

    // g goes to the top of the history, where the first lines are.
    client.clearOutput();
    try client.send("g");
    {
        const screen = try waitCopyFrame(alloc, &client, 24, 80);
        defer alloc.free(screen);
        try std.testing.expect(std.mem.indexOf(u8, screen, "HIST-001") != null);
        try std.testing.expect(std.mem.indexOf(u8, screen, "HIST-060") == null);
        // At the top, the rows scrolled back equal the rows of history.
        const first_row = screen[0 .. std.mem.indexOfScalar(u8, screen, '\n') orelse screen.len];
        const open = std.mem.lastIndexOfScalar(u8, first_row, '[').?;
        const slash = std.mem.indexOfScalarPos(u8, first_row, open, '/').?;
        const close = std.mem.indexOfScalarPos(u8, first_row, slash, ']').?;
        try std.testing.expectEqualStrings(first_row[open + 1 .. slash], first_row[slash + 1 .. close]);
    }

    // Output while scrolled back stays out of the frame.
    client.clearOutput();
    try h.sendLine("copy", "echo LIVE-MARK");
    const live = try h.waitPeekContains("copy", "LIVE-MARK\n");
    alloc.free(live);
    while (try client.pump(200)) {}
    try std.testing.expect(std.mem.indexOf(u8, client.output.items, "LIVE-MARK") == null);

    // q returns to the live screen, which has kept up, and typing reaches
    // the shell again.
    try client.send("q");
    try client.waitFor("LIVE-MARK");
    try client.send("echo AFTER-COPY\r");
    const after = try h.waitPeekContains("copy", "AFTER-COPY\n");
    alloc.free(after);

    try client.send("\x01d");
    try client.waitFor("detached from copy");
    _ = try client.waitExit();
}
