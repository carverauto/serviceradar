defmodule ServiceRadarCoreElx.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :serviceradar_core_elx,
      version: @version,
      elixir: "~> 1.17",
      compilers: boundary_compilers() ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_add_apps: [:mix]],
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
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
      extra_applications: [:logger, :ssl, :crypto, :public_key],
      mod: {ServiceRadarCoreElx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp boundary_compilers do
    if Mix.env() in [:dev, :test], do: [:boundary], else: []
  end

  defp deps do
    [
      # ServiceRadar Core - shared domains, repo, cluster, registry
      {:serviceradar_core, path: "../serviceradar_core"},
      # Ratio 4.0.1 still advertises Decimal 2.x even though its Decimal integration
      # remains API-compatible. Force the patched Decimal line and the Numbers release
      # that officially supports it so Ash/Ecto can resolve their secured versions.
      {:decimal, "~> 3.1", override: true},
      {:numbers, "~> 5.2.5", override: true},
      # ex_hls through 0.2.5 advertises Req 0.5.x but only calls the compatible
      # Req.get!/1 API. Force the release containing the decompression limits.
      #
      # Held at the same version as web-ng: serviceradar_core is a path dep of
      # both, so a split here means core's code runs against a Req it was never
      # compiled or tested against, and `finch: [name: ...]` (0.7+) silently
      # becomes an invalid pool name under 0.6.
      {:req, "~> 0.7", override: true},

      # Distributed cluster
      {:libcluster, "~> 3.4"},

      # Minimal gRPC footprint for sync/checker coordination
      {:grpc, "~> 1.0"},
      # grpc 1.0 made transport adapters optional and pins the default Gun
      # adapter to `~> 2.2.0`. Keep the CVE-patched gun 2.4.1 (Phase-1) and force
      # it via override so the default Gun client adapter stays available.
      {:gun, "~> 2.4", override: true},
      # hackney is intentionally absent. Its only consumer was boombox's generic HTTP
      # media-file source (membrane_hackney_plugin), which the vendored boombox no longer
      # pulls. hackney 4.x (the SSRF-patched line, GHSA-pj7v-xfvx-wmjq) dragged in `h2`,
      # whose h2_* modules collide with grpcbox's chatterbox and break `mix release`;
      # dropping hackney removes that collision AND the SSRF lineage entirely. Do not
      # re-add hackney without resolving the h2/chatterbox module clash.
      {:swoosh, "~> 1.26", override: true},
      {:membrane_core, "1.2.6"},
      {:membrane_webrtc_plugin, "~> 0.26.3"},
      # Keep transitive MPEG-TS deps on Elixir 1.19-compatible releases without
      # patching vendored Boombox or upstream Hex packages. Boombox still needs
      # SRT on its compatible 0.1.x line.
      {:membrane_mpeg_ts_plugin, "~> 2.4", override: true},
      {:mpeg_ts, "~> 3.3", override: true},
      {:boombox, path: "../../third_party/hex_vendored/boombox"},
      {:bandit, "~> 1.10"},
      {:plug, "~> 1.18"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:bundlex, github: "membraneframework/bundlex", tag: "v1.5.4", override: true},
      {:elixir_uuid, "~> 1.2", override: true},
      {:protobuf, "~> 0.16.0", override: true},
      # credo must NOT carry an :only restriction here: membrane_opus_format
      # 0.3.1 (transitive via the vendored boombox) ships credo as a hard,
      # all-envs dependency (upstream packaging bug), and Mix fails prod
      # deps.get with an :only divergence when our entry is dev/test-only —
      # which broke the core_elx release build. runtime: false keeps credo
      # out of the assembled release either way.
      {:credo, "~> 1.7", runtime: false},
      {:ash_credo, "~> 0.7", only: [:dev, :test], runtime: false},
      {:boundary, "~> 0.10.4", runtime: false},
      {:ex_dna, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end

  defp releases do
    [
      serviceradar_core_elx: [
        include_executables_for: [:unix],
        include_erts: &shipped_erts/0,
        # Avoid boot abort when optional deps (e.g. lazy_html via phoenix_live_view)
        # bake compile-time env that is unset in some runtime paths.
        validate_compile_env: false,
        applications: [
          runtime_tools: :permanent,
          serviceradar_core: :permanent,
          serviceradar_core_elx: :permanent
        ],
        steps: [:assemble],
        rel_templates_path: "rel"
      ]
    ]
  end

  # Which ERTS the release embeds. `true` -- the default, and what every amd64 build gets --
  # copies ERTS and the OTP applications from the VM running `mix release`, which is wrong
  # the moment the build host and the target differ in architecture. Mix also accepts a path
  # and resolves the OTP applications relative to it, so naming the erts-* directory of a
  # second OTP root redirects VM and NIFs together. //build:elixir_release.bzl sets this
  # variable when it stages such a tree; unset, this is the previous behaviour exactly.
  #
  # Note this alone does not make an arm64 core-elx image possible: the Membrane precompiled
  # archives this release depends on are published for linux_x86 only.
  defp shipped_erts do
    System.get_env("SERVICERADAR_RELEASE_ERTS") || true
  end
end
