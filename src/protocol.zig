//! Length-prefixed message framing for the client/daemon Unix socket.
//!
//! Wire format, little endian:
//!
//!   | type: u8 | payload_len: u32 | payload: [payload_len]u8 |
//!
//! Payloads are opaque bytes; structured payloads (sizes, command argv)
//! are encoded by the helpers below.

const std = @import("std");

/// Maximum payload size. Anything larger is a protocol error; this bounds
/// memory used by a malicious or corrupt peer.
pub const max_payload = 1 << 20;

pub const header_len = 5;

pub const MsgType = enum(u8) {
    // Client to daemon.
    attach = 1,
    input = 2,
    resize = 3,
    detach_req = 4,
    command = 5,
    /// The client closed the session menu without switching, so the
    /// session's canvas needs a frame again.
    close_menu = 6,
    /// The background color of the client's real terminal, as a
    /// `RgbPayload`. The client probes its terminal once at startup and
    /// reports the answer so the daemon can satisfy OSC 11 background
    /// queries (and the color-scheme DSR) from inside the session, where
    /// the application can no longer reach the real terminal. An older
    /// daemon ignores the unknown type, so theme detection simply stays
    /// as it was before this message existed.
    bg_color = 7,

    // Daemon to client.
    output = 64,
    detached = 65,
    exit = 66,
    ok = 67,
    err = 68,
    /// A leading piece of a payload larger than `max_payload`. The
    /// pieces arrive in order, and a message of the payload's own type
    /// carries the last piece (see `appendMsg`).
    part = 69,
    /// Attach the session the payload names in place of this one, as
    /// `pane switch` asked.
    switch_to = 70,
    /// Attach the session this client switched from, as `C-a L` asked.
    switch_back = 71,
    /// Open the session menu, as `C-a m` asked. The canvas is the
    /// client's until it closes the menu or switches away.
    menu = 72,
    _,
};

pub const Msg = struct {
    type: MsgType,
    payload: []const u8,
};

/// 2x u16 little endian: rows, cols. Used by attach and resize.
pub const SizePayload = struct {
    rows: u16,
    cols: u16,

    pub fn encode(self: SizePayload) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.rows, .little);
        std.mem.writeInt(u16, buf[2..4], self.cols, .little);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!SizePayload {
        if (payload.len != 4) return error.InvalidPayload;
        return .{
            .rows = std.mem.readInt(u16, payload[0..2], .little),
            .cols = std.mem.readInt(u16, payload[2..4], .little),
        };
    }
};

/// Why a client attaches.
pub const AttachReason = enum(u8) {
    /// `pane attach` or `pane new`.
    attach = 0,
    /// The client moved here from another session.
    switch_client = 1,
};

