set shell := ["bash", "-euo", "pipefail", "-c"]

export PORT := `phx-port`
dev          := "scripts/dev_node.sh"

# List available tasks
default:
    @just --list

# Compile the project and Rust NIF
build:
    mix deps.get
    mix compile
    @# Ensure NIF .so exists (Rustler incremental build can skip it)
    @test -f _build/dev/lib/blue_green/priv/native/socket_handoff.so \
      || { echo "⚠ NIF missing, forcing rebuild…"; mix clean && mix compile; }

# ──────────────────────────────────────────────
#  Node lifecycle
# ──────────────────────────────────────────────

# Start the BEAM node (orchestrator auto-starts on TCP :4000)
start: build
    {{dev}} start

# Stop the background BEAM node
stop:
    {{dev}} stop

# Check if the node is running
status:
    {{dev}} status

# Tail the node log
log:
    {{dev}} log

# Run an expression on the live node
rpc *EXPR:
    {{dev}} rpc {{EXPR}}

# ──────────────────────────────────────────────
#  Demo workflow
# ──────────────────────────────────────────────

# Connect the test client (run in a second terminal)
client:
    PORT={{PORT}} elixir test_client.exs

# Connect with ncat — type messages and see VERSION prefix change after upgrade
ncat:
    @echo "Connecting to localhost:{{PORT}} with ncat (type messages, Ctrl-C to quit)…"
    ncat localhost {{PORT}}

# Trigger the hot upgrade v1 → v2
upgrade:
    {{dev}} rpc 'BlueGreen.Orchestrator.upgrade()'

# ──────────────────────────────────────────────
#  Introspection helpers
# ──────────────────────────────────────────────

# Show which OS processes own TCP sockets on this port (one-shot)
lsof:
    @echo "Socket owners on port {{PORT}}:"
    @echo "─────────────────────────────────────────────────────────────"
    @lsof -i TCP:{{PORT}} -n -P +c0 2>/dev/null || echo "(no sockets open)"

# Continuously watch socket ownership (refresh every 0.5s)
watch-sockets:
    watch -n 0.5 "lsof -i TCP:{{PORT}} -n -P +c0 2>/dev/null || echo '(no sockets open)'"

# Show orchestrator state
inspect-orch:
    {{dev}} rpc ':sys.get_state(BlueGreen.Orchestrator)'

# Show handler state on the active peer node
inspect-handler:
    {{dev}} rpc ':erpc.call(Map.get(:sys.get_state(BlueGreen.Orchestrator), :active_node), :sys, :get_state, [BlueGreen.Handler])'

# List connected peer nodes
nodes:
    {{dev}} rpc 'Node.list()'

# ──────────────────────────────────────────────
#  Full automated demo (single terminal)
# ──────────────────────────────────────────────
auto: build
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'just stop 2>/dev/null; kill $(jobs -p) 2>/dev/null' EXIT

    just start
    sleep 1

    echo ""
    echo "📡 Starting test client — upgrade fires in 15 s …"
    echo ""
    elixir test_client.exs &
    CLIENT_PID=$!

    sleep 15
    echo ""
    echo "═══════════════════════════════════════"
    echo "  🔄  TRIGGERING HOT UPGRADE v1 → v2"
    echo "═══════════════════════════════════════"
    just upgrade
    echo "  ✅  Upgrade complete!"
    echo "═══════════════════════════════════════"

    wait $CLIENT_PID 2>/dev/null || true
    just stop

# Show step-by-step instructions
demo:
    @echo ""
    @echo "╔══════════════════════════════════════════════════════════╗"
    @echo "║        Blue/Green Hot Handoff Demo                      ║"
    @echo "╚══════════════════════════════════════════════════════════╝"
    @echo ""
    @echo "  just start           Start node (orchestrator on :${PORT})"
    @echo "  just client          Connect test client  (new terminal)"
    @echo "  just upgrade         Trigger v1 → v2 hot handoff"
    @echo ""
    @echo "  just lsof            Show socket owners on port :${PORT}"
    @echo "  just watch-sockets   Continuously watch socket ownership"
    @echo "  just log             Tail the server log"
    @echo "  just inspect-orch    Show orchestrator state"
    @echo "  just inspect-handler Show handler state on active peer"
    @echo "  just nodes           List connected peer nodes"
    @echo "  just rpc '<expr>'    Evaluate any Elixir on the live node"
    @echo ""
    @echo "  just auto            Run the full demo in one terminal"
    @echo "  just stop            Stop everything"
    @echo ""
