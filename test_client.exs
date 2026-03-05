#!/usr/bin/env elixir
# Test client for the Blue/Green hot handoff demo.
# Connects to TCP port 4000, sends a message every 2 seconds,
# and prints responses to show the VERSION transition.

defmodule TestClient do
  def run do
    IO.puts("[Client] Connecting to localhost:4000...")

    case :gen_tcp.connect({127, 0, 0, 1}, 4000, [:binary, active: false, packet: :line]) do
      {:ok, sock} ->
        IO.puts("[Client] Connected!")
        loop(sock, 1)

      {:error, reason} ->
        IO.puts("[Client] Connection failed: #{inspect(reason)}")
    end
  end

  defp loop(_sock, n) when n > 30 do
    IO.puts("[Client] Done after 30 messages.")
  end

  defp loop(sock, n) do
    msg = "ping #{n}\n"
    case :gen_tcp.send(sock, msg) do
      :ok ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} ->
            IO.puts("[Client] ##{n} -> #{String.trim(data)}")
            Process.sleep(2_000)
            loop(sock, n + 1)

          {:error, reason} ->
            IO.puts("[Client] Recv error: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("[Client] Send error: #{inspect(reason)}")
    end
  end
end

TestClient.run()
