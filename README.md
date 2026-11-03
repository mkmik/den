# den

a safe space for your processes

den runs one program on its own PTY in the background and keeps its terminal
state, so clients can attach, detach and reattach without losing anything.
When you reattach while a program such as vim is on the alternate screen,
den sends both screens, so the main screen and its scrollback come back when
the program exits.

## Build

Needs Zig 0.17.

    zig build          # builds zig-out/bin/den
    zig build test     # unit tests plus an end-to-end test of the real binary

Or use `just` (run `just` to list recipes): `just build`, `just test`,
`just release`, `just linux aarch64`, `just run spawn --spec examples/den.json`.

## Run

den reads a `Den` resource. For now it must be JSON (JSON is valid YAML):

```json
{
  "apiVersion": "den.mkm.pub/v1alpha1",
  "kind": "Den",
  "metadata": { "name": "build", "namespace": "myproject" },
  "spec": {
    "command": ["/bin/zsh", "-l"],
    "workingDir": "/home/marko/src/myproject",
    "env": [{ "name": "FOO", "value": "bar" }],
    "size": { "cols": 120, "rows": 40 },
    "history": { "memoryLines": 5000, "keepAfterExit": "24h" }
  }
}
```

    den spawn --spec den.json    # start it in the background
    den attach --spec den.json   # use it in this terminal; Ctrl-\ detaches
    den status --spec den.json   # the resource with status filled in (-o yaml|json)
    den history --spec den.json  # scrollback and screen as text (--color keeps colors)
    den send --spec den.json make test   # type "make test" and Enter (-n: no Enter)
    den kill --spec den.json     # stop the program and den

`--spec` takes a path, absolute or relative, or a `file:///absolute/path` URL.

den prints its socket path and goes into the background. The socket is
`$XDG_RUNTIME_DIR/den/<namespace>/<name>.sock`. Where `XDG_RUNTIME_DIR` is not
set (macOS) it is `$XDG_STATE_HOME/den/<namespace>/<name>.sock`, which is
`~/.local/state/den/<namespace>/<name>.sock` by default.
den exits `keepAfterExit` after the program exits, or on `den kill` or SIGTERM
(it sends the program SIGHUP, then SIGKILL after 5 seconds).

Once the program has exited its screen cannot change, so den writes the final
screen and scrollback to `$XDG_STATE_HOME/den/<namespace>/<name>.final`
(default `~/.local/state/den/...`, mode 0600), frees the terminal emulator,
and answers attaches from that file. An exited den uses about 1 MB. den
deletes the file when it exits.

## Protocol

Length-prefixed binary frames over the Unix socket. The wire format is
documented at the top of [`src/proto.zig`](src/proto.zig).
