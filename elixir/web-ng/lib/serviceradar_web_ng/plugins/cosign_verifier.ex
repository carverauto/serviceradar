defmodule ServiceRadarWebNG.Plugins.CosignVerifier do
  @moduledoc """
  Verifies first-party Wasm plugin and native add-on OCI artifacts with Cosign.

  Verification is against the configured release public key only, and needs no
  network access beyond the registry that holds the artifact. The transparency
  log is deliberately not consulted: a first-party signature carries no embedded
  log proof, so checking the log means an online lookup at the public Sigstore
  services, which an air-gapped installation cannot reach. A lookup that cannot
  connect does not fail, it waits, and every import waited with it.

  Cosign runs under its own `--timeout`, so an unreachable registry ends the
  verification with an error instead of holding the import job open.
  """

  @cosign_timeout "60s"

  @type artifact :: %{required(:ref) => String.t(), required(:digest) => String.t()}

  @spec verify(artifact()) :: :ok | {:error, term()}
  def verify(%{ref: ref, digest: digest}) when is_binary(ref) and is_binary(digest) do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])

    case cosign_key_arg(config) do
      {:ok, key_arg, cleanup} ->
        try do
          binary = Keyword.get(config, :cosign_binary, "cosign")
          target = digest_ref(ref, digest)
          {cmd_opts, cleanup_cmd_opts} = cosign_cmd_opts(config)

          try do
            run_cosign(binary, key_arg, target, cmd_opts)
          after
            cleanup_cmd_opts.()
          end
        after
          cleanup.()
        end

      {:error, _reason} = error ->
        error
    end
  end

  def verify(_artifact), do: {:error, :invalid_cosign_artifact}

  defp digest_ref(ref, digest) do
    ref
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.replace(~r/:[^\/:]+$/, "")
    |> then(&"#{&1}@#{digest}")
  end

  defp cosign_key_arg(config) do
    cond do
      key_file = Keyword.get(config, :cosign_public_key_file) ->
        {:ok, key_file, fn -> :ok end}

      key = Keyword.get(config, :cosign_public_key) ->
        path = Path.join(System.tmp_dir!(), "serviceradar-cosign-pub-#{System.unique_integer([:positive])}.pub")
        File.write!(path, key)
        {:ok, path, fn -> File.rm(path) end}

      true ->
        {:error, :cosign_public_key_not_configured}
    end
  end

  defp run_cosign(binary, key_arg, target, opts) do
    args = ["verify", "--timeout", @cosign_timeout, "--insecure-ignore-tlog=true", "--key", key_arg, target]

    case System.cmd(binary, args, opts) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:cosign_verify_failed, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:cosign_verify_failed, Exception.message(error)}}
  end

  defp cosign_cmd_opts(config) do
    runtime_path = Path.join(System.tmp_dir!(), "serviceradar-cosign-runtime-#{System.unique_integer([:positive])}")
    home_path = Path.join(runtime_path, "home")
    cache_path = Path.join(runtime_path, "cache")
    config_path = Path.join(runtime_path, "config")
    sigstore_cache_path = Path.join(runtime_path, "sigstore")

    Enum.each([home_path, cache_path, config_path, sigstore_cache_path], &File.mkdir_p!/1)

    env = [
      {"HOME", home_path},
      {"XDG_CACHE_HOME", cache_path},
      {"XDG_CONFIG_HOME", config_path},
      {"SIGSTORE_CACHE_DIR", sigstore_cache_path}
    ]

    opts = [stderr_to_stdout: true, env: env]

    case registry_docker_config_payload(config) do
      nil ->
        {opts, fn -> File.rm_rf(runtime_path) end}

      payload ->
        path = Path.join(runtime_path, "docker")
        File.mkdir_p!(path)
        File.write!(Path.join(path, "config.json"), payload)

        opts =
          Keyword.update!(opts, :env, fn existing ->
            existing ++
              [
                {"DOCKER_CONFIG", path},
                {"REGISTRY_AUTH_FILE", Path.join(path, "config.json")}
              ]
          end)

        {opts, fn -> File.rm_rf(runtime_path) end}
    end
  end

  defp registry_docker_config_payload(config) do
    cond do
      payload = Keyword.get(config, :registry_docker_config_json) ->
        payload

      path = Keyword.get(config, :registry_docker_config_file) ->
        case File.read(path) do
          {:ok, payload} -> payload
          {:error, _reason} -> nil
        end

      true ->
        nil
    end
  end
end
