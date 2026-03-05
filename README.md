# BlueGreen — Zero-Downtime TCP Hot Handoff

A proof-of-concept demonstrating **zero-downtime TCP connection migration** between
two Elixir BEAM nodes using Linux `SCM_RIGHTS` file descriptor passing.

## Architecture

```
  TCP Client <──TCP:4000──> Orchestrator (main BEAM node)
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
               v1 (peer node)             v2 (peer node)
               via OTP :peer              via OTP :peer
                    │                           │
                    └───── UDS SCM_RIGHTS ──────┘
                           (FD handoff)
```

- **Orchestrator** — Listens TCP:4000, accepts clients, manages `:peer` child nodes
- **Handler** — GenServer on each peer that owns a client socket and echoes with a version tag
- **Rust NIF** — `send_fd`/`recv_fd` over Unix Domain Sockets using `SCM_RIGHTS` ancillary data

## How It Works

1. Orchestrator boots, spawns **v1** as a separate OS process (`:peer`)
2. Client connects → orchestrator extracts the raw FD, sends it to v1 via UDS
3. v1 wraps the FD with `:socket.open/2`, echoes `"VERSION 1: ..."`
4. `Orchestrator.upgrade()` is called:
   - Spawns **v2** peer node
   - v1 sends the FD to v2 via UDS (`SCM_RIGHTS` duplicates the FD across processes)
   - v2 wraps it, starts echoing `"VERSION 2: ..."`
   - v1 peer is stopped
5. **Client never sees a disconnect** — the TCP connection survives the handoff

## Prerequisites

- Elixir ~> 1.20 / OTP 28
- Rust (for compiling the Rustler NIF)
- Linux (SCM_RIGHTS is a Unix feature)

## Quick Start

```bash
# Compile
mix deps.get && mix compile

# Terminal 1: Start the orchestrator (auto-upgrades after 20s)
elixir --sname demo -S mix run -e '
BlueGreen.Orchestrator.start_link()
spawn(fn -> Process.sleep(20_000); BlueGreen.Orchestrator.upgrade() end)
Process.sleep(:infinity)
'

# Terminal 2: Run the test client
elixir test_client.exs
```

You'll see:
```
[Client] #1 -> VERSION 1: ping 1
[Client] #2 -> VERSION 1: ping 2
[Client] #3 -> VERSION 1: ping 3
[Client] #4 -> VERSION 2: ping 4   ← handoff happened here!
[Client] #5 -> VERSION 2: ping 5
```

## Key Technical Details

| Problem | Solution |
|---|---|
| Extract FD from gen_tcp socket | `:prim_inet.getfd/1` (port-based driver) |
| Pass FD between OS processes | `sendmsg`/`recvmsg` with `SCM_RIGHTS` via Rust NIF |
| Reconstruct socket from raw FD | `:socket.open(fd, %{domain: :inet, type: :stream, protocol: :tcp})` |
| Avoid killing connection on close | Don't call `gen_tcp.close` or `:socket.close` — just leak the FD |
| Non-blocking handler for handoff | `:socket.recv/3` with `:nowait` + select messages |


