#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="${DEV_NODE_NAME:-$(basename "$PROJECT_DIR")}"
COOKIE="${DEV_NODE_COOKIE:-devcookie}"
HOSTNAME="$(hostname -s)"
FQDN="${APP_NAME}@${HOSTNAME}"
PIDFILE="${PROJECT_DIR}/.dev_node.pid"
LOGFILE="${PROJECT_DIR}/.dev_node.log"

case "${1:-help}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "Node already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    echo "Starting node ${FQDN} ..."
    cd "$PROJECT_DIR"
    elixir --sname "$APP_NAME" --cookie "$COOKIE" -S mix run --no-halt > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    for i in $(seq 1 30); do
      if elixir --sname "probe_$$" --cookie "$COOKIE" -e "
        Node.connect(:\"${FQDN}\") |> IO.inspect()
      " 2>/dev/null | grep -q "true"; then
        echo "Node ${FQDN} is up (pid $(cat "$PIDFILE"))"
        exit 0
      fi
      sleep 1
    done
    echo "ERROR: Node did not become reachable within 30s. Check $LOGFILE"
    exit 1
    ;;

  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null && echo "Node stopped" || echo "Node was not running"
      rm -f "$PIDFILE"
    else
      echo "No pidfile found"
    fi
    ;;

  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "Node running (pid $(cat "$PIDFILE"))"
    else
      echo "Node not running"
      rm -f "$PIDFILE" 2>/dev/null
    fi
    ;;

  rpc)
    shift
    EXPR="$*"
    elixir --sname "rpc_$$" --cookie "$COOKIE" --no-halt -e "
      target = :\"${FQDN}\"
      true = Node.connect(target)
      {result, _binding} = :rpc.call(target, Code, :eval_string, [\"\"\"
        ${EXPR}
      \"\"\"])
      IO.inspect(result, pretty: true, limit: 200, printable_limit: 4096)
      System.halt(0)
    "
    ;;

  eval_file)
    shift
    FILE="$1"
    elixir --sname "rpc_$$" --cookie "$COOKIE" --no-halt -e "
      target = :\"${FQDN}\"
      true = Node.connect(target)
      code = File.read!(\"${FILE}\")
      {result, _binding} = :rpc.call(target, Code, :eval_string, [code])
      IO.inspect(result, pretty: true, limit: 200, printable_limit: 4096)
      System.halt(0)
    "
    ;;

  log)
    tail -f "$LOGFILE"
    ;;

  help|*)
    echo "Usage: scripts/dev_node.sh {start|stop|status|rpc <expr>|eval_file <path>|log}"
    echo ""
    echo "Environment variables:"
    echo "  DEV_NODE_NAME   - sname for the node (default: project directory name)"
    echo "  DEV_NODE_COOKIE - cluster cookie (default: devcookie)"
    ;;
esac
