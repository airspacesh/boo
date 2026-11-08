# pane

Terminal sessions that keep running when you leave.

pane is a fork of [coder/boo](https://github.com/coder/boo), from its
v0.6.4 release.

[Install](#install) | [Usage](#usage) | [Automation](#automation) | [Why](#why-pane) | [Architecture](#architecture)

[![ci](https://github.com/airspacesh/pane/actions/workflows/ci.yml/badge.svg)](https://github.com/airspacesh/pane/actions/workflows/ci.yml)

A GNU `screen` style terminal multiplexer built on
[libghostty](https://github.com/ghostty-org/ghostty)
(`libghostty-vt`), written in Zig.

Every session's output is parsed through Ghostty's terminal emulation
core, so pane always knows the exact screen state of every session:
contents, styles, cursor, scrollback, and terminal modes. That state is
used to rehydrate your terminal on attach, to answer terminal queries
for detached sessions, and to let scripts and AI agents read the screen
exactly as a human would see it.

## Features

- Sessions that survive disconnects: detach with `Ctrl-A d`, reattach with `pane attach`.
- Faithful redraws from libghostty terminal state, including SGR styles, cursor position, scrolling regions, window title, and terminal modes.
- Agent-friendly automation primitives: `send`, `peek`, `wait`, and `--json` output, all usable without a TTY.

## Install

Build from source with [Zig](https://ziglang.org) 0.15.2, on Linux or
macOS:

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/pane ~/.local/bin/
```

## Usage

```sh
pane new                    # new session running $SHELL, attached
pane new work               # named session
pane new work -d -- make    # create detached, running a command
pane ls                     # list sessions
pane attach work            # reattach (alias: at, a)
pane rename work api        # rename a session
pane kill work              # end a session
pane kill --all             # end every session
```

With no name, `pane new` names the session after the current directory,
falling back to the process id when that name is taken or unusable.
`attach` accepts a unique prefix of a session's name (`pane at w`), and
every other command takes the exact name, so a script cannot act on the
wrong session.

Run `pane help` for the full overview, `pane help <command>` for flags
and examples, and `pane help --all` to print every help page at once.

### Key bindings (prefix `Ctrl-a`)

Bindings follow GNU screen's defaults, including the `C-x` variants
(`C-a C-d` detaches just like `C-a d`).

| Keys      | Action                              |
|-----------|-------------------------------------|
| `C-a d`, `C-a C-d` | detach                     |
| `C-a l`, `C-a C-l` | redraw                     |
| `C-a [`, `C-a Esc` | scroll the history (copy mode) |
| `C-a a`   | send a literal `C-a`                |

In copy mode, `k`/`j` or the arrow keys move a row, `C-u`/`C-d` half a
page, `C-b`/`C-f` or PgUp/PgDn a page, and `g`/`G` or Home/End jump to
the top or bottom of the history. `q` or `Esc` returns to the live
screen.

### Automation

Everything except `attach` works without a terminal, which makes pane a
natural sandbox for scripts and AI agents driving interactive programs.
The canonical loop:

```sh
pane new build -d -- bash               # 1. headless session
pane send build --text 'make' --enter   # 2. type into it
pane wait build --idle                  # 3. let output settle
pane peek build --scrollback            # 4. read the screen
pane kill build                         # 5. clean up
```

- **Reading state**: `peek` prints the rendered screen reconstructed
  from terminal state, not a raw byte log: ordered, fully redrawn, and
  stable. `--scrollback` includes history; `--json` adds size, cursor,
  and title.
- **Waiting**: `wait --text <text>` blocks until the screen contains
  the text; `wait --idle` until output has been quiet for 2 seconds;
  `--timeout <dur>` exits 4 instead of hanging forever (durations:
  `500ms`, `2s`, `1m`, `4h`, `1d`). No more sleep-and-poll loops.
- **Sending input**: `send --text` is literal: no escape processing, no
  implicit newline, no quoting layer to fight. `--enter` submits,
  `--key Enter,C-c,Up` names control keys, and stdin mode is binary
  safe.
- **Machine-readable output**: `ls --json` and `peek --json`.
- **Exit codes**: `0` success, `1` error, `2` usage error, `3` no such
  session, `4` wait timed out.

See `pane help automation` for the full page.

## Why pane?

GNU screen works the same way pane does, architecturally: it parses all
output through its own built-in terminal emulator and redraws from
that state on reattach. But that emulator is decades old and lags far
behind what modern programs emit. Whatever it doesn't understand gets
dropped or mangled on redraw. pane swaps that layer for `libghostty-vt`,
Ghostty's VT core, so the saved state matches what your terminal would
actually display, and terminal queries are answered while detached so
TUIs don't hang unattended.

Scripting is the other win: `send`, `peek --json`, and
`wait --text`/`--idle` instead of `-X stuff`, hardcopy files, and
sleep loops.

tmux is great, it just solves a different problem. pane keeps screen's
model by design: sessions, a prefix key, and nothing else to learn.
One session per task.

## Contributing

Requires [Zig](https://ziglang.org) 0.15.2.

```sh
zig build                       # binary in zig-out/bin/pane
zig build test                  # unit tests
zig build test-integration     # end-to-end tests on a real PTY
zig build test-all             # everything
```

The libghostty dependency is fetched and built from source
automatically (pinned in `build.zig.zon`).

## Architecture

```
your terminal <-(raw tty)-> pane client <-(unix socket)-> session daemon
                                                         `- PTY + ghostty-vt Terminal
```

- The **client** puts your TTY in raw mode and shuttles bytes over a
  framed Unix-socket protocol (`src/protocol.zig`).
- The **daemon** (forked on session creation) owns the session's
  command: a PTY-attached child whose output feeds a persistent
  `ghostty-vt` `TerminalStream` (`src/window.zig`).
- While attached, output is passed through to your terminal byte for
  byte. On attach the daemon sanitizes your terminal and replays the
  screen from libghostty state using its VT `TerminalFormatter`.
- Terminal queries (DSR, DA, XTWINOPS, ...) while detached are answered
  by libghostty's stream handler; while attached your real terminal
  answers, avoiding double replies.

## Caveats

This is a young project, not a drop-in GNU screen replacement:

- One attached client per session (attaching steals); no `-x` sharing.
- One window per session: no splits or tabs inside a session. Run one
  session per task.
- The `C-a` prefix is not yet configurable, and pasted bytes containing
  `0x01` are interpreted as the prefix (GNU screen has the same quirk).
- Sessions run with `TERM=xterm-256color`.

## Support

Feel free to [open an issue](https://github.com/airspacesh/pane/issues/new)
if you have questions, run into bugs, or have a feature request.

## License

[MIT](LICENSE). Ghostty itself is MIT licensed.
