defmodule ServiceRadar.Automation.CallbackGrants.RuntimeConfig do
  @moduledoc false

  import Bitwise

  @max_file_bytes 8_192
  @max_keys 4

  @spec load_verifier_file!(Path.t()) :: keyword()
  def load_verifier_file!(path) when is_binary(path) and path != "" do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         true <- stat.size in 1..@max_file_bytes,
         true <- secure_mode?(stat.mode),
         {:ok, bytes} <- File.read(path),
         {:ok, document} <- Jason.decode(bytes),
         {:ok, config} <- verifier_config(document) do
      config
    else
      _ -> raise "invalid automation callback HMAC keyring file"
    end
  end

  def load_verifier_file!(_path), do: raise("automation callback HMAC keyring file is required")

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

  # Kubernetes projected secrets are mounted 0440 by the chart. Reject any
  # file readable or writable by "other" users and every executable keyring.
  defp secure_mode?(mode), do: (mode &&& 0o007) == 0 and (mode &&& 0o111) == 0
end
