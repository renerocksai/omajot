# Spikes 0a + 0b — baz hub behind `tailscale serve`, Zig TLS/SSE client

Date: 2026-09-25. Run on **laptop** (Linux), not the M3 Max: the Mac was not
reachable over SSH from here. baz pinned by tarball at `2258ff87c668`, Zig 0.16.0.
Public URL (tailnet only): `https://laptop.your-tailnet.ts.net:8443` → hub on `127.0.0.1:8787`.

Files: `src/hub.zig` (whoami, POST ops, SSE doorbell, embedded test page, report
sink), `src/test.html` (self-reporting EventSource test, which is also the iOS test),
`src/client.zig` (Zig `std.http.Client` over TLS, streaming SSE).

## 0a — hub

| Question | Result |
|---|---|
| baz behind `tailscale serve` | **Yes.** `HTTP/2 200`, `server: bounded-http` |
| Identity headers | **Present, even from the same node**: `Tailscale-User-Login`, `Tailscale-User-Name`. A spoofed `Tailscale-User-Login: evil@x` sent through serve was **overwritten** |
| SSE through serve buffered? | **No.** POST at 17:34:51.244 → event `id: 1` at .262 (~18 ms). 3 s heartbeats arrived; the stream ended at the 15 s deadline |
| `Last-Event-ID` reconnect | **Works.** Chromium sent it automatically (hub log: `Last-Event-ID=7 head=7`, `=14 head=15`); cursor 4 with head 7 got `id: 7` immediately |
| Headless Chromium 152, 45 s, 22 pushes | **PASS**: 3 connections, 0 duplicates, 0 missed, worst latency 16 ms (`reports.log`) |
| iOS Safari | **PASS on the real hub** (see below) |

## Rerun on the M3 Max (the real hub host)

Reached with `ssh mac`. Built natively there with Zig 0.16.0 (no linker
workaround needed on macOS), run in tmux, `tailscale serve --https=8443`
next to the Mac's existing 443 route (left untouched). baz reported
`backend=kqueue`. No certificate wait: the Mac already had one from its 443 route.

**iOS Safari 26.5** (iOS simulator, iPhone 17 Pro, booted headless with `simctl`
while the Mac was screen-locked): **PASS**: 4 connections (3 reconnects at the
15 s deadline), resumed from `Last-Event-ID` 7 / 15 / 22, 22 pushes, 0 missed,
0 duplicates, worst latency 11 ms, identity headers present. Raw report:
`reports-mac-ios.log`. (`simctl bootstatus` printed "Install Failed: Authorization
is required", which did not affect Safari.)

## 0b — Zig client

| Question | Result |
|---|---|
| TLS to the Let's Encrypt `*.ts.net` cert | **Works** with the system CA bundle, no config; `whoami` 200 in 409 ms |
| Incremental SSE read | **Works**: `response.reader()` + `takeDelimiter('\n')`; events printed at +3004 / +4527 / +6042 ms, matching POSTs 1.5 s apart |

## Surprises (all folded into DESIGN.md)

- **The deadline ends streams uncleanly**: baz closes mid-body without the final
  `0\r\n\r\n` chunk. Browsers treat it as an error and reconnect (fine); the Zig
  client gets `error.ReadFailed`. → The hub should `.finish` SSE streams a few
  seconds before `timeout_ms`; the client treats `ReadFailed` as "reconnect".
- **The first HTTPS request through serve took 32.6 s** (certificate issued on
  first use); after that, 13 ms. → Warm up once with `curl` after `tailscale serve`.
- **The doorbell can outrun the POST response and merge several ops**: clients
  must treat "head ≥ H" as covering op H, never count events.
- **Linking on Linux needs `use_llvm`/`use_lld`**: Zig 0.16's self-hosted linker
  rejects GCC 16's `crt1.o` (`.sframe` relocations). baz's embedding example
  uses the same workaround.
- One early proxied run showed only a single heartbeat; three later runs did not reproduce it.
- baz fit well: the `examples/jobs.zig` notification/continuation pattern mapped
  one-to-one onto the doorbell.

## Left running

On the Mac only (the laptop hub was stopped): tmux session `omajot-spike` in
`~/omajot-spike/hub`, served at `https://your-mac.your-tailnet.ts.net:8443/`,
tailnet only. Cleanup:

```sh
ssh mac 'zsh -lic "tmux kill-session -t omajot-spike; tailscale serve --https=8443 off"'
```
