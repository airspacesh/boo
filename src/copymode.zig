//! Copy mode keys, which scroll a session's history as in GNU screen.
//!
//! `C-a Esc` or `C-a [` stops passing a window's output through to the
//! attached client and shows it the window's viewport instead, which
//! these keys scroll through the history. The frame resets the client's
//! keyboard modes, so keys arrive as plain bytes and VT220 sequences
//! (CSI or SS3) whatever the application had enabled.

const std = @import("std");
const vt = @import("ghostty-vt");

pub const Action = enum {
    line_up,
    line_down,
    half_page_up,
    half_page_down,
    page_up,
    page_down,
    top,
    bottom,
    exit,
};

/// One decoded key: the action it maps to, or null for a key copy mode
/// ignores, and how many input bytes it spans.
pub const Key = struct {
    action: ?Action,
    len: usize,
};

/// Decode the key at the start of `input`, which must not be empty.
pub fn decodeKey(input: []const u8) Key {
    const byte = input[0];
    if (byte == 0x1b) return decodeEscape(input);
    return .{
        .len = 1,
        .action = switch (byte) {
            'k' => .line_up,
            'j' => .line_down,
            0x15 => .half_page_up, // C-u
            0x04 => .half_page_down, // C-d
            0x02 => .page_up, // C-b
            0x06 => .page_down, // C-f
            'g' => .top,
            'G' => .bottom,
            'q' => .exit,
            else => null,
        },
    };
}

/// A lone Esc leaves copy mode. A CSI or SS3 sequence is a cursor or
/// editing key. Any other escape, like Alt with a key, is ignored.
fn decodeEscape(input: []const u8) Key {
    if (input.len == 1) return .{ .action = .exit, .len = 1 };
    const introducer = input[1];
    if (introducer != '[' and introducer != 'O') return .{ .action = null, .len = 2 };

    // Parameter bytes run up to the final byte, 0x40 to 0x7e (ECMA-48
    // section 5.4). A sequence cut off by the end of the read is
    // dropped whole.
    var end: usize = 2;
    while (end < input.len and (input[end] < 0x40 or input[end] > 0x7e)) end += 1;
    if (end == input.len) return .{ .action = null, .len = input.len };

    const params = input[2..end];
    const action: ?Action = switch (input[end]) {
        'A' => .line_up,
        'B' => .line_down,
        'H' => .top,
        'F' => .bottom,
        '~' => if (std.mem.eql(u8, params, "5"))
            .page_up
        else if (std.mem.eql(u8, params, "6"))
            .page_down
        else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7"))
            .top
        else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8"))
            .bottom
        else
            null,
        else => null,
    };
    return .{ .action = action, .len = end + 1 };
}

/// How `action` scrolls a viewport `rows` tall. Exit does not scroll.
pub fn viewportScroll(action: Action, rows: u16) vt.Terminal.ScrollViewport {
    const page: isize = rows;
    const half_page: isize = @max(1, @divTrunc(page, 2));
    return switch (action) {
        .line_up => .{ .delta = -1 },
        .line_down => .{ .delta = 1 },
        .half_page_up => .{ .delta = -half_page },
        .half_page_down => .{ .delta = half_page },
        .page_up => .{ .delta = -page },
        .page_down => .{ .delta = page },
        .top => .top,
        .bottom => .bottom,
        .exit => unreachable,
    };
}

fn expectKeys(input: []const u8, want: []const ?Action) !void {
    var rest = input;
    for (want) |action| {
        const key = decodeKey(rest);
        try std.testing.expectEqual(action, key.action);
        rest = rest[key.len..];
    }
    try std.testing.expectEqual(@as(usize, 0), rest.len);
}

test "keys decode in sequence, ignoring the ones copy mode has no use for" {
    try expectKeys("kjx\x15\x04\x02\x06gGq", &.{
        .line_up, .line_down, null, .half_page_up, .half_page_down,
        .page_up, .page_down, .top, .bottom,       .exit,
    });
}

test "cursor and editing keys decode in CSI and SS3 forms" {
    try expectKeys("\x1b[A\x1bOB\x1b[5~\x1b[6~\x1b[H\x1bOF\x1b[1~\x1b[4~", &.{
        .line_up, .line_down, .page_up, .page_down, .top, .bottom, .top, .bottom,
    });
}

test "a lone Esc exits, but Alt with a key and unknown sequences do not" {
    try expectKeys("\x1bx\x1b[2~\x1b", &.{ null, null, .exit });
}

test "a sequence cut off by the end of the read is dropped" {
    try expectKeys("\x1b[5", &.{null});
}
