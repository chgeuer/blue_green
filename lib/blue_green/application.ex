defmodule BlueGreen.Application do
  @moduledoc false
  use Application

  @default_port 4000

  @impl true
  def start(_type, _args) do
    tcp_port = port_from_env()

    children = [
      BlueGreen.Orchestrator,
      {ThousandIsland,
        port: tcp_port,
        handler_module: BlueGreen.ConnectionDispatcher,
        transport_options: [reuseaddr: true]}
    ]

    opts = [strategy: :one_for_one, name: BlueGreen.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port_from_env do
    case System.get_env("PORT") do
      nil -> @default_port
      val -> String.to_integer(val)
    end
  end
end
