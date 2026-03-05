# BlueGreen — Zero-Downtime TCP Hot Handoff

A proof-of-concept demonstrating **zero-downtime TCP connection migration** between
two Elixir BEAM nodes using Linux `SCM_RIGHTS` file descriptor passing.

## Architecture

```
  TCP Client <──TCP:$PORT──> Orchestrator (main BEAM node)
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
               v1 (peer node)             v2 (peer node)
               via OTP :peer              via OTP :peer
                    │                           │
                    └───── UDS SCM_RIGHTS ──────┘
                           (FD handoff)
```

- **Orchestrator** — Listens on `$PORT` (via [`phx-port`](https://github.com/chgeuer/phx-port), defaults to 4000), accepts clients, manages `:peer` child nodes
- **Handler** — GenServer on each peer that owns a client socket and echoes with a version tag
- **Rust NIF** — `send_fd`/`recv_fd` over Unix Domain Sockets using `SCM_RIGHTS` ancillary data

## How It Works

1. Orchestrator boots inside the application supervisor, spawns **v1** as a separate OS process (`:peer`)
2. Client connects → orchestrator extracts the raw FD via `:prim_inet.getfd/1`, sends it to v1 via UDS + SCM_RIGHTS NIF
3. v1 wraps the FD with `:socket.open/2`, echoes `"VERSION 1: ..."` using non-blocking select
4. `BlueGreen.Orchestrator.upgrade()` is called (e.g. via `just upgrade`):
   - Spawns **v2** peer node
   - v2 starts a UDS receiver (dirty NIF, blocks until FD arrives)
   - Orchestrator tells v1's Handler to hand off: v1 sends its FD to v2 via UDS
   - v2 wraps the FD, starts echoing `"VERSION 2: ..."`
   - v1 peer is stopped
5. **Client never sees a disconnect** — the TCP connection survives the handoff

## Prerequisites

- Elixir ~> 1.20 / OTP 28
- Rust (for compiling the Rustler NIF)
- Linux (SCM_RIGHTS is a Unix feature)
- [`phx-port`](https://github.com/chgeuer/phx-port) — stable per-project port assignments (optional; falls back to 4000)

## Quick Start

```bash
# Compile
mix deps.get && mix compile

# Start the BEAM node (orchestrator auto-starts on TCP port from phx-port)
just start

# In another terminal: connect the test client
just client

# In a third terminal: trigger the hot upgrade
just upgrade

# Or run the full demo in one terminal
just auto
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

## The "Relay Race" Deployment: Understanding Hot Blue-Green Deploys in Elixir

In the world of DevOps, we've been conditioned to accept a certain level of violence during deployments. We "kill" containers, "drain" nodes, and "terminate" instances. Even with modern orchestrators like Kubernetes, a deployment is essentially a high-speed replacement: out with the old, in with the new, and hope the load balancer handles the handoff gracefully.

But what if you didn't have to kill anything? What if your new code could simply "step into" the existing network connections of the old code, like a relay runner taking a baton at full speed?

This is the "Hot Blue-Green" deployment pattern—a technique that leverages the unique architecture of the Erlang Virtual Machine (BEAM) to achieve zero-downtime upgrades without dropping a single TCP packet.

---

### The Secret Sauce: The VM within a VM

Most runtimes are guests on the Operating System. The BEAM, however, acts like a distributed OS itself. Using the `:peer` module, a running Elixir application can spawn a second, independent VM instance as a child process.

In a modern setting (like the Fly.io environment mentioned in the original tweets), your "Primary" node acts as a thin **Control Plane**. It doesn't run your web server; it manages the workers that do.

When you want to deploy version 2.0:

1. The Parent node boots a **Peer VM** (the "Green" node) via OTP's `:peer` module. The new VM inherits the same code paths, so it can immediately run the latest compiled modules.
2. The Parent orchestrates the FD handoff from the old Handler to the new one.
3. Both VMs are clustered via Erlang distribution, so the Parent can call functions on either peer with `:erpc` — negligible latency, full introspection.

---

### The "Impossible" Trick: SCM_RIGHTS

Here is where it gets technical. Usually, a TCP connection is a "file" owned by a specific OS process ID (PID). If that PID dies, the connection dies.

To solve this, we use a Unix syscall called `sendmsg` with the `SCM_RIGHTS` flag, wrapped in a [Rustler](https://github.com/rusterlium/rustler) NIF for safe integration with the BEAM. This allows one OS process to literally "pass" a file descriptor (the handle for the TCP socket) to another process on the same machine.

1. **The Handover:** The Old VM (Blue) reaches a "quiescence" state. Its Handler GenServer holds the open socket and stops processing new data.
2. **The Pass:** The Handler sends the file descriptor of the active client connection to the New VM (Green) through a Unix Domain Socket using the Rust NIF.
3. **The Adoption:** Green receives the integer FD, wraps it back into an Erlang `:socket` reference via `:socket.open/2`, and resumes the echo logic using Version 2.0 of the code.

The client on the other end of the wire sees absolutely nothing. No disconnect, no 503 error, no "reconnecting..." spinner. Just a seamless transition to the new logic.

---

### Why This Matters Today

You might ask: *"Why bother when I have Kubernetes and Load Balancers?"* Standard Blue-Green deployments at the infrastructure level are "cold." The load balancer shifts traffic, but existing connections are usually severed or left to "drain" (which can take minutes). This is a nightmare for:

* **Stateful Applications:** Collaborative editors (like Figma or Livebook) where users have active sessions in memory.
* **Long-lived Connections:** Gaming servers, IoT command-and-control, or high-frequency trading feeds.
* **Low-Power Edge Devices:** Where a full container restart is too heavy for the hardware.

### Modern Setting: The Edge

We are seeing a shift toward "intelligent edges." Platform providers like Fly.io allow you to run these nodes extremely close to the user. By using Hot Blue-Green deploys on the edge, you can update your global application logic in milliseconds.

Because the Parent node handles the orchestration, you can even perform **State Handoff**. Since the Blue and Green nodes are clustered, Blue can serialize a user's current session state and send it to Green over the Erlang distribution protocol *at the same time* it hands over the TCP socket.

---

### Summary: The New Standard for Reliability

The Elixir ecosystem continues to prove that "old" telecom-grade reliability is the ultimate "modern" feature. By treating the VM as a fleet of manageable peers rather than a monolithic process, we can move away from the "kill and restart" mentality and toward a more fluid, continuous evolution of running code.

It's not just a deployment; it's a seamless evolution.
