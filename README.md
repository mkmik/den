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
`just release`, `just linux aarch64`, `just run apply -f examples/den.yaml`.

## Run

den reads a `Den` resource, as YAML or JSON:

```yaml
apiVersion: den.mkm.pub/v1alpha1
kind: Den
metadata:
  name: build
  namespace: myproject
spec:
  command: ["/bin/zsh", "-l"]
  workingDir: /home/marko/src/myproject
  env:
  - name: FOO
    value: bar
  inheritEnv: ["LANG", "LC_*", "SSH_AUTH_SOCK", "TMPDIR"]
  size:
    cols: 120
    rows: 40
  history:
    memoryLines: 5000
    keepAfterExit: 24h
```

The YAML reader covers what people write by hand: block mappings and
lists, quoted and plain scalars, and comments. Inline `[...]` and `{...}`
must be valid JSON; anchors, tags and `|`/`>` block text are not supported.

    den apply -f den.yaml      # start it in the background
    den attach -f den.yaml     # use it in this terminal; Ctrl-\ detaches
    den get -f den.yaml        # the resource with status filled in (-o yaml|json)
    den logs -f den.yaml       # scrollback and screen as text (--color keeps colors)
    den send -f den.yaml make test   # type "make test" and Enter (-n: no Enter)
    den delete -f den.yaml     # stop the program and den

Without `command`, den runs your login shell (from the password database) as
a login shell. The program starts from a fresh login environment: `HOME`,
`USER`, `LOGNAME`, `SHELL` and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. On top of
that come the variables named in `inheritEnv`, copied from the environment
`den apply` ran with (exact names, or prefixes ending in `*`, e.g.
`["LANG", "LC_*", "SSH_AUTH_SOCK", "TMPDIR"]`; `["*"]` copies everything), then
`TERM=xterm-256color` and `DEN_SOCKET`, then `env`. den passes nothing through on its own:
which variables to inherit is up to whatever writes the spec.

`-f` (`--filename`) takes a path, absolute or relative, or a URL:

    den apply -f den.yaml
    den apply -f file:///home/marko/den.yaml
    den apply -f https://example.com/dens/build.yaml
    den apply -f http+unix://%2Frun%2Fapi.sock/v1/dens/build
    den apply -f http://api/v1/dens/build --unix-socket /run/api.sock

The last two both ask the HTTP server on the Unix socket `/run/api.sock` for
`/v1/dens/build`. In `http+unix://` the host is the socket path with each `/`
written as `%2F` (the same form as Python's requests-unixsocket and HTTPie);
the Host header is `localhost`. `--unix-socket` works like curl's: the URL
must be `http://`, and its host only goes in the Host header.
Whatever comes back is read as if it came from a file. The server must answer 2xx; den reads at most 1 MiB
and follows redirects only over TCP.

When the spec came from an HTTP URL, den reports its status back to the same
URL with `/status` added to the path (`.../dens/build` becomes
`.../dens/build/status`, the query is kept), the way a Kubernetes status
subresource works. Each time the status changes, den sends

    PATCH .../dens/build/status
    Content-Type: application/merge-patch+json

    {"metadata":{"uid":"..."},"status":{"phase":"Running",...}}

the same `status` that `den get` shows. `metadata.uid` is there only when the
spec had one; a Kubernetes-style server answers 409 when it no longer matches
(the Den was deleted and created again). den sends at most one PATCH every 5 s
(`--status-interval`, e.g. `--status-interval 30s`), always the newest
status, and retries at the same pace while the server is unreachable or
answers 5xx or 429. The last PATCH, after the program exits or on
`den delete`, has phase `Exited` and goes out right away; den waits at most
1 s for it before exiting. A spec read from a file reports nothing.

den also holds a `coordination.k8s.io/v1` Lease named after the Den, so the
server can tell a quiet den from a dead one. It first asks the server whether
it serves Leases (`GET /apis/coordination.k8s.io/v1` on the spec URL's host
or socket); when the answer lists `leases`, den applies

    PATCH /apis/coordination.k8s.io/v1/namespaces/<ns>/leases/<name>?fieldManager=den&force=true
    Content-Type: application/apply-patch+yaml

with `holderIdentity` (`<host>/<den pid>`), `leaseDurationSeconds: 30`,
`renewTime` and, when the spec had a `metadata.uid`, an owner reference to
the Den, so the Lease goes away with it. den renews it every 10 s for as long
as it runs, and stops when a status PATCH answers 404 or 409. When den is
gone, the Lease simply expires. A server that answers discovery with a 4xx,
or without `leases`, gets no Lease.

den prints its socket path and goes into the background. The socket is
`$XDG_RUNTIME_DIR/den/<namespace>/<name>.sock`. Where `XDG_RUNTIME_DIR` is not
set (macOS) it is `$XDG_STATE_HOME/den/<namespace>/<name>.sock`, which is
`~/.local/state/den/<namespace>/<name>.sock` by default.
den logs to `<name>.log` next to the socket (also `status.log`); it keeps the
file when it exits.
den exits `keepAfterExit` after the program exits, or on `den delete` or SIGTERM
(it sends the program SIGHUP, then SIGKILL after 5 seconds).

Once the program has exited its screen cannot change, so den writes the final
screen and scrollback to `$XDG_STATE_HOME/den/<namespace>/<name>.final`
(default `~/.local/state/den/...`, mode 0600), frees the terminal emulator,
and answers attaches from that file. An exited den uses about 1 MB. den
deletes the file when it exits.

## Protocol

Length-prefixed binary frames over the Unix socket. The wire format is
documented at the top of [`src/proto.zig`](src/proto.zig).

Design and plans: [`docs/PRD.md`](docs/PRD.md).
