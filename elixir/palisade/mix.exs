defmodule Palisade.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/carverauto/serviceradar/tree/staging/elixir/palisade"

  def project do
    [
      app: :palisade,
      version: @version,
      # ~> 1.15 keeps the door open for CRM (1.19) and ServiceRadar
      # (also recent) to both consume without version-pinning churn.
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      aliases: aliases()
    ]
  end

  def application do
    # No application callback. The processes palisade provides
    # (Palisade.RateLimit.ETS, Palisade.ConnectionLimiter) are started
    # by the consumer from its own supervision tree via child_spec/1.
    [extra_applications: [:logger]]
  end

  defp description do
    """
    Trust-boundary primitives for Elixir web services: SSRF-safe
    outbound URL policy and fetch, plus plugs for security headers,
    trusted-proxy client IP, rate limiting, connection caps and
    malformed-request rejection.
    """
  end

  defp package do
    [
      maintainers: ["CarverAutomation"],
      licenses: ["Apache-2.0"],
      links: %{"Source" => @source_url},
      # Hex publish uploads these files (relative to the project
      # root). Excluded by default: _build, deps, .git, etc.
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp deps do
    [
      # HTTP client for OutboundFetch. Both CRM and ServiceRadar
      # already pull Req in transitively; pinning here so palisade
      # builds standalone.
      {:req, "~> 0.6"},
      # Plug behaviour and Plug.Conn for the web-edge plugs.
      {:plug, "~> 1.14"},
      # Dev / test tooling.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "format",
        "credo",
        "test"
      ]
    ]
  end
end
