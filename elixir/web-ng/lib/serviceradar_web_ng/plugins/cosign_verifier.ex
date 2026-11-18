defmodule ServiceRadarWebNG.Plugins.CosignVerifier do
  @moduledoc """
  Verifies first-party Wasm plugin and native add-on OCI artifacts with Cosign.

  From the cutover release on, the classic `.sig` signature of a first-party
  artifact carries its Rekor transparency-log receipt (`dev.sigstore.cosign/bundle`).
  Verification runs in exactly one of two shapes, chosen from that signature
  (`signature_manifest`, the `.sig` manifest the caller fetched from the
  artifact's registry), never from anything an operator can configure:

    * **Receipt required.** Every digest whose signature carries a receipt, and
      every digest that is not on the frozen pre-cutover allowlist. The Rekor key
      for the receipt's log ID comes from the key set shipped in the image and is
      passed as `SIGSTORE_REKOR_PUBLIC_KEY`; cosign runs with `--offline=true` and
      `--new-bundle-format=false`, without `--trusted-root` and without
      `--insecure-ignore-tlog`. The SignedEntryTimestamp must verify under that
      key, and the logged entry must name the same signature, release key and
      payload hash. A missing receipt, or a log ID with no shipped key, fails
      before cosign runs. Records `verified` with the log index and integrated
      time cosign verified.
    * **Key only.** Only a digest on the allowlist whose signature carries no
      receipt: every first-party signature published before the cutover lacks
      one, and Harbor tag immutability prevents adding it. The release key alone
      (`--insecure-ignore-tlog=true`). Records `absent_allowlisted`.

  Neither shape contacts a public Sigstore service: the registry that holds the
  artifact is the only network destination, so an air-gapped installation
  verifies without waiting on a transparency-log lookup. Cosign runs under its
  own `--timeout`, with isolated home and cache directories.

  The Rekor key set and the allowlist are files baked into the web-ng image
  (`:first_party_transparency_log` in `config/config.exs`). They change only with
  a reviewed web-ng release; there is no runtime override.
  """

  @cosign_timeout "60s"
  @bundle_annotation "dev.sigstore.cosign/bundle"
  @log_id ~r/\A[0-9a-f]{64}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  # Sigstore trust overrides that must not leak in from the server's environment.
  @trust_overrides ~w(
    SIGSTORE_REKOR_PUBLIC_KEY
    SIGSTORE_ROOT_FILE
    SIGSTORE_CT_LOG_PUBLIC_KEY_FILE
    SIGSTORE_TSA_CERTIFICATE_FILE
  )

  @type artifact :: %{
          required(:ref) => String.t(),
          required(:digest) => String.t(),
          required(:signature_manifest) => map()
        }

  @typedoc "Stored on the imported package as `transparency_receipt`."
  @type receipt :: %{required(String.t()) => String.t() | integer()}

  @spec verify(artifact()) :: {:ok, receipt()} | {:error, term()}
  def verify(%{ref: ref, digest: digest, signature_manifest: signature_manifest})
      when is_binary(ref) and is_binary(digest) and is_map(signature_manifest) do
    config = Application.get_env(:serviceradar_web_ng, :first_party_plugin_import, [])
    trust = Application.get_env(:serviceradar_web_ng, :first_party_transparency_log, [])

    with {:ok, mode} <- verification_mode(signature_manifest, digest, trust),
         {:ok, key_arg, cleanup} <- cosign_key_arg(config) do
      try do
        binary = Keyword.get(config, :cosign_binary, "cosign")
        target = digest_ref(ref, digest)
        {cmd_opts, cleanup_cmd_opts} = cosign_cmd_opts(config, mode)

        try do
          run_cosign(mode, binary, key_arg, target, cmd_opts)
        after
          cleanup_cmd_opts.()
        end
      after
        cleanup.()
      end
    end
  end

  def verify(_artifact), do: {:error, :invalid_cosign_artifact}

  defp verification_mode(signature_manifest, digest, trust) do
    case receipt_log_id(signature_manifest) do
      {:ok, nil} ->
        if allowlisted?(digest, trust), do: {:ok, :key_only}, else: {:error, :transparency_receipt_missing}

      {:ok, log_id} ->
        key_file = Path.join(Keyword.get(trust, :rekor_keys_dir, ""), log_id <> ".pub")

        if File.regular?(key_file),
          do: {:ok, {:receipt, log_id, key_file}},
          else: {:error, {:unknown_transparency_log, log_id}}

      {:error, _reason} = error ->
        error
    end
  end

  # The log ID the receipts on the `.sig` layers name, or nil when no layer carries one.
  defp receipt_log_id(signature_manifest) do
    signature_manifest
    |> Map.get("layers")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"annotations" => %{@bundle_annotation => value}} -> [value]
      _layer -> []
    end)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn value, {:ok, log_ids} ->
      case annotation_log_id(value) do
        {:ok, log_id} -> {:cont, {:ok, MapSet.put(log_ids, log_id)}}
        :error -> {:halt, {:error, :malformed_transparency_receipt}}
      end
    end)
    |> case do
      {:ok, log_ids} -> single_log_id(MapSet.to_list(log_ids))
      error -> error
    end
  end

  defp single_log_id([]), do: {:ok, nil}
  defp single_log_id([log_id]), do: {:ok, log_id}
  defp single_log_id(_several), do: {:error, :ambiguous_transparency_receipt}

  defp annotation_log_id(value) when is_binary(value) do
    with {:ok, %{"Payload" => %{"logID" => log_id}}} when is_binary(log_id) <- Jason.decode(value),
         true <- Regex.match?(@log_id, log_id) do
      {:ok, log_id}
    else
      _invalid -> :error
    end
  end

  defp annotation_log_id(_value), do: :error

  defp allowlisted?(digest, trust) do
    with path when is_binary(path) <- Keyword.get(trust, :pre_cutover_digests_file),
         {:ok, raw} <- File.read(path),
         {:ok, %{"digests" => digests}} when is_list(digests) <- Jason.decode(raw) do
      Regex.match?(@digest, digest) and digest in digests
    else
      _unavailable -> false
    end
  end

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

  defp run_cosign({:receipt, log_id, _key_file}, binary, key_arg, target, opts) do
    args = [
      "verify",
      "--timeout",
      @cosign_timeout,
      "--new-bundle-format=false",
      "--offline=true",
      "--key",
      key_arg,
      target
    ]

    case System.cmd(binary, args, opts) do
      {output, 0} -> verified_receipt(output, log_id)
      {output, status} -> {:error, {:cosign_verify_failed, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:cosign_verify_failed, Exception.message(error)}}
  end

  defp run_cosign(:key_only, binary, key_arg, target, opts) do
    args = ["verify", "--timeout", @cosign_timeout, "--insecure-ignore-tlog=true", "--key", key_arg, target]

    case System.cmd(binary, args, opts) do
      {_output, 0} -> {:ok, %{"status" => "absent_allowlisted"}}
      {output, status} -> {:error, {:cosign_verify_failed, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:cosign_verify_failed, Exception.message(error)}}
  end

  # Record the log entry cosign itself verified: its JSON output lists each verified
  # signature with the receipt it checked under `optional.Bundle`.
  defp verified_receipt(output, log_id) do
    output
    |> String.split("\n")
    |> Enum.find_value(&verified_line(&1, log_id))
    |> case do
      nil -> {:error, {:cosign_verify_failed, :verified_receipt_not_reported}}
      receipt -> {:ok, receipt}
    end
  end

  defp verified_line(line, log_id) do
    with "[" <> _rest <- String.trim_leading(line),
         {:ok, signatures} when is_list(signatures) <- Jason.decode(line) do
      Enum.find_value(signatures, &verified_entry(&1, log_id))
    else
      _other -> nil
    end
  end

  defp verified_entry(%{"optional" => %{"Bundle" => %{"Payload" => %{"logID" => log_id} = payload}}}, log_id) do
    case payload do
      %{"logIndex" => log_index, "integratedTime" => integrated_time}
      when is_integer(log_index) and is_integer(integrated_time) ->
        %{
          "status" => "verified",
          "log_id" => log_id,
          "log_index" => log_index,
          "integrated_time" => integrated_time
        }

      _invalid ->
        nil
    end
  end

  defp verified_entry(_signature, _log_id), do: nil

  defp cosign_cmd_opts(config, mode) do
    runtime_path = Path.join(System.tmp_dir!(), "serviceradar-cosign-runtime-#{System.unique_integer([:positive])}")
    home_path = Path.join(runtime_path, "home")
    cache_path = Path.join(runtime_path, "cache")
    config_path = Path.join(runtime_path, "config")
    sigstore_cache_path = Path.join(runtime_path, "sigstore")

    Enum.each([home_path, cache_path, config_path, sigstore_cache_path], &File.mkdir_p!/1)

    env =
      Enum.map(@trust_overrides, &{&1, nil}) ++
        [
          {"HOME", home_path},
          {"XDG_CACHE_HOME", cache_path},
          {"XDG_CONFIG_HOME", config_path},
          {"SIGSTORE_CACHE_DIR", sigstore_cache_path}
        ] ++ rekor_key_env(mode)

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

  defp rekor_key_env({:receipt, _log_id, key_file}), do: [{"SIGSTORE_REKOR_PUBLIC_KEY", key_file}]
  defp rekor_key_env(:key_only), do: []

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
