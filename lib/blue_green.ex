defmodule BlueGreen do
  @moduledoc """
  Hot blue/green deployment for TCP services using BEAM peer nodes
  and SCM_RIGHTS file descriptor passing.

  A parent (shim) VM runs the `BlueGreen.Orchestrator`, which accepts TCP
  connections and forwards them to a peer node running `BlueGreen.Handler`.
  On upgrade, a new peer is booted, the live socket is handed off via
  Unix domain socket, and the old peer is stopped — all without dropping
  the client's TCP connection.

  See `BlueGreen.Orchestrator` for the main entry point.
  """
end