/// An attach request: the client terminal's size, its device number,
/// which the daemon compares with the session's own terminal, why it
/// attaches, and the terminal's path, which names the client.
pub const AttachPayload = struct {
    size: SizePayload,
    tty_device: u64,
    reason: AttachReason,
    /// Borrowed from the payload when decoded.
    tty_name: []const u8,

    const fixed_len = 13;

    pub fn encode(self: AttachPayload, alloc: std.mem.Allocator) ![]u8 {
        const buf = try alloc.alloc(u8, fixed_len + self.tty_name.len);
        buf[0..4].* = self.size.encode();
        std.mem.writeInt(u64, buf[4..12], self.tty_device, .little);
        buf[12] = @intFromEnum(self.reason);
        @memcpy(buf[fixed_len..], self.tty_name);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!AttachPayload {
        if (payload.len < fixed_len) return error.InvalidPayload;
        return .{
            .size = try SizePayload.decode(payload[0..4]),
            .tty_device = std.mem.readInt(u64, payload[4..12], .little),
            .reason = std.enums.fromInt(AttachReason, payload[12]) orelse return error.InvalidPayload,
            .tty_name = payload[fixed_len..],
        };
    }
};

/// A terminal color as three 16-bit channels, matching the precision a
/// terminal reports for an OSC 10/11/12 query (`rgb:RRRR/GGGG/BBBB`).
pub const RgbPayload = struct {
    r: u16,
    g: u16,
    b: u16,

    pub fn encode(self: RgbPayload) [6]u8 {
        var buf: [6]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.r, .little);
        std.mem.writeInt(u16, buf[2..4], self.g, .little);
        std.mem.writeInt(u16, buf[4..6], self.b, .little);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!RgbPayload {
        if (payload.len != 6) return error.InvalidPayload;
        return .{
            .r = std.mem.readInt(u16, payload[0..2], .little),
            .g = std.mem.readInt(u16, payload[2..4], .little),
            .b = std.mem.readInt(u16, payload[4..6], .little),
        };
    }

    /// Perceived luminance on a 0..255 scale (Rec. 601 weights), computed
    /// from the high byte of each channel. Used to classify the
    /// background as light or dark for the color-scheme DSR.
    pub fn luminance(self: RgbPayload) u8 {
        const r: u32 = self.r >> 8;
        const g: u32 = self.g >> 8;
        const b: u32 = self.b >> 8;
        return @intCast((r * 299 + g * 587 + b * 114) / 1000);
    }

    pub fn isDark(self: RgbPayload) bool {
        return self.luminance() < 128;
    }
};

/// Write a full frame to a fd. Handles short writes.
pub fn writeMsg(fd: std.posix.fd_t, msg_type: MsgType, payload: []const u8) !void {
    std.debug.assert(payload.len <= max_payload);
    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(msg_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

/// Append a message to a growable buffer, for callers that queue output
/// to flush later instead of writing it to a fd right away (e.g. a
/// non-blocking socket with backpressure). A payload larger than
/// `max_payload` goes as `.part` frames carrying its leading pieces,
/// then a `msg_type` frame carrying the rest.
pub fn appendMsg(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
    msg_type: MsgType,
    payload: []const u8,
) !void {
    var rest = payload;
    while (rest.len > max_payload) {
        try appendFrame(alloc, list, .part, rest[0..max_payload]);
        rest = rest[max_payload..];
    }
    try appendFrame(alloc, list, msg_type, rest);
}

fn appendFrame(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
    msg_type: MsgType,
    payload: []const u8,
) !void {
    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(msg_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try list.appendSlice(alloc, &header);
    try list.appendSlice(alloc, payload);
}

pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) i += try std.posix.write(fd, bytes[i..]);
}

/// Incremental frame decoder. Feed bytes as they arrive from the socket,
/// pop complete messages out with next(). Payloads returned by next() are
/// valid until the following call to feed().
pub const Decoder = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    consumed: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Decoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.alloc);
    }

    /// Drops the messages next() has returned before appending, so
    /// popping many messages from one feed takes time linear in its size.
    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        self.buf.replaceRangeAssumeCapacity(0, self.consumed, &.{});
        self.consumed = 0;
        try self.buf.appendSlice(self.alloc, bytes);
    }

    /// Returns the next complete message, or null if more bytes are needed.
    pub fn next(self: *Decoder) error{PayloadTooLarge}!?Msg {
        const items = self.buf.items[self.consumed..];
        if (items.len < header_len) return null;

        const len = std.mem.readInt(u32, items[1..5], .little);
        if (len > max_payload) return error.PayloadTooLarge;
        const total = header_len + @as(usize, len);
        if (items.len < total) return null;

        self.consumed += total;
        return .{
            .type = @enumFromInt(items[0]),
            .payload = items[header_len..total],
        };
    }
};

/// Encode argv as a NUL separated string for command payloads.
pub fn encodeArgv(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(alloc, 0);
        try out.appendSlice(alloc, arg);
    }
    return out.toOwnedSlice(alloc);
}

