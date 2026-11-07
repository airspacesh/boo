//! Session naming and socket directory resolution.

const std = @import("std");

pub const max_name_len = 64;

pub const NameError = error{InvalidSessionName};

/// Session names become file names, so restrict them to a safe set.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidSessionName;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.InvalidSessionName,
    };
    // Avoid names that look like path traversal or hidden files.
    if (name[0] == '.' or name[0] == '-') return error.InvalidSessionName;
}

/// Resolve the directory that holds session sockets: $BOO_DIR, else
/// /tmp/boo-<uid>. The directory is created with mode 0700.
pub fn socketDir(alloc: std.mem.Allocator) ![]u8 {
    return socketDirFrom(alloc, std.posix.getenv("BOO_DIR"));
}

/// Sessions outlive the login that started them, so they cannot live in
/// $XDG_RUNTIME_DIR. systemd-logind deletes that directory when the
/// user's last login ends, which would leave every detached session
/// running but unreachable.
fn socketDirFrom(alloc: std.mem.Allocator, boo_dir: ?[]const u8) ![]u8 {
    if (boo_dir) |d| {
        if (d.len > 0) {
            const dir = try alloc.dupe(u8, d);
            errdefer alloc.free(dir);
            try ensureDir(dir);
            return dir;
        }
    }
    const dir = try std.fmt.allocPrint(alloc, "/tmp/boo-{d}", .{std.c.getuid()});
    errdefer alloc.free(dir);
    try ensureDir(dir);
    return dir;
}

/// Dir.makePath checks an existing directory with statx, which Linux added
/// in 4.11, so on older kernels every command after the first would fail.
/// Open the directory first and only make it when it is missing.
fn ensureDir(dir: []const u8) !void {
    if (std.fs.cwd().openDir(dir, .{})) |d| {
        var existing = d;
        existing.close();
    } else |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().makePath(dir),
        else => return err,
    }
    // Best effort: sockets must not be reachable by other users.
    std.posix.fchmodat(std.posix.AT.FDCWD, dir, 0o700, 0) catch {};
}

pub fn socketPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.sock", .{name});
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, file });
}

/// Map an arbitrary string onto the session-name character set: bytes
/// outside the allowed set become '-' and overlong input is truncated.
/// Returns null when the result still fails validation, e.g. empty input
/// or a leading '.' or '-'.
fn sanitizeName(buf: []u8, base: []const u8) ?[]const u8 {
    const len = @min(base.len, @min(buf.len, max_name_len));
    if (len == 0) return null;
    for (base[0..len], buf[0..len]) |c, *out| {
        out.* = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => c,
            else => '-',
        };
    }
    const name = buf[0..len];
    validateName(name) catch return null;
    return name;
}

/// Default session name for sessions created without a name: the basename
/// of the current directory when it is usable and no session socket with
/// that name exists in dir, otherwise the creating process id (like GNU
/// screen's pid prefix).
pub fn defaultName(buf: []u8, dir: []const u8) []const u8 {
    cwd: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch break :cwd;
        const name = sanitizeName(buf, std.fs.path.basename(cwd)) orelse break :cwd;
        var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sock = std.fmt.bufPrint(
            &sock_buf,
            "{s}/{s}.sock",
            .{ dir, name },
        ) catch break :cwd;
        // An existing socket means the name is taken; fall back to the pid.
        std.fs.cwd().access(sock, .{}) catch return name;
        break :cwd;
    }
    return std.fmt.bufPrint(buf, "{d}", .{std.c.getpid()}) catch unreachable;
}

/// Iterate sessions in dir: every "*.sock" file. Returns names without
/// the extension; caller frees each name and the list.
pub fn listSessions(alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.toOwnedSlice(alloc),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const name = entry.name[0 .. entry.name.len - ".sock".len];
        validateName(name) catch continue;
        try names.append(alloc, try alloc.dupe(u8, name));
    }

    return names.toOwnedSlice(alloc);
}

test "validateName" {
    try validateName("work");
    try validateName("a-b_c.d2");
    try std.testing.expectError(error.InvalidSessionName, validateName(""));
    try std.testing.expectError(error.InvalidSessionName, validateName("a/b"));
    try std.testing.expectError(error.InvalidSessionName, validateName(".hidden"));
    try std.testing.expectError(error.InvalidSessionName, validateName("-flag"));
    try std.testing.expectError(error.InvalidSessionName, validateName("a" ** 65));
    try std.testing.expectError(error.InvalidSessionName, validateName("sp ace"));
}

test "sanitizeName" {
    var buf: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("my-proj", sanitizeName(&buf, "my proj").?);
    try std.testing.expectEqualStrings("a.b_c-1", sanitizeName(&buf, "a.b_c-1").?);
    try std.testing.expectEqualStrings("h--llo", sanitizeName(&buf, "héllo").?);
    try std.testing.expect(sanitizeName(&buf, "") == null);
    try std.testing.expect(sanitizeName(&buf, ".hidden") == null);
    try std.testing.expect(sanitizeName(&buf, "-flag") == null);
    try std.testing.expectEqualStrings(
        "x" ** max_name_len,
        sanitizeName(&buf, "x" ** 100).?,
    );
}

test "socketPath" {
    const alloc = std.testing.allocator;
    const p = try socketPath(alloc, "/run/gs", "work");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/run/gs/work.sock", p);
}

test "socketDirFrom prefers BOO_DIR and creates it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const want = try std.fs.path.join(alloc, &.{ base, "override", "boo" });
    defer alloc.free(want);

    const dir = try socketDirFrom(alloc, want);
    defer alloc.free(dir);
    try std.testing.expectEqualStrings(want, dir);
    var d = try std.fs.cwd().openDir(dir, .{});
    d.close();
}

test "socketDirFrom defaults to /tmp/boo-<uid>" {
    const alloc = std.testing.allocator;
    const want = try std.fmt.allocPrint(alloc, "/tmp/boo-{d}", .{std.c.getuid()});
    defer alloc.free(want);

    const dir = try socketDirFrom(alloc, null);
    defer alloc.free(dir);
    try std.testing.expectEqualStrings(want, dir);
}
