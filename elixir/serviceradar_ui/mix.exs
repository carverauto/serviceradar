defmodule ServiceRadarUI.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/carverauto/serviceradar/tree/staging/elixir/serviceradar_ui"

  # The package supports LiveView 1.1 and 1.2. `mix.lock` resolves the newest
  # release; set SERVICERADAR_UI_LIVE_VIEW=1.1 to compile and test against the
  # 1.1 line instead. That run keeps its own lockfile, deps and _build so the
  # two never overwrite each other (see `scripts/test_matrix.sh`).
  @live_view_line System.get_env("SERVICERADAR_UI_LIVE_VIEW", "")

  def project do
    [
      app: :serviceradar_ui,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      aliases: aliases()
    ] ++ live_view_line_paths(@live_view_line)
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp live_view_line_paths(""), do: []

  defp live_view_line_paths(line) do
    suffix = "lv" <> String.replace(line, ".", "")

    [
      lockfile: "mix.#{suffix}.lock",
      deps_path: "_matrix/#{suffix}/deps",
      build_path: "_matrix/#{suffix}/_build"
    ]
  end

  defp live_view_requirement(""), do: "~> 1.1"
  defp live_view_requirement(line), do: "~> #{line}.0"

  defp description do
    """
    ServiceRadar's Phoenix design system: sr-* design tokens with light and dark
    themes, function components, shell pieces, server-rendered SVG charts and a
    prebuilt bundle of LiveView hooks (sparkline, time series, offline world map).
    Safe under a strict content security policy.
    """
  end

  defp package do
    [
      maintainers: ["CarverAutomation"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => @source_url,
        "Changelog" => @source_url <> "/CHANGELOG.md"
      },
      # Hex publish uploads these files (relative to the project root). The
      # hook sources under assets/ are not shipped; priv/static holds the
      # prebuilt bundle and its source map.
      files:
        ~w(lib priv/css priv/static mix.exs README.md CHANGELOG.md LICENSE NOTICE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "serviceradar_ui-v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, live_view_requirement(@live_view_line)},
      {:phoenix_html, "~> 4.1"},
      {:jason, "~> 1.4"},
      # Dev / test tooling.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
