defmodule BlueGreen.MixProject do
  use Mix.Project

  def project do
    [
      app: :blue_green,
      version: "0.1.0",
      elixir: "~> 1.20-rc",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {BlueGreen.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.37.3"},
      {:thousand_island, "~> 1.0"}
    ]
  end
end
