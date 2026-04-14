defmodule ServiceRadarSRQL.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :serviceradar_srql,
      version: @version,
      elixir: "~> 1.15",
      compilers: boundary_compilers() ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp boundary_compilers do
    [:boundary]
  end

  defp deps do
    [
      # Rust NIF binding
      {:rustler, "~> 0.36"},

      # JSON parsing
      {:jason, "~> 1.2"},
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

  defp description do
    """
    SRQL (ServiceRadar Query Language) shared library.
    Provides Rust NIF bindings for SRQL parsing and an Ash adapter for query execution.
    """
  end
end