/// Decode a NUL separated argv. Caller frees the returned slice (the
/// strings point into payload).
pub fn decodeArgv(alloc: std.mem.Allocator, payload: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, payload, 0);
    while (it.next()) |part| try list.append(alloc, part);
    return list.toOwnedSlice(alloc);
}

test "size payload roundtrip" {
    const size: SizePayload = .{ .rows = 51, .cols = 213 };
    const enc = size.encode();
    const dec = try SizePayload.decode(&enc);
    try std.testing.expectEqual(size, dec);
    try std.testing.expectError(error.InvalidPayload, SizePayload.decode("abc"));
}

test "attach payload roundtrip" {
    const alloc = std.testing.allocator;
    const request: AttachPayload = .{
        .size = .{ .rows = 51, .cols = 213 },
        .tty_device = 0x1000_0000_0000_0042,
        .reason = .switch_client,
        .tty_name = "/dev/pts/3",
    };
    const enc = try request.encode(alloc);
    defer alloc.free(enc);
    const dec = try AttachPayload.decode(enc);
    try std.testing.expectEqual(request.size, dec.size);
    try std.testing.expectEqual(request.tty_device, dec.tty_device);
    try std.testing.expectEqual(request.reason, dec.reason);
    try std.testing.expectEqualStrings(request.tty_name, dec.tty_name);
    try std.testing.expectError(error.InvalidPayload, AttachPayload.decode(enc[0..12]));
}

test "rgb payload roundtrip and luminance" {
    const white: RgbPayload = .{ .r = 0xffff, .g = 0xffff, .b = 0xffff };
    const enc = white.encode();
    try std.testing.expectEqual(white, try RgbPayload.decode(&enc));
    try std.testing.expectError(error.InvalidPayload, RgbPayload.decode("abc"));

    // White is light, black is dark.
    try std.testing.expect(!white.isDark());
    try std.testing.expect((RgbPayload{ .r = 0, .g = 0, .b = 0 }).isDark());
    // A typical dark editor background.
    try std.testing.expect((RgbPayload{ .r = 0x2828, .g = 0x2c2c, .b = 0x3434 }).isDark());
}

test "argv roundtrip" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{ "stuff", "hello world\n" };
    const enc = try encodeArgv(alloc, &argv);
    defer alloc.free(enc);
    const dec = try decodeArgv(alloc, enc);
    defer alloc.free(dec);
    try std.testing.expectEqual(@as(usize, 2), dec.len);
    try std.testing.expectEqualStrings("stuff", dec[0]);
    try std.testing.expectEqualStrings("hello world\n", dec[1]);
}

test "decoder handles fragmented and coalesced frames" {
    const alloc = std.testing.allocator;
    var dec: Decoder = .init(alloc);
    defer dec.deinit();

    // Build two frames back to back.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);
    const payload1 = "hello";
    const payload2 = "";
    try frame.append(alloc, @intFromEnum(MsgType.output));
    try frame.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, payload1.len)));
    try frame.appendSlice(alloc, payload1);
    try frame.append(alloc, @intFromEnum(MsgType.detach_req));
    try frame.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, payload2.len)));

    // Feed a single byte at a time; messages appear exactly when complete.
    var seen: usize = 0;
    for (frame.items) |byte| {
        try dec.feed(&.{byte});
        while (try dec.next()) |msg| {
            switch (seen) {
                0 => {
                    try std.testing.expectEqual(MsgType.output, msg.type);
                    try std.testing.expectEqualStrings(payload1, msg.payload);
                },
                1 => {
                    try std.testing.expectEqual(MsgType.detach_req, msg.type);
                    try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
                },
                else => return error.TestUnexpectedResult,
            }
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "decoder rejects oversized payloads" {
    const alloc = std.testing.allocator;
    var dec: Decoder = .init(alloc);
    defer dec.deinit();

    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(MsgType.input);
    std.mem.writeInt(u32, header[1..5], max_payload + 1, .little);
    try dec.feed(&header);
    try std.testing.expectError(error.PayloadTooLarge, dec.next());
}
