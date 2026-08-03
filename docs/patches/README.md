# Patches

Local patches against upstream projects, kept here so they survive a scratchpad
wipe and can be attached to an upstream issue or PR. None of these are applied
by the installers — they are carried deliberately or not at all.

## `ds4-listen_on-ipv6.patch`

Against [antirez/ds4](https://github.com/antirez/ds4) `54b36ed`. Touches
`listen_on()` in `ds4_server.c` and nothing else, +42/-17.

**Problem.** `--host` only accepts IPv4 literals. The listener is built as
`socket(AF_INET, ...)` and the address parsed with `inet_pton(AF_INET, ...)`, so
an IPv6 literal or a hostname fails to bind and the server exits. There is also
no way to listen on more than one address: one socket, one `bind()`. On a Mac
reachable over both Tailscale and the LAN, that forces `0.0.0.0` — everything or
one address.

**Change.** Resolve with `getaddrinfo(AI_PASSIVE | AI_NUMERICSERV)` and create
the socket from the resolved `ai_family`, trying each candidate until one binds.
`IPV6_V6ONLY` is cleared on IPv6 sockets, so `--host ::` serves both stacks from
a single socket — the IPv6 spelling of what `0.0.0.0` does for IPv4 alone.

`localhost` still maps to `127.0.0.1` before resolution. Left deliberately:
`getaddrinfo` would usually return `::1` first, and a client dialling
`127.0.0.1` would find nothing listening.

Nothing else needs to change. `listen_on()` has one caller, and the accept loop
is `accept(lfd, NULL, NULL)` — no client address is inspected anywhere, so no
code is family-aware.

**Verified** on macOS 26.5.2, M5 Max, built from the patched tree:

```
0803 23:37:36 ds4-server: listening on http://:::8123
ds4-serve  IPv6  TCP *:8123 (LISTEN)

curl http://[::1]:8123/v1/models      -> 200
curl http://127.0.0.1:8123/v1/models  -> 200
--host not-an-address                 -> exits non-zero, "failed to listen"
```

**Applying.**

```bash
cd ~/ghq/github.com/antirez/ds4
git apply /path/to/ds4-listen_on-ipv6.patch
make
```

Not submitted upstream.
