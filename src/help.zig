//! All user-facing help text: the overview, per-command help, and
//! topic pages. Kept in one place so the CLI surface reads as a whole
//! and stays consistent.

pub const Entry = struct {
    /// Primary command or topic name.
    name: []const u8,
    /// Optional short alias (e.g. `at` for `attach`).
    alias: ?[]const u8 = null,
    /// Full help text printed by `pane help <name>`.
    body: []const u8,
};

pub const overview =
    \\pane: terminal sessions that keep running when you leave
    \\
    \\A terminal multiplexer in the spirit of GNU screen, built on
    \\libghostty. Sessions keep running when you disconnect; reattach
    \\and the screen, scrollback, and title come back exactly as a
    \\human would see them.
    \\
    \\usage:
    \\  pane <command> [arguments]
    \\
    \\commands:
    \\
    \\  Session Management
    \\    new [name] [-d] [-- cmd...]  start a session (attach unless -d)
    \\    attach, at, a <name>         attach a session (steals politely)
    \\    switch <client> <session>    show another session in a client
    \\    ls [--json]                  list sessions
    \\
    \\  Interaction
    \\    send <name> [flags]          type into a session
    \\    peek <name>                  print the session's screen
    \\    wait <name>                  block until output matches or settles
    \\
    \\  Administration
    \\    kill <name | --all>          end a session, or all of them
    \\    rename <name> <new-name>     rename a session
    \\
    \\  Information
    \\    version                      print the version
    \\    help [page]                  this overview, or detailed help
    \\
    \\Run 'pane help <command>' for flags and examples, 'pane help keys'
    \\for the key bindings inside a session, 'pane help automation' for
    \\driving pane from scripts, or 'pane help --all' for every page.
    \\
    \\session selection:
    \\  attach accepts a unique prefix of the session name (e.g.
    \\  'pane attach bu' for "build"). Other commands take the exact
    \\  name.
    \\
    \\environment:
    \\  PANE_DIR  socket directory
    \\           (default: /tmp/pane-<uid>)
    \\  PANE_LOG  append daemon logs to this file (debugging)
    \\
;

