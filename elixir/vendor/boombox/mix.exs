defmodule Boombox.Mixfile do
  use Mix.Project

  @version "0.2.10"
  @github_url "https://github.com/membraneframework/boombox"

  def project do
    [
      app: :boombox,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      releases: releases(),
      aliases: aliases(),

      # hex
      description: "Boombox",
      package: package(),

      # docs
      name: "Boombox",
      source_url: @github_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [],
      mod:
        if burrito?() do
          {Boombox.Utils.BurritoApp, []}
        else
          {Boombox.Application, []}
        end
    ]
  end

  defp burrito?, do: System.get_env("BOOMBOX_BURRITO") != nil

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 1.2"},
      {:membrane_transcoder_plugin, "~> 0.3.2"},
      {:membrane_webrtc_plugin, "~> 0.26.1"},
      {:membrane_mp4_plugin, "~> 0.36.0"},
      {:membrane_realtimer_plugin, "~> 0.9.0"},
      {:membrane_http_adaptive_stream_plugin, "~> 0.20.2"},
      {:membrane_rtmp_plugin, "~> 0.29.1"},
      {:membrane_rtsp_plugin, "~> 0.7.0"},
      {:membrane_rtp_plugin, "~> 0.31.1"},
      {:membrane_rtp_format, "~> 0.11.0"},
      {:membrane_rtp_aac_plugin, "~> 0.9.0"},
      {:membrane_rtp_h264_plugin, "~> 0.20.0"},
      {:membrane_rtp_opus_plugin, "~> 0.10.0"},
      {:membrane_rtp_h265_plugin, "~> 0.5.2"},
      {:membrane_vpx_plugin, "~> 0.4.2"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20.0"},
      {:membrane_hackney_plugin, "~> 0.11.0"},
      {:membrane_ffmpeg_swscale_plugin, "~> 0.16.2"},
      {:membrane_wav_plugin, "~> 0.10.1"},
      {:membrane_ivf_plugin, "~> 0.8.0"},
      {:membrane_ogg_plugin, "~> 0.5.0"},
      {:membrane_stream_plugin, "~> 0.4.0"},
      {:membrane_srt_plugin, "~> 0.1.1"},
      {:membrane_simple_rtsp_server, "~> 0.1.5", only: :test},
      {:image, "~> 0.54.0"},
      {:async_test, github: "software-mansion-labs/elixir_async_test", only: :test},
      {:playwright, "~> 1.49.1-alpha.2", only: :test},
      {:cowlib, "~> 2.16", override: true, only: :test},
      {:burrito, "~> 1.0", runtime: burrito?(), optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membrane.stream"
      },
      files: ["lib", "mix.exs", "README*", "LICENSE*", ".formatter.exs", "bin/boombox"]
    ]
  end

  defp aliases do
    [docs: [&generate_docs_examples/1, "docs"]]
  end

  defp generate_docs_examples(_) do
    docs_install_config = "boombox = :boombox"

    modified_livebook =
      "examples.livemd"
      |> File.read!()
      |> String.replace(
        ~r/# MIX_INSTALL_CONFIG_BEGIN\n(.|\n)*# MIX_INSTALL_CONFIG_END\n/U,
        docs_install_config,
        global: false
      )

    File.write!("#{Mix.Project.build_path()}/examples.livemd", modified_livebook)
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        {"#{Mix.Project.build_path()}/examples.livemd", title: "Examples"},
        {"LICENSE", title: "License"}
      ],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Boombox]
    ]
  end

  defp releases do
    {burrito_wrap, burrito_config} =
      if burrito?() do
        {&Burrito.wrap/1, burrito_config()}
      else
        {& &1, []}
      end

    [
      boombox:
        [
          steps: [:assemble, &restore_symlinks/1, burrito_wrap]
        ] ++ burrito_config,
      server: [
        steps: [:assemble, &restore_symlinks/1]
      ]
    ]
  end

  defp burrito_config do
    current_os =
      case :os.type() do
        {:win32, _} -> :windows
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
      end

    arch_string =
      :system_architecture
      |> :erlang.system_info()
      |> to_string()
      |> String.downcase()
      |> String.split("-")
      |> List.first()

    current_cpu =
      case arch_string do
        "x86_64" -> :x86_64
        "arm64" -> :aarch64
        "aarch64" -> :aarch64
        _ -> :unknown
      end

    [
      burrito: [
        targets: [
          current: [os: current_os, cpu: current_cpu]
        ]
      ]
    ]
  end

  # mix release doesn't preserve symlinks, but replaces
  # them with whatever they point to, while
  # bundlex uses symlinks to provide precompiled deps.
  # That makes the release size enormous, so this workaroud
  # recreates the symlinks by replacing the copied data
  # with new symlinks pointing to bundlex's
  # priv/shared/precompiled directory
  defp restore_symlinks(release) do
    base_dir =
      Path.join([
        __DIR__,
        "_build",
        Atom.to_string(Mix.env()),
        "rel",
        Atom.to_string(release.name),
        "lib"
      ])

    shared =
      base_dir
      |> Path.join("bundlex*/priv/shared/precompiled/*")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, base_dir))
      |> Map.new(&{Path.basename(&1), &1})

    # Restore symlinks
    # <package>/priv/shared/precompiled/<precompiled_dir> -> ../../../../bundlex-<version>/priv/shared/<precompiled_dir>/lib
    base_dir
    |> Path.join("*/priv/bundlex/*/*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      name = Path.basename(path)

      if Map.has_key?(shared, name) do
        ln =
          [base_dir, shared[name], "lib"]
          |> Path.join()
          |> Path.relative_to(Path.dirname(path), force: true)

        File.rm_rf!(path)
        File.ln_s!(ln, path)
      end
    end)

    # Restore symlinks
    # bundlex-<version>/priv/shared/precompiled/<precompiled_dir>/lib/<some_lib>.dylib -> <some_lib>.<most_precise_version>.dylib
    # e.g. libvpx.dylib -> libvpx.11.dylib
    base_dir
    |> Path.join("bundlex*/priv/shared/precompiled/*/lib")
    |> Path.wildcard()
    |> Enum.map(fn lib_dir ->
      lib_dir
      |> File.ls!()
      |> Enum.group_by(&(&1 |> String.split(".") |> List.first()))
      |> Enum.each(fn {_lib_name, libs} ->
        lib_to_symlink_to =
          Enum.max_by(libs, &String.length/1)

        libs
        |> Enum.filter(&(&1 != lib_to_symlink_to))
        |> Enum.map(fn lib_to_replace ->
          lib_to_replace_path =
            Path.join(lib_dir, lib_to_replace)

          File.rm_rf!(lib_to_replace_path)
          File.ln_s!(lib_to_symlink_to, lib_to_replace_path)
        end)
      end)
    end)

    release
  end
end
