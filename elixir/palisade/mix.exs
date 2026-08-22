defmodule Palisade.MixProject do
  use Mix.Project

  @version "0.1.0"
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
    # No supervision tree in v0.1 — everything's pure / per-call.
    # OIDC discovery + JWKS caching will need a GenServer-owned ETS
    # in a later version; we'll add an `Application` module then.
    [extra_applications: [:logger]]
  end

  defp description do
    """
    Shared trust-boundary primitives for CarverAutomation services
    (currently CRM + ServiceRadar). Outbound URL / network address
    policy (SSRF defense), HTTP fetch with resolved-IP binding to
    defeat DNS rebinding, and — in later versions — OIDC + SAML
    primitives needed to make federated identity safe.
    """
  end

  defp package do
    [
      maintainers: ["CarverAutomation"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => "https://github.com/carverauto/serviceradar/tree/staging/elixir/palisade"
      },
      # Hex publish uploads these files (relative to the project
      # root). Excluded by default: _build, deps, .git, etc.
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp deps do
    [
      # HTTP client for OutboundFetch. Both CRM and ServiceRadar
      # already pull Req in transitively; pinning here so palisade
      # builds standalone.
      {:req, "~> 0.6"},
      # Dev / test tooling.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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