pub const commands = [_]Entry{
    .{
        .name = "new",
        .body =
        \\usage: pane new [name] [-d|--detached] [--rows N] [--cols N] [-- cmd...]
        \\
        \\Start a session running cmd (default: $SHELL) and attach to
        \\it. The session keeps running after you detach (C-a d) or
        \\lose the connection.
        \\
        \\Names may contain letters, digits, '.', '_', and '-'. The
        \\default name is the name of the current directory, or the
        \\process id when that name is taken or unusable. Everything
        \\after '--' is the command to run in the session.
        \\
        \\flags:
        \\  -d, --detached  start without attaching and print the
        \\                  session name on stdout
        \\  --rows N        initial terminal height (default 24); the
        \\                  next attach resizes to the real terminal
        \\  --cols N        initial terminal width (default 80)
        \\                  Sessions are at most 4096 rows by 4096
        \\                  columns.
        \\  --cwd DIR       run the command in DIR instead of the
        \\                  current directory (must already exist)
        \\
        \\examples:
        \\  pane new                      interactive shell, attach now
        \\  pane new work                 named session
        \\  pane new build -d -- make -j  background a build
        \\
        ,
    },
    .{
        .name = "attach",
        .alias = "at",
        .body =
        \\usage: pane attach <name>
        \\       pane at <name>
        \\       pane a <name>
        \\
        \\Attach this terminal to a session. The screen, scrollback,
        \\cursor, and title are restored from terminal state. If the
        \\session is attached elsewhere, the other client is detached
        \\(the session is stolen). Attaching the session you are inside
        \\is refused.
        \\
        \\A unique prefix of the name is accepted.
        \\
        \\Inside the session, press C-a d to detach. See 'pane help
        \\keys' for all bindings.
        \\
        \\examples:
        \\  pane attach build     reattach "build"
        \\  pane at bu            the same, by prefix
        \\
        ,
    },
    .{
        .name = "switch",
        .body =
        \\usage: pane switch <client> <session>
        \\
        \\Show another session in an attached client, as if it had
        \\attached that session itself. Name the client by the session
        \\it shows now, or by its terminal, like /dev/pts/3 or pts/3
        \\('pane ls --json' lists each session's client). The client
        \\shows "switched to <session>" until a key is pressed a second
        \\after the switch, and C-a L takes it back.
        \\
        \\examples:
        \\  pane switch chief build     show build where chief is shown
        \\  pane switch pts/3 build     show build on terminal pts/3
        \\
        ,
    },
    .{
        .name = "ls",
        .alias = "list",
        .body =
        \\usage: pane ls [--json]
        \\
        \\List sessions: name, attach state, idle time (time since the
        \\last output or client input), the status its program reports,
        \\and the session's title. A session that does not answer within
        \\a second is listed as busy. Stale sockets left by crashed
        \\daemons are cleaned up.
        \\
        \\Programs such as coding agents report their status with OSC
        \\7501, the Program Status Protocol: idle, working, done,
        \\blocked, or error. pane keeps each session's latest report
        \\and gives it to the terminal of the client attached to it.
        \\
        \\flags:
        \\  --json  emit a JSON array:
        \\          [{"name","responding","attached","idle_ms","unread",
        \\            "bell_idle_ms","pid","title","client","status"}]
        \\          ("unread" flags unseen output; "bell_idle_ms" is the
        \\           age of a bell rung while away, -1 if none; "pid" is
        \\           the session command's pid, -1 once it has exited;
        \\           "client" is the attached client's terminal, or null;
        \\           "status" is {"state","kind","progress","app","title",
        \\           "msg"} with the keys the program sent, or null)
        \\          A busy session has only "name" and "responding".
        \\
        ,
    },
    .{
        .name = "send",
        .body =
        \\usage: pane send <name> [--text <text>] [--key <list>] [flags]
        \\
        \\Type into a session, exactly as if the text had been typed
        \\at the keyboard. --text is sent literally: no escape
        \\processing and no implicit newline, so there is never a
        \\quoting layer to fight. With neither --text nor --key,
        \\bytes are read from stdin (binary safe, NUL excluded).
        \\
        \\flags:
        \\  --text <text>  the text to type
        \\  --enter        append Enter after everything else
        \\  --key <list>   send named keys, comma separated:
        \\                 Enter, Tab, Escape, Space, Backspace,
        \\                 Up, Down, Left, Right, Home, End, C-a..C-z.
        \\                 Cannot be combined with --text; use two calls.
        \\  --stdin        force reading from stdin
        \\
        \\examples:
        \\  pane send build --text 'make test' --enter   run a command
        \\  pane send build --key C-c                    interrupt it
        \\  printf 'y\n' | pane send build               pipe bytes in
        \\
        ,
    },
    .{
        .name = "peek",
        .body =
        \\usage: pane peek <name> [--scrollback] [--json]
        \\
        \\Print the session's rendered screen: what a human attached
        \\right now would see, reconstructed from terminal state (not
        \\a raw byte log). Safe to run while attached.
        \\
        \\flags:
        \\  --scrollback  include the full scrollback history
        \\  --json        emit {"session","title","rows","cols",
        \\                "cursor":{"row","col"},"screen"}
        \\
        \\examples:
        \\  pane peek build | tail -20
        \\  pane peek build --scrollback | grep -n error
        \\
        ,
    },
    .{
        .name = "wait",
        .body =
        \\usage: pane wait <name> (--text <text> | --idle) [--timeout <dur>]
        \\
        \\Block until something happens in the session, then exit 0.
        \\Replaces sleep-and-poll loops in scripts.
        \\
        \\flags:
        \\  --text <text>    until the rendered screen contains <text>
        \\                   (plain substring match)
        \\  --idle           until the session has produced no output
        \\                   for 2 seconds
        \\  --timeout <dur>  give up and exit 4 (default: 30s)
        \\
        \\Durations are an integer with a unit: 500ms, 2s, 1m, 4h
        \\(or 4hr), 1d. Flags also accept --flag=value.
        \\
        \\examples:
        \\  pane wait build --text 'PASS' --timeout 2m
        \\  pane wait build --idle && pane peek build
        \\
        ,
    },
    .{
        .name = "kill",
        .body =
        \\usage: pane kill <name | --all>
        \\
        \\End a session: its process receives SIGHUP and the daemon
        \\exits. --all ends every session and sweeps stale sockets.
        \\
        \\examples:
        \\  pane kill build
        \\  pane kill --all
        \\
        ,
    },
    .{
        .name = "rename",
        .body =
        \\usage: pane rename <name> <new-name>
        \\
        \\Rename a session. The running program is unaffected and an
        \\attached client stays attached.
        \\
        \\example:
        \\  pane rename work api-server
        \\
        ,
    },
    .{
        .name = "version",
        .body =
        \\usage: pane version
        \\
        \\Print the pane version. Also available as -V or --version.
        \\
        ,
    },
    .{
        .name = "help",
        .body =
        \\usage: pane help [page] [--all]
        \\
        \\Show the overview or a detailed page. There is a page for
        \\every command, plus 'keys' (the C-a bindings inside a
        \\session) and 'automation' (driving pane from scripts and AI
        \\agents). --all prints every page in one pass, which is handy
        \\for piping into a pager or for tools that want to learn the
        \\whole CLI in one call.
        \\
        ,
    },
};

pub const topics = [_]Entry{
    .{
        .name = "keys",
        .body =
        \\Key bindings inside an attached session (prefix C-a)
        \\
        \\  C-a d   detach
        \\  C-a l   redraw
        \\  C-a [   scroll the session's history (copy mode), also C-a Esc
        \\  C-a m   pick a session to switch to from a menu
        \\  C-a L   return to the session you switched from
        \\  C-a a   send a literal C-a
        \\
        \\Control variants match GNU screen: C-a C-d detaches and
        \\C-a C-l redraws. C-a C-m opens the menu, so ctrl may stay
        \\held for it too. Detaching leaves the session running;
        \\'pane attach' brings it back.
        \\
        \\Copy mode keys
        \\
        \\  k, Up        up a row
        \\  j, Down      down a row
        \\  C-u, C-d     up or down half a page
        \\  C-b, PgUp    up a page
        \\  C-f, PgDn    down a page
        \\  g, Home      top of the history
        \\  G, End       bottom of the history
        \\  q, Esc       back to the live screen
        \\
        \\The tag at the top right shows how many rows you have scrolled
        \\back, out of the rows of history. Output keeps reaching the
        \\session while you scroll.
        \\
        \\The menu lists the sessions as 'pane ls' does, with the cursor
        \\on this one. It moves with the copy mode keys, Enter switches
        \\to the session under the cursor, and q or Esc closes the menu.
        \\
        ,
    },
    .{
        .name = "automation",
        .body =
        \\Driving pane from scripts and AI agents
        \\
        \\Everything except 'attach' works without a terminal. The
        \\canonical loop:
        \\
        \\  pane new build -d -- bash               # 1. headless session
        \\  pane send build --text 'make' --enter   # 2. type into it
        \\  pane wait build --idle                  # 3. let output settle
        \\  pane peek build --scrollback            # 4. read the screen
        \\  pane kill build                         # 5. clean up
        \\
        \\reading state:
        \\  peek prints the rendered screen, not a raw byte stream:
        \\  ordered, fully redrawn, and stable. --scrollback includes
        \\  history; --json adds size, cursor, and title.
        \\
        \\waiting (instead of sleep):
        \\  pane wait <name> --text <text>   screen contains <text>
        \\  pane wait <name> --idle          output quiet for 2 seconds
        \\  pane wait <name> ... --timeout <dur>   exit 4 on timeout
        \\
        \\sending input:
        \\  send is literal: no escapes, no implicit newline, no
        \\  quoting layer. --enter submits; --key Enter,C-c,Up names
        \\  control keys; stdin mode is binary safe.
        \\
        \\machine-readable output:
        \\  pane ls --json    [{"name","responding","attached","idle_ms",
        \\                    "unread","bell_idle_ms","pid","title","client",
        \\                    "status"}]
        \\  pane peek --json  {"session","title","rows","cols",
        \\                    "cursor":{"row","col"},"screen"}
        \\
        \\exit codes:
        \\  0 success    1 error    2 usage error
        \\  3 no such session       4 wait timed out
        \\
        \\tips:
        \\  - Sessions are cheap; use one session per task.
        \\  - 'pane new -d' prints the session name on stdout.
        \\
        ,
    },
};

pub fn find(name: []const u8) ?*const Entry {
    const eql = @import("std").mem.eql;
    for (&commands) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
        if (entry.alias) |alias| {
            if (eql(u8, alias, name)) return entry;
        }
    }
    for (&topics) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
    }
    return null;
}
