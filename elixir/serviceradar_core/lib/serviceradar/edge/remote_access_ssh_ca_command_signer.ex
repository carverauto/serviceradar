defmodule ServiceRadar.Edge.RemoteAccessSSHCACommandSigner do
  @moduledoc """
  SSH certificate signer boundary backed by an external command.

  The command receives the bounded signing request through
  `SERVICERADAR_SSHCA_SIGN_REQUEST_FILE` and returns JSON on stdout. This keeps
  CA private-key custody outside web-ng and agent-gateway while still giving the
  Elixir issuer a concrete signer module.
  """

  @behaviour ServiceRadar.Edge.RemoteAccessSSHCertificates

  @default_command "serviceradar-sshca-signer"
  @request_file_env "SERVICERADAR_SSHCA_SIGN_REQUEST_FILE"
  @max_error_bytes 2_000
  @max_certificate_bytes 65_536
  @max_fingerprint_bytes 256

  @impl true
  def sign_user_certificate(request, opts) when is_map(request) do
    with {:ok, command} <- command(opts),
         {:ok, payload} <- encode_request(request),
         {:ok, output} <- run_command(command, command_args(opts), payload, command_env(opts)),
         {:ok, decoded} <- decode_response(output) do
      normalize_response(decoded, opts)
    end
  end

  def sign_user_certificate(_request, _opts),
    do: {:error, :ssh_certificate_signer_invalid_request}

  defp command(opts) do
    opts
    |> option(:command, @default_command)
    |> string_or_nil()
    |> case do
      nil -> {:error, :ssh_certificate_signer_command_required}
      command -> {:ok, command}
    end
  end

  defp command_args(opts), do: opts |> option(:args, []) |> list_or_empty()
  defp command_env(opts), do: opts |> option(:env, []) |> list_or_empty()

  defp option(opts, key, default \\ nil) do
    Keyword.get(opts, key, Keyword.get(config(), key, default))
  end

  defp config do
    Application.get_env(:serviceradar_core, __MODULE__, [])
  end

  defp encode_request(request) do
    payload =
      %{
        "public_key" => Map.get(request, :public_key),
        "key_id" => Map.get(request, :key_id),
        "principals" => Map.get(request, :principals, []),
        "ttl_seconds" => Map.get(request, :ttl_seconds)
      }
      |> maybe_put("serial", Map.get(request, :serial))
      |> maybe_put("valid_after", Map.get(request, :valid_after))
      |> maybe_put("critical_options", Map.get(request, :critical_options))
      |> maybe_put("extensions", Map.get(request, :extensions))

    Jason.encode(payload)
  end

  defp run_command(command, args, payload, env) do
    with {:ok, request_dir, request_file} <- write_request_file(payload) do
      try do
        run_with_request_file(command, args, request_file, env)
      after
        File.rm(request_file)
        File.rmdir(request_dir)
      end
    end
  rescue
    error in ErlangError ->
      {:error, {:ssh_certificate_signer_unavailable, Exception.message(error)}}
  end

  defp write_request_file(payload) do
    request_dir =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-sshca-request-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    request_file = Path.join(request_dir, "request.json")

    with :ok <- File.mkdir(request_dir),
         :ok <- File.chmod(request_dir, 0o700),
         :ok <- File.write(request_file, payload, [:write, :binary, :exclusive]),
         :ok <- File.chmod(request_file, 0o600) do
      {:ok, request_dir, request_file}
    else
      {:error, reason} -> {:error, {:ssh_certificate_signer_unavailable, reason}}
    end
  end

  defp run_with_request_file(command, args, request_file, env) do
    env = [{@request_file_env, request_file} | env]

    case System.cmd(
           command,
           args,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output}

      {output, exit_status} ->
        {:error, {:ssh_certificate_signer_failed, exit_status, sanitize(output)}}
    end
  end

  defp decode_response(output) do
    case Jason.decode(output) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :ssh_certificate_signer_invalid_response}
      {:error, _error} -> {:error, :ssh_certificate_signer_invalid_json}
    end
  end

  defp normalize_response(decoded, opts) do
    with {:ok, certificate} <- required_string(decoded, "certificate", @max_certificate_bytes),
         {:ok, fingerprint} <-
           optional_string(Map.get(decoded, "fingerprint"), @max_fingerprint_bytes),
         {:ok, expires_at} <- optional_datetime(Map.get(decoded, "expires_at")) do
      {:ok,
       %{
         certificate: certificate,
         expires_at: expires_at,
         fingerprint: fingerprint,
         serial: Map.get(decoded, "serial"),
         ca_key_id: option(opts, :ca_key_id)
       }}
    end
  end

  defp required_string(map, key, max_bytes) do
    case string_or_nil(Map.get(map, key)) do
      nil -> {:error, :ssh_certificate_signer_invalid_response}
      value when byte_size(value) <= max_bytes -> {:ok, value}
      _value -> {:error, :ssh_certificate_signer_invalid_response}
    end
  end

  defp optional_string(value, max_bytes) do
    case string_or_nil(value) do
      nil -> {:ok, nil}
      value when byte_size(value) <= max_bytes -> {:ok, value}
      _value -> {:error, :ssh_certificate_signer_invalid_response}
    end
  end

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(value) do
    with value when not is_nil(value) <- string_or_nil(value),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      _error -> {:error, :ssh_certificate_signer_invalid_response}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp string_or_nil(nil), do: nil

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp string_or_nil(_value), do: nil

  defp list_or_empty(values) when is_list(values), do: values
  defp list_or_empty(_values), do: []

  defp sanitize(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, @max_error_bytes)
  end

  defp sanitize(_output), do: ""
end
