defmodule ServiceRadar.Automation.CallbackGrants.RuntimeConfig do
  @moduledoc false

  import Bitwise

  alias ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProvider

  @max_file_bytes 8_192
  @max_envelope_key_file_bytes 128
  @max_keys 4
  @max_callback_origin_bytes 512

  @spec load_verifier_file!(Path.t()) :: keyword()
  def load_verifier_file!(path) when is_binary(path) and path != "" do
    with {:ok, bytes} <- read_secure_file(path, @max_file_bytes),
         {:ok, document} <- Jason.decode(bytes),
         {:ok, config} <- verifier_config(document) do
      config
    else
      _ -> raise "invalid automation callback HMAC keyring file"
    end
  end

  def load_verifier_file!(_path), do: raise("automation callback HMAC keyring file is required")

  @spec callback_deployment_config!(map()) :: :disabled | map()
  def callback_deployment_config!(attrs) when is_map(attrs) do
    case boolean(value(attrs, :enabled)) do
      {:ok, false} ->
        :disabled

      {:ok, true} ->
        with {:ok, credential_type_id} <- positive_integer(value(attrs, :credential_type_id)),
             {:ok, organization_id} <- positive_integer(value(attrs, :organization_id)),
             injector_digest when is_binary(injector_digest) <-
               value(attrs, :injector_digest),
             true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, injector_digest),
             policy_file when is_binary(policy_file) and policy_file != "" <-
               value(attrs, :response_policy_file),
             :ok <- validate_response_policy_file(policy_file) do
          %{
            credential_contract: [
              credential_type_id: credential_type_id,
              organization_id: organization_id,
              injector_digest: injector_digest
            ],
            response_policy_provider: FileCallbackResponsePolicyProvider,
            response_policy_provider_config: [path: policy_file]
          }
        else
          _ -> raise "invalid enabled automation callback deployment configuration"
        end

      {:error, _} ->
        raise "invalid automation callback enabled flag"
    end
  end

  def callback_deployment_config!(_attrs),
    do: raise("invalid automation callback deployment configuration")

  @spec load_envelope_key_file!(Path.t()) :: binary()
  def load_envelope_key_file!(path) when is_binary(path) and path != "" do
    with {:ok, bytes} <- read_secure_file(path, @max_envelope_key_file_bytes),
         {:ok, decoded} <- Base.decode64(String.trim(bytes)),
         true <- byte_size(decoded) == 32 do
      decoded
    else
      _ -> raise "invalid automation callback launch-envelope key file"
    end
  end

  def load_envelope_key_file!(_path),
    do: raise("automation callback launch-envelope key file is required")

  @spec canonical_callback_origin(term()) :: {:ok, binary()} | {:error, atom()}
  def canonical_callback_origin(origin) when is_binary(origin) do
    origin = String.trim(origin)

    with true <- origin != "" and byte_size(origin) <= @max_callback_origin_bytes,
         true <- String.valid?(origin),
         %URI{
           scheme: scheme,
           host: host,
           port: parsed_port,
           userinfo: nil,
           path: path,
           query: nil,
           fragment: nil
         } <- URI.parse(origin),
         true <- is_binary(scheme) and String.downcase(scheme) == "https",
         port = parsed_port || 443,
         true <- is_binary(host) and host != "" and not Regex.match?(~r/\s/u, host),
         true <- is_integer(port) and port in 1..65_535,
         true <- path in [nil, ""],
         canonical =
           URI.to_string(%URI{scheme: "https", host: String.downcase(host), port: port}),
         true <- byte_size(canonical) <= @max_callback_origin_bytes do
      {:ok, canonical}
    else
      _ -> {:error, :automation_callback_origin_unavailable}
    end
  end

  def canonical_callback_origin(_origin), do: {:error, :automation_callback_origin_unavailable}

  @spec configured_callback_origin() :: {:ok, binary()} | {:error, atom()}
  def configured_callback_origin do
    case Application.fetch_env(:serviceradar_core, :automation_callback_origin) do
      {:ok, origin} -> canonical_callback_origin(origin)
      :error -> {:error, :automation_callback_origin_unavailable}
    end
  end

  @spec verifier_config(map()) :: {:ok, keyword()} | {:error, atom()}
  def verifier_config(%{"active_key_id" => active_key_id, "keys" => encoded_keys} = document)
      when map_size(document) == 2 and is_map(encoded_keys) do
    with :ok <- key_id(active_key_id),
         true <- map_size(encoded_keys) in 1..@max_keys,
         {:ok, keys} <- decode_keys(encoded_keys),
         true <- Map.has_key?(keys, active_key_id) do
      {:ok, active_key_id: active_key_id, keys: keys}
    else
      _ -> {:error, :invalid_verifier_config}
    end
  end

  def verifier_config(_document), do: {:error, :invalid_verifier_config}

  defp decode_keys(encoded_keys) do
    Enum.reduce_while(encoded_keys, {:ok, %{}}, fn {key_id, encoded}, {:ok, keys} ->
      with :ok <- key_id(key_id),
           true <- is_binary(encoded) and byte_size(encoded) <= 128,
           {:ok, key} <- Base.decode64(encoded),
           true <- byte_size(key) in 32..64 do
        {:cont, {:ok, Map.put(keys, key_id, key)}}
      else
        _ -> {:halt, {:error, :invalid_verifier_config}}
      end
    end)
  end

  defp key_id(value) when is_binary(value) and byte_size(value) in 1..64 do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value),
      do: :ok,
      else: {:error, :invalid_verifier_config}
  end

  defp key_id(_value), do: {:error, :invalid_verifier_config}

  defp boolean(value) when value in [true, "true", "1", "yes"], do: {:ok, true}
  defp boolean(value) when value in [false, nil, "", "false", "0", "no"], do: {:ok, false}
  defp boolean(_value), do: {:error, :invalid_boolean}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :invalid_positive_integer}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp validate_response_policy_file(path) do
    FileCallbackResponsePolicyProvider.validate_file!(path)
  rescue
    _ -> {:error, :invalid_response_policy_file}
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp read_secure_file(path, max_bytes) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         true <- stat.size in 1..max_bytes,
         true <- secure_owner?(stat.uid),
         true <- secure_mode?(stat.mode),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) in 1..max_bytes do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_secure_key_file}
    end
  end

  # Kubernetes projected secrets are root-owned and mounted 0440 by the chart.
  # Local secret files may instead be owned by the effective service user.
  defp secure_owner?(uid) when is_integer(uid), do: uid in [0, effective_uid()]
  defp secure_owner?(_uid), do: false

  # Accept only 0400/0440/0600/0640-style permissions. In particular, group
  # write, every "other" permission, and every executable bit are forbidden.
  defp secure_mode?(mode) when is_integer(mode) do
    permissions = mode &&& 0o777
    (permissions &&& 0o400) == 0o400 and (permissions &&& bnot(0o640)) == 0
  end

  defp secure_mode?(_mode), do: false

  defp effective_uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+(\d+)/m, status),
         {uid, ""} <- Integer.parse(uid) do
      uid
    else
      _ -> effective_uid_from_command()
    end
  end

  defp effective_uid_from_command do
    case System.cmd("/usr/bin/id", ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} -> uid
          _ -> -1
        end

      _ ->
        -1
    end
  rescue
    _ -> -1
  end
end
