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
      package: package(),
      # Keep Hex's advisory gate aligned with the documented, temporary
      # exceptions in .deps_audit_ignore. See that file for mitigations and
      # removal criteria for each advisory.
      hex: [
        ignore_advisories: [
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969",
          "EEF-CVE-2026-43971",
          "GHSA-g2wm-735q-3f56",
          "GHSA-w4f7-4cxr-rv3c"
        ]
      ]
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
      {:grpc, "~> 1.0"},
      # grpc 1.0 makes its transport adapters optional and pins the default Gun
      # adapter to `~> 2.2.0`. Keep the CVE-patched gun 2.4.1 (Phase-1) and force
      # it via override so the default Gun client adapter stays available.
      {:gun, "~> 2.4", override: true},
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
