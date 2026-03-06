defmodule BlueGreen.SocketHandoff do
  @moduledoc """
  NIF wrapper for SCM_RIGHTS file descriptor passing over Unix Domain Sockets.
  """
  use Rustler, otp_app: :blue_green, crate: "socket_handoff"

  @doc "Send a file descriptor over UDS at `path` using SCM_RIGHTS."
  @spec send_fd(String.t(), integer()) :: :ok | no_return()
  def send_fd(_path, _fd), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Receive a file descriptor from UDS at `path` using SCM_RIGHTS. Blocks until a sender connects."
  @spec recv_fd(String.t()) :: {:ok, integer()} | no_return()
  def recv_fd(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Release the caller's reference to a socket FD after handoff.

  Uses dup2() to replace the FD with /dev/null, decrementing the kernel
  socket's refcount without calling shutdown() (which would send TCP FIN).
  """
  @spec release_fd(integer()) :: :ok | no_return()
  def release_fd(_fd), do: :erlang.nif_error(:nif_not_loaded)
end
