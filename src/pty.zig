//! PTY allocation and child process spawning.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ttyname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

/// Terminal ioctl request codes. Zig's std does not define the set
/// variants for darwin, so the (ABI-stable) BSD values are spelled out.
pub const Tio = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const IOCGWINSZ: c_ulong = 0x40087468;
        pub const IOCSWINSZ: c_ulong = 0x80087467;
        pub const IOCSCTTY: c_ulong = 0x20007461;
    },
    else => struct {
        pub const IOCGWINSZ: c_ulong = std.c.T.IOCGWINSZ;
        pub const IOCSWINSZ: c_ulong = std.c.T.IOCSWINSZ;
        pub const IOCSCTTY: c_ulong = std.c.T.IOCSCTTY;
    },
};

pub const Winsize = std.posix.winsize;

pub fn makeWinsize(rows: u16, cols: u16) Winsize {
    return .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
}

pub const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    pub fn open(size: Winsize) !Pty {
        const master = posix_openpt(@bitCast(@as(u32, @bitCast(posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }))));
        if (master < 0) return error.OpenPtyFailed;
        errdefer posix.close(master);

        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;

        var path_buf: [128]u8 = undefined;
        if (ptsname_r(master, &path_buf, path_buf.len) != 0) {
            return error.OpenPtyFailed;
        }
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse {
            return error.OpenPtyFailed;
        };
        const slave_path = path_buf[0..path_len :0];

        // NOCTTY: the opener may be a session leader without a
        // controlling terminal; the child acquires the PTY explicitly
        // via TIOCSCTTY after fork.
        const slave = posix.openZ(slave_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0) catch return error.OpenPtyFailed;
        errdefer posix.close(slave);

        // Set the initial size on the slave, mirroring openpty(3).
        // macOS rejects TIOCSWINSZ on the master until the slave has
        // been opened.
        if (ioctl(slave, Tio.IOCSWINSZ, @intFromPtr(&size)) != 0) {
            return error.IoctlFailed;
        }

        return .{ .master = master, .slave = slave };
    }

    pub fn setSize(fd: posix.fd_t, size: Winsize) !void {
        if (ioctl(fd, Tio.IOCSWINSZ, @intFromPtr(&size)) != 0) {
            return error.IoctlFailed;
        }
    }
};

pub fn getSize(fd: posix.fd_t) !Winsize {
    var ws: Winsize = undefined;
    if (ioctl(fd, Tio.IOCGWINSZ, @intFromPtr(&ws)) != 0) {
        return error.IoctlFailed;
    }
    return ws;
}

pub const SpawnOptions = struct {
    argv: []const []const u8,
    env: *std.process.EnvMap,
    size: Winsize,
    /// Working directory for the child; null inherits the caller's.
    cwd: ?[]const u8 = null,
};

pub const Spawned = struct {
    pid: posix.pid_t,
    master: posix.fd_t,
    /// The session terminal's device number (see `ttyDevice`).
    tty_device: u64,
};

/// The device number of the terminal open on `fd`, which tells two
/// terminals apart. `st_rdev` is signed on some systems, so its bits are
/// taken as they are.
pub fn ttyDevice(fd: posix.fd_t) !u64 {
    const rdev = (try posix.fstat(fd)).rdev;
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(rdev)));
    return @as(Bits, @bitCast(rdev));
}

/// The path of the terminal open on `fd`, like /dev/pts/3, written into
/// `buf`.
pub fn ttyName(fd: posix.fd_t, buf: []u8) ![]const u8 {
    if (ttyname_r(fd, buf.ptr, buf.len) != 0) return error.NotATty;
    return std.mem.sliceTo(buf, 0);
}

/// Why a forked child could not start the session command.
pub const StartError = posix.ExecveError || posix.ChangeCurDirError || error{TerminalSetupFailed};

const ErrorInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

