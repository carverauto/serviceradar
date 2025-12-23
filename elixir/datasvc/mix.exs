defmodule Datasvc.MixProject do
  use Mix.Project

  def project do
    [
      app: :datasvc,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir client for ServiceRadar datasvc gRPC service",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.13"}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{}
    ]
  end
end
