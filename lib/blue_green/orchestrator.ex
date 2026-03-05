defmodule BlueGreen.Orchestrator do
  @moduledoc """
  Manages the TCP listener and coordinates blue/green deployments
  using :peer nodes and SCM_RIGHTS FD passing.

  The listen port is read from the `PORT` environment variable,
  falling back to 4000 when unset.

  ## Usage

      iex> BlueGreen.Orchestrator.start_link()
      iex> BlueGreen.Orchestrator.upgrade()
  """
  use GenServer
  require Logger

  @default_port 4000

  defstruct [
    :listen_socket,
    :active_peer,
    :active_node,
    :active_version
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger a hot upgrade from current version to next version."
  def upgrade do
    GenServer.call(__MODULE__, :upgrade, 30_000)
  end

  @impl true
  def init(_opts) do
    tcp_port = port_from_env()

    {:ok, lsock} = :gen_tcp.listen(tcp_port, [
      :binary,
      active: false,
      reuseaddr: true,
      packet: :line
    ])
    Logger.info("[Orchestrator] Listening on TCP port #{tcp_port}")

    # Start v1 peer node (no receiver yet — waits for a client)
    {peer, node} = start_peer_node(1)
    Logger.info("[Orchestrator] Started v1 on #{node}")

    state = %__MODULE__{
      listen_socket: lsock,
      active_peer: peer,
      active_node: node,
      active_version: 1
    }

    # Start the acceptor loop
    send(self(), :accept)

    {:ok, state}
  end

  @impl true
  def handle_info(:accept, state) do
    me = self()
    spawn_link(fn ->
      case :gen_tcp.accept(state.listen_socket) do
        {:ok, client_socket} ->
          :gen_tcp.controlling_process(client_socket, me)
          send(me, {:new_client, client_socket})
        {:error, :closed} ->
          :ok
        {:error, reason} ->
          Logger.error("[Orchestrator] Accept error: #{inspect(reason)}")
      end
    end)
    {:noreply, state}
  end

  def handle_info({:new_client, client_socket}, state) do
    {:ok, fd} = BlueGreen.FdUtil.extract_fd(client_socket)
    Logger.info("[Orchestrator] Client connected, FD=#{fd}, passing to v#{state.active_version}")

    uds_path = uds_path_for(state.active_version)

    # Start receiver on the peer, then send FD
    start_receiver_on_peer(state.active_node, state.active_version, uds_path)
    Process.sleep(200)
    :ok = BlueGreen.SocketHandoff.send_fd(uds_path, fd)
    Logger.info("[Orchestrator] Sent FD #{fd} to v#{state.active_version}")

    # Don't close the gen_tcp socket — gen_tcp.close calls shutdown() which
    # would kill the TCP connection at the protocol level. We leak the port
    # intentionally; the peer owns the connection via its SCM_RIGHTS-dup'd FD.

    # Accept next client
    send(self(), :accept)

    {:noreply, state}
  end

  @impl true
  def handle_call(:upgrade, _from, %{active_version: v} = state) do
    new_version = v + 1
    new_uds_path = uds_path_for(new_version)
    Logger.info("[Orchestrator] Upgrading v#{v} -> v#{new_version}")

    # 1. Start new peer node
    {new_peer, new_node} = start_peer_node(new_version)
    Logger.info("[Orchestrator] Started v#{new_version} on #{new_node}")

    # 2. Start receiver on new node (blocks in spawned process until FD arrives)
    start_receiver_on_peer(new_node, new_version, new_uds_path)
    Process.sleep(200)

    # 3. Tell old handler to hand off its socket to new node's UDS
    Logger.info("[Orchestrator] Telling v#{v} to hand off to #{new_uds_path}")
    :erpc.call(state.active_node, BlueGreen.Handler, :handoff, [new_uds_path])

    # 4. Stop old peer
    Process.sleep(500)
    :peer.stop(state.active_peer)
    Logger.info("[Orchestrator] Stopped v#{v} peer")

    {:reply, :ok, %{state |
      active_peer: new_peer,
      active_node: new_node,
      active_version: new_version
    }}
  end

  # --- Private helpers ---

  defp start_peer_node(version) do
    code_paths = :code.get_path()
    pa_args = Enum.flat_map(code_paths, fn p -> [~c"-pa", p] end)
    cookie_args = [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]

    {:ok, peer, node} = :peer.start(%{
      name: String.to_atom("v#{version}"),
      args: pa_args ++ cookie_args,
      connection: :standard_io
    })

    {peer, node}
  end

  defp start_receiver_on_peer(node, version, uds_path) do
    :erpc.call(node, fn ->
      spawn(fn ->
        Logger.info("[Peer v#{version}] Waiting for FD on #{uds_path}")
        {:ok, fd} = BlueGreen.SocketHandoff.recv_fd(uds_path)
        Logger.info("[Peer v#{version}] Received FD #{fd}")
        BlueGreen.Handler.start_link(fd: fd, version: version, uds_path: uds_path)
      end)
    end)
  end

  defp uds_path_for(version) do
    "/tmp/blue_green_v#{version}_#{System.pid()}.sock"
  end

  defp port_from_env do
    case System.get_env("PORT") do
      nil -> @default_port
      val -> String.to_integer(val)
    end
  end
end
