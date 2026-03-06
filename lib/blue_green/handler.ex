defmodule BlueGreen.Handler do
  @moduledoc """
  GenServer that owns a TCP socket (from a raw FD) and echoes data back
  with a version prefix. Uses non-blocking :socket.recv with select to
  remain responsive to handoff calls.
  """
  use GenServer
  require Logger

  defstruct [:socket, :fd, :version, :uds_path]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Tell this handler to hand off its socket to the receiver at `target_uds_path`."
  def handoff(target_uds_path) do
    GenServer.call(__MODULE__, {:handoff, target_uds_path}, 10_000)
  end

  @impl true
  def init(opts) do
    fd = Keyword.fetch!(opts, :fd)
    version = Keyword.fetch!(opts, :version)
    uds_path = Keyword.fetch!(opts, :uds_path)

    {:ok, socket} = BlueGreen.FdUtil.wrap_fd(fd)
    Logger.info("[Handler v#{version}] Adopted FD #{fd}, serving")

    state = %__MODULE__{socket: socket, fd: fd, version: version, uds_path: uds_path}

    # Kick off non-blocking recv
    request_recv(socket)
    {:ok, state}
  end

  # Select notification: socket has data ready
  @impl true
  def handle_info({:"$socket", socket, :select, _ref}, %{socket: socket} = state) do
    case :socket.recv(socket, 0, :nowait) do
      {:ok, data} ->
        reply = "VERSION #{state.version}: #{String.trim(data)}\n"
        :socket.send(state.socket, reply)
        request_recv(socket)
        {:noreply, state}

      {:select, _select_info} ->
        # Will get another select message when ready
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Handler v#{state.version}] recv error: #{inspect(reason)}")
        cleanup_fd(state)
        {:stop, :normal, %{state | socket: nil}}
    end
  end

  def handle_info({:"$socket", _socket, :abort, _info}, state) do
    Logger.warning("[Handler v#{state.version}] socket aborted")
    cleanup_fd(state)
    {:stop, :normal, %{state | socket: nil}}
  end

  def handle_info({:immediate_data, data}, state) do
    reply = "VERSION #{state.version}: #{String.trim(data)}\n"
    :socket.send(state.socket, reply)
    request_recv(state.socket)
    {:noreply, state}
  end

  def handle_info({:recv_error, reason}, state) do
    Logger.warning("[Handler v#{state.version}] recv error: #{inspect(reason)}")
    cleanup_fd(state)
    {:stop, :normal, %{state | socket: nil}}
  end

  @impl true
  def handle_call({:handoff, target_uds_path}, _from, state) do
    Logger.info("[Handler v#{state.version}] Handing off socket to #{target_uds_path}")

    :ok = BlueGreen.SocketHandoff.send_fd(target_uds_path, state.fd)

    # Release our FD — dup2 to /dev/null so shutdown() isn't called.
    # The peer is stopped shortly after, but this is still cleaner than
    # leaking the FD until peer termination.
    :ok = BlueGreen.SocketHandoff.release_fd(state.fd)
    Logger.info("[Handler v#{state.version}] Released FD #{state.fd}")

    {:stop, :normal, :ok, %{state | socket: nil}}
  end

  @impl true
  def terminate(_reason, %{socket: nil}), do: :ok

  def terminate(_reason, %{socket: _socket} = state) do
    cleanup_fd(state)
  end

  # Release the underlying FD directly via dup2(/dev/null).
  # We can't rely on :socket.close here — when :socket.recv returns
  # {:error, :closed}, the NIF marks the socket as closed internally,
  # making the subsequent :socket.close a no-op that never calls close()
  # on the actual FD. This leaves the socket stuck in CLOSE_WAIT.
  defp cleanup_fd(%{fd: fd, version: version}) do
    BlueGreen.SocketHandoff.release_fd(fd)
    Logger.info("[Handler v#{version}] Released FD #{fd}")
  end

  defp request_recv(socket) do
    case :socket.recv(socket, 0, :nowait) do
      {:ok, data} ->
        # Data was immediately available, process it
        send(self(), {:immediate_data, data})

      {:select, _select_info} ->
        # Will get a select message when data arrives
        :ok

      {:error, reason} ->
        send(self(), {:recv_error, reason})
    end
  end
end
