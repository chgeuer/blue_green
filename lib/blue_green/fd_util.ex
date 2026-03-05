defmodule BlueGreen.FdUtil do
  @moduledoc """
  Helpers for extracting raw FDs from gen_tcp sockets and wrapping raw FDs
  back into Erlang `:socket` references.
  """

  @doc "Extract the raw OS file descriptor from a gen_tcp (port-based) socket."
  @spec extract_fd(:gen_tcp.socket()) :: {:ok, integer()} | {:error, term()}
  def extract_fd(tcp_socket) do
    :prim_inet.getfd(tcp_socket)
  end

  @doc "Wrap a raw OS file descriptor into an Erlang `:socket.t()` for TCP."
  @spec wrap_fd(integer()) :: {:ok, :socket.socket()} | {:error, term()}
  def wrap_fd(fd) when is_integer(fd) do
    :socket.open(fd, %{domain: :inet, type: :stream, protocol: :tcp, dup: false})
  end
end
