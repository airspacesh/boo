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

pane is a GNU `screen` style terminal multiplexer built on
[libghostty](https://github.com/ghostty-org/ghostty). Every session's
output runs through Ghostty's terminal core, so reattaching restores the
exact screen, and scripts and agents read the same screen you would see.

pane is a fork of [coder/boo](https://github.com/coder/boo), from its
v0.6.4 release.

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
```

Inside a session, `C-a d` detaches and `C-a Esc` scrolls the history.
Run `pane help` for every command and key.

## License

[MIT](LICENSE). Ghostty itself is MIT licensed.