/// Send the child's start failure to the parent over the status pipe,
/// then exit. The child shares the parent's binary, so the error's
/// integer means the same error there, as in std.process.Child.
fn reportStartFailure(status_fd: posix.fd_t, err: StartError) noreturn {
    const err_int: ErrorInt = @intFromError(err);
    _ = posix.write(status_fd, std.mem.asBytes(&err_int)) catch {};
    posix.exit(127);
}

/// Fork a child running argv with a fresh PTY as its controlling
/// terminal. Returns the child pid and the PTY master fd, or the
/// StartError that kept the child from running argv.
pub fn spawnInPty(alloc: std.mem.Allocator, opts: SpawnOptions) !Spawned {
    const pty = try Pty.open(opts.size);
    errdefer posix.close(pty.master);
    errdefer posix.close(pty.slave);

    // Prepare exec arguments before forking; only async-signal-safe
    // calls are allowed in the child.
    const argv0 = try alloc.dupeZ(u8, opts.argv[0]);
    defer alloc.free(argv0);
    const argv = try alloc.allocSentinel(?[*:0]const u8, opts.argv.len, null);
    defer alloc.free(argv);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    for (opts.argv, 0..) |arg, i| argv[i] = try arena.allocator().dupeZ(u8, arg);
    const envp = try std.process.createEnvironFromMap(arena.allocator(), opts.env, .{});
    const cwd_z: ?[:0]const u8 = if (opts.cwd) |d|
        try arena.allocator().dupeZ(u8, d)
    else
        null;

    // The child reports a failure before exec on this pipe. exec closes
    // it, so EOF with nothing read means the command is running.
    const status_pipe = try posix.pipe2(.{ .CLOEXEC = true });
    defer posix.close(status_pipe[0]);
    const status_fd = status_pipe[1];

    const pid = posix.fork() catch |err| {
        posix.close(status_fd);
        return err;
    };
    if (pid == 0) {
        // Child. Become a session leader and acquire the inherited
        // PTY slave as the controlling terminal (login_tty pattern).
        _ = posix.setsid() catch reportStartFailure(status_fd, error.TerminalSetupFailed);
        // The daemon ignores SIGHUP and SIGPIPE, and exec keeps a signal
        // ignored. Restore the defaults, so a hangup ends the session's
        // processes and a pipeline's writer stops when its reader exits.
        const default: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.HUP, &default, null);
        posix.sigaction(posix.SIG.PIPE, &default, null);
        if (ioctl(pty.slave, Tio.IOCSCTTY, @as(c_ulong, 0)) != 0) {
            reportStartFailure(status_fd, error.TerminalSetupFailed);
        }

        posix.dup2(pty.slave, 0) catch reportStartFailure(status_fd, error.TerminalSetupFailed);
        posix.dup2(pty.slave, 1) catch reportStartFailure(status_fd, error.TerminalSetupFailed);
        posix.dup2(pty.slave, 2) catch reportStartFailure(status_fd, error.TerminalSetupFailed);
        if (pty.slave > 2) posix.close(pty.slave);
        posix.close(pty.master);

        // chdir(2) is async-signal-safe; an invalid directory aborts
        // the child rather than silently starting in the wrong place.
        if (cwd_z) |d| posix.chdirZ(d) catch |err| reportStartFailure(status_fd, err);

        reportStartFailure(status_fd, posix.execvpeZ(argv0, argv, envp));
    }

    posix.close(status_fd);
    var err_int: ErrorInt = 0;
    const status_len = try posix.read(status_pipe[0], std.mem.asBytes(&err_int));
    if (status_len != 0) {
        const err: StartError = @errorCast(@errorFromInt(err_int));
        return err;
    }

    // Parent. Drop the slave so the master sees EOF once the child
    // (the only remaining holder) exits.
    const tty_device = try ttyDevice(pty.slave);
    posix.close(pty.slave);
    return .{ .pid = pid, .master = pty.master, .tty_device = tty_device };
}
