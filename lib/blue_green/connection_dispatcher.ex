defmodule BlueGreen.ConnectionDispatcher do
  @moduledoc """
  ThousandIsland handler that accepts TCP connections and dispatches
  them to the active peer node via the Orchestrator.

  Each accepted connection's raw file descriptor is extracted and handed
  off to a peer node via SCM_RIGHTS. The ThousandIsland handler then
  releases its FD reference and closes — the peer owns the connection.
  """
  use ThousandIsland.Handler
  require Logger

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    # Access the underlying :gen_tcp socket from the ThousandIsland.Socket struct
    {:ok, fd} = BlueGreen.FdUtil.extract_fd(socket.socket)
    Logger.info("[Dispatcher] New client FD=#{fd}, handing off to active peer")

    :ok = BlueGreen.Orchestrator.register_client(fd)

    # dup2 to /dev/null so ThousandIsland's close() doesn't send TCP FIN
    :ok = BlueGreen.SocketHandoff.release_fd(fd)

    {:close, %{}}
  end
end
