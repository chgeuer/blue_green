#!/usr/bin/env elixir
# Test client for the Blue/Green hot handoff demo.
# Connects to TCP port 4000, sends a message every 2 seconds,
# and prints responses to show the VERSION transition.

defmodule TestClient do
  @default_port 4000

  def run do
    port = port_from_env()
    IO.puts("[Client] Connecting to localhost:#{port}...")

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line]) do
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
        case :gen_tcp.recv(sock, 0, to_timeout(second: 5)) do
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

  defp port_from_env do
    case System.get_env("PORT") do
      nil -> @default_port
      val -> String.to_integer(val)
    end
  end
end

TestClient.run()
