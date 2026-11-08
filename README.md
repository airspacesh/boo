<div align="center">
<pre>
 _ __   __ _ _ __   ___       __________
| '_ \ / _` | '_ \ / _ \     / ----   //
| |_) | (_| | | | |  __/    / --     // 
| .__/ \__,_|_| |_|\___|   / $      //  
|_|                       /________//   
</pre>

Terminal sessions that keep running when you leave.

</div>

Pane is a simple GNU screen style terminal multiplexer built on
[libghostty](https://github.com/ghostty-org/ghostty). It is designed to be used by
agents to start work in panes you can then attach and interact with. The goal is
to give agents the freedom to manage your terminal for you.

Originally forked from [coder/boo](https://github.com/coder/boo).

## Install

Build from source with [Zig](https://ziglang.org) 0.15.2, on Linux or
macOS:

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/pane ~/.local/bin/
```

## Usage

```sh
pane new work               # start a session named work and attach
pane ls                     # list sessions
pane attach work            # reattach
pane kill work              # end a session
pane switch work build      # show build where work is shown
```

Inside a session, `C-a d` detaches, `C-a Esc` scrolls the history,
`C-a m` opens a menu of sessions to switch to, and `C-a L` returns to
the session you switched from.
Run `pane help` for every command and key.

## License

[MIT](LICENSE). Ghostty itself is MIT licensed.
