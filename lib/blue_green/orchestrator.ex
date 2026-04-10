defmodule BlueGreen.Orchestrator do
  @moduledoc """
  Coordinates blue/green deployments using :peer nodes and SCM_RIGHTS
  FD passing. TCP acceptance is handled by ThousandIsland via
  `BlueGreen.ConnectionDispatcher`.

  ## Usage

      iex> BlueGreen.Orchestrator.start_link()
      iex> BlueGreen.Orchestrator.upgrade()
  """
  use GenServer
  require Logger

  @type t() :: %__MODULE__{
          active_peer: pid(),
          active_node: node(),
          active_version: pos_integer(),
          active_handlers: MapSet.t(pid())
        }

  defstruct [
    :active_peer,
    :active_node,
    :active_version,
    active_handlers: MapSet.new()
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger a hot upgrade from current version to next version."
  @spec upgrade() :: :ok
  def upgrade do
    GenServer.call(__MODULE__, :upgrade, 30_000)
  end

  @doc "Hand off a client socket FD to the active peer node."
  @spec register_client(non_neg_integer()) :: :ok
  def register_client(fd) do
    GenServer.call(__MODULE__, {:register_client, fd}, 10_000)
  end

  @impl true
  def init(_opts) do
    {peer, node} = start_peer_node(1)
    Logger.info("[Orchestrator] Started v1 on #{node}")

    state = %__MODULE__{
      active_peer: peer,
      active_node: node,
      active_version: 1
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register_client, fd}, _from, state) do
    Logger.info("[Orchestrator] Registering client FD=#{fd} with v#{state.active_version}")

    uds_path = unique_uds_path(state.active_version)
    ref = start_receiver_on_peer(state.active_node, state.active_version, uds_path)
    Process.sleep(200)
    :ok = BlueGreen.SocketHandoff.send_fd(uds_path, fd)

    handler_pid = receive do
      {^ref, {:handler_started, pid}} -> pid
    after
      5_000 -> raise "Handler failed to start on peer"
    end

    Process.monitor(handler_pid)
    Logger.info("[Orchestrator] Handler #{inspect(handler_pid)} tracking for v#{state.active_version}")

    {:reply, :ok, %{state | active_handlers: MapSet.put(state.active_handlers, handler_pid)}}
  end

  @impl true
  def handle_call(:upgrade, _from, %{active_version: v} = state) do
    new_version = v + 1
    Logger.info("[Orchestrator] Upgrading v#{v} -> v#{new_version}")

    # 1. Start new peer node
    {new_peer, new_node} = start_peer_node(new_version)
    Logger.info("[Orchestrator] Started v#{new_version} on #{new_node}")

    # 2. Hand off each active handler to the new peer
    new_handlers =
      state.active_handlers
      |> Enum.map(fn old_handler_pid ->
        new_uds_path = unique_uds_path(new_version)

        ref = start_receiver_on_peer(new_node, new_version, new_uds_path)
        Process.sleep(200)

        Logger.info("[Orchestrator] Telling #{inspect(old_handler_pid)} to hand off to #{new_uds_path}")
        BlueGreen.Handler.handoff(old_handler_pid, new_uds_path)

        receive do
          {^ref, {:handler_started, pid}} -> pid
        after
          5_000 -> raise "New handler failed to start during upgrade"
        end
      end)
      |> MapSet.new()

    Enum.each(new_handlers, &Process.monitor/1)

    # 3. Stop old peer
    Process.sleep(500)
    :peer.stop(state.active_peer)
    Logger.info("[Orchestrator] Stopped v#{v} peer")

    {:reply, :ok, %{state |
      active_peer: new_peer,
      active_node: new_node,
      active_version: new_version,
      active_handlers: new_handlers
    }}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | active_handlers: MapSet.delete(state.active_handlers, pid)}}
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
    ref = make_ref()
    caller = self()

    :erpc.call(node, fn ->
      spawn(fn ->
        Logger.info("[Peer v#{version}] Waiting for FD on #{uds_path}")
        {:ok, fd} = BlueGreen.SocketHandoff.recv_fd(uds_path)
        Logger.info("[Peer v#{version}] Received FD #{fd}")
        {:ok, pid} = BlueGreen.Handler.start_link(fd: fd, version: version, uds_path: uds_path)
        send(caller, {ref, {:handler_started, pid}})
      end)
    end)

    ref
  end

  defp unique_uds_path(version) do
    id = System.unique_integer([:positive])
    "/tmp/blue_green_v#{version}_#{System.pid()}_#{id}.sock"
  end
end
