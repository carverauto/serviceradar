defmodule Connection.Mixfile do
  use Mix.Project

  @version "1.1.0"

  def project do
    [
      app: :connection,
      version: @version,
      elixir: "~> 1.7",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    []
  end

  defp deps() do
    [
      {:ex_doc, "~> 0.22", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test]}
    ]
  end

  defp docs do
    [
      source_url: "https://github.com/elixir-ecto/connection",
      source_ref: "v#{@version}",
      main: Connection
    ]
  end

  defp description do
    """
    Connection behaviour for connection processes
    """
  end

  defp package do
    %{
      licenses: ["Apache 2.0"],
      links: %{"Github" => "https://github.com/elixir-ecto/connection"}
    }
  end
end
