defmodule UUID.Mixfile do
  use Mix.Project

  @version "1.2.1"

  def project do
    [
      app: :elixir_uuid,
      name: "UUID",
      version: @version,
      elixir: "~> 1.7",
      compilers: boundary_compilers() ++ Mix.compilers(),
      docs: [extras: ["README.md", "CHANGELOG.md"], main: "readme", source_ref: "v#{@version}"],
      source_url: "https://github.com/zyro/elixir-uuid",
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  # Application configuration.
  def application do
    []
  end

  defp boundary_compilers do
    if Mix.env() in [:dev, :test], do: [:boundary], else: []
  end

  # List of dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.16", only: :dev},
      {:earmark, "~> 1.2", only: :dev},
      {:benchfella, "~> 0.3", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test]},
      {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false}
    ]
  end

  # Description.
  defp description do
    """
    UUID generator and utilities for Elixir.
    """
  end

  # Package info.
  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Andrei Mihu"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/zyro/elixir-uuid"}
    ]
  end
end
