defmodule Datasvc.MixProject do
  use Mix.Project

  def project do
    [
      app: :datasvc,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: boundary_compilers() ++ Mix.compilers(),
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

  defp boundary_compilers do
    if Mix.env() in [:dev, :test], do: [:boundary], else: []
  end

  defp deps do
    [
      {:grpc, "~> 0.9"},
      {:protobuf, "~> 0.16.0", override: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{}
    ]
  end
end
