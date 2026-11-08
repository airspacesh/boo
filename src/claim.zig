//! Ownership of a session name. The daemon that serves <dir>/<name>.sock
//! holds an exclusive flock(2) on <dir>/<name>.lock for as long as it
//! listens there, and only the lock's holder creates or deletes the
//! socket. A socket whose lock anyone can take therefore belongs to no
//! live daemon, however slowly a live one answers.

const std = @import("std");
const posix = std.posix;

const paths = @import("paths.zig");

/// A session name held by this process: its lock and its listening
/// socket.
pub const Claim = struct {
    socket_path: []u8,
    lock_path: []u8,
    listen_fd: posix.fd_t,
    lock_fd: posix.fd_t,

    /// Give up the name. The socket goes before the listener closes, so
    /// a new client finds no session rather than one that refuses it.
    pub fn release(self: Claim, alloc: std.mem.Allocator) void {
        posix.unlink(self.socket_path) catch {};
        posix.close(self.listen_fd);
        unlockFile(self.lock_fd, self.lock_path);
        alloc.free(self.socket_path);
        alloc.free(self.lock_path);
    }

    /// Close this process's copies of the claim's descriptors after
    /// fork handed the claim to a daemon, which goes on holding it.
    pub fn closeInherited(self: Claim, alloc: std.mem.Allocator) void {
        posix.close(self.listen_fd);
        posix.close(self.lock_fd);
        alloc.free(self.socket_path);
        alloc.free(self.lock_path);
    }
};

/// Take `name` in `dir` and listen on its socket. Returns null when a
/// live daemon holds the name.
pub fn claim(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?Claim {
    const lock_path = try paths.lockPath(alloc, dir, name);
    errdefer alloc.free(lock_path);
    const socket_path = try paths.socketPath(alloc, dir, name);
    errdefer alloc.free(socket_path);

    const lock_fd = try lockFile(lock_path) orelse {
        alloc.free(socket_path);
        alloc.free(lock_path);
        return null;
    };
    errdefer unlockFile(lock_fd, lock_path);

    // A socket left at the path belongs to a daemon that died holding
    // the lock.
    posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const listen_fd = try listen(socket_path);
    return .{
        .socket_path = socket_path,
        .lock_path = lock_path,
        .listen_fd = listen_fd,
        .lock_fd = lock_fd,
    };
}

/// Delete the socket of `name` in `dir` when no live daemon holds the
/// name. Returns false when one does.
pub fn removeStale(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !bool {
    const lock_path = try paths.lockPath(alloc, dir, name);
    defer alloc.free(lock_path);
    const lock_fd = try lockFile(lock_path) orelse return false;
    defer unlockFile(lock_fd, lock_path);

    const socket_path = try paths.socketPath(alloc, dir, name);
    defer alloc.free(socket_path);
    posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return true;
}

/// Lock the file at `path`, creating it if needed. Returns null when
/// another process holds the lock.
fn lockFile(path: []const u8) !?posix.fd_t {
    while (true) {
        const fd = try posix.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
        posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| {
            posix.close(fd);
            if (err == error.WouldBlock) return null;
            return err;
        };
        // A holder unlinks the file before it unlocks, so this lock may
        // be on a file no longer at `path`. Such a lock guards nothing:
        // retry on the file the path names now.
        if (try isFileAt(fd, path)) return fd;
        posix.close(fd);
    }
}

fn isFileAt(fd: posix.fd_t, path: []const u8) !bool {
    const held = try posix.fstat(fd);
    const current = posix.fstatat(posix.AT.FDCWD, path, 0) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return held.dev == current.dev and held.ino == current.ino;
}

fn unlockFile(fd: posix.fd_t, path: []const u8) void {
    posix.unlink(path) catch {};
    posix.close(fd);
}

/// Bind and listen on a Unix socket at `path` that only this user may
/// connect to. Non-blocking, so the daemon can accept until the backlog
/// is empty.
fn listen(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    // bind creates the socket file with the umask's permissions, which
    // may let the group connect, and chmod on a socket fails on some
    // file systems. The umask is process-wide, but boo is
    // single-threaded, so nothing else creates a file meanwhile.
    const umask = std.c.umask(0o177);
    defer _ = std.c.umask(umask);
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(fd, std.c.SOMAXCONN);
    return fd;
}

test "a claimed name cannot be claimed again until it is released" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Relative, because socket paths must fit in sockaddr_un.
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const first = (try claim(alloc, dir, "s")).?;
    try std.testing.expect(try claim(alloc, dir, "s") == null);
    try std.testing.expect(!try removeStale(alloc, dir, "s"));
    first.release(alloc);

    const second = (try claim(alloc, dir, "s")).?;
    second.release(alloc);
}
