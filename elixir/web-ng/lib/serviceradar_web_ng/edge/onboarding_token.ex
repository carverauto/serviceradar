defmodule ServiceRadarWebNG.Edge.OnboardingToken do
  @moduledoc false

  @token_v2_prefix "edgepkg-v2:"
  @signature_separator "."

  @type payload :: %{
          required(:pkg) => String.t(),
          required(:dl) => String.t(),
          optional(:api) => String.t()
        }

  def encode(package_id, download_token, core_api_url \\ nil, opts \\ []) do
    payload =
      maybe_put_api(
        %{pkg: normalize_required_string(package_id), dl: normalize_required_string(download_token)},
        core_api_url
      )

    with :ok <- validate_payload(payload),
         {:ok, json} <- encode_payload_json(payload) do
      case signing_seed(opts) do
        {:ok, seed} ->
          signature = :crypto.sign(:eddsa, :none, json, [seed, :ed25519])

          {:ok,
           @token_v2_prefix <>
             Base.url_encode64(json, padding: false) <>
             @signature_separator <> Base.url_encode64(signature, padding: false)}

        {:error, :missing_signing_key} ->
          {:error, :missing_signing_key}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def decode(raw, opts \\ [])

  def decode(raw, opts) when is_binary(raw) do
    raw = String.trim(raw)

    cond do
      String.starts_with?(raw, @token_v2_prefix) ->
        decode_v2(raw, opts)

      true ->
        {:error, :unsupported_token_format}
    end
  end

  def decode(_, _opts), do: {:error, :unsupported_token_format}

  defp decode_v2(raw, opts) do
    encoded = String.replace_prefix(raw, @token_v2_prefix, "")

    with [encoded_payload, encoded_signature] <- String.split(encoded, @signature_separator, parts: 2),
         {:ok, json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, public_key} <- verification_public_key(opts),
         true <- :crypto.verify(:eddsa, :none, json, signature, [public_key, :ed25519]),
         {:ok, payload} <- Jason.decode(json),
         payload = atomize_payload(payload),
         :ok <- validate_payload(payload) do
      {:ok, payload}
    else
      [_encoded_payload] -> {:error, :malformed_token}
      [] -> {:error, :malformed_token}
      false -> {:error, :invalid_signature}
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, _} = error -> error
      _ -> {:error, :malformed_token}
    end
  end

  defp maybe_put_api(payload, nil), do: payload

  defp maybe_put_api(payload, api) when is_binary(api) do
    api = String.trim(api)
    if api == "", do: payload, else: Map.put(payload, :api, api)
  end

  defp maybe_put_api(payload, _), do: payload

  defp atomize_payload(%{} = payload) do
    %{
      pkg: Map.get(payload, "pkg", ""),
      dl: Map.get(payload, "dl", ""),
      api: Map.get(payload, "api")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp validate_payload(%{pkg: pkg, dl: dl} = payload) do
    cond do
      not is_binary(pkg) or pkg == "" ->
        {:error, :missing_package_id}

      not is_binary(dl) or dl == "" ->
        {:error, :missing_download_token}

      Map.has_key?(payload, :api) and not is_binary(payload.api) ->
        {:error, :invalid_core_api_url}

      true ->
        :ok
    end
  end

  defp validate_payload(_), do: {:error, :invalid_payload}

  defp encode_payload_json(%{pkg: pkg, dl: dl} = payload) do
    json =
      [
        ~s({"pkg":),
        Jason.encode!(pkg),
        ~s(,"dl":),
        Jason.encode!(dl)
      ]
      |> maybe_append_api(payload)
      |> Kernel.++(["}"])
      |> IO.iodata_to_binary()

    {:ok, json}
  end

  defp maybe_append_api(parts, %{api: api}) when is_binary(api), do: parts ++ [~s(,"api":), Jason.encode!(api)]

  defp maybe_append_api(parts, _payload), do: parts

  defp signing_seed(opts) do
    with {:ok, raw_key} <- fetch_key(opts, :private_key, :onboarding_token_private_key),
         {:ok, key_bytes} <- decode_key(raw_key) do
      case byte_size(key_bytes) do
        32 -> {:ok, key_bytes}
        64 -> {:ok, binary_part(key_bytes, 0, 32)}
        _ -> {:error, :invalid_private_key}
      end
    end
  end

  defp verification_public_key(opts) do
    case fetch_key(opts, :public_key, :onboarding_token_public_key) do
      {:ok, raw_key} ->
        with {:ok, key_bytes} <- decode_key(raw_key),
             true <- byte_size(key_bytes) == 32 do
          {:ok, key_bytes}
        else
          false -> {:error, :invalid_public_key}
          {:error, _} = error -> error
        end

      {:error, :missing_signing_key} ->
        with {:ok, seed} <- signing_seed(opts),
             {public_key, _private_key} <- :crypto.generate_key(:eddsa, :ed25519, seed) do
          {:ok, public_key}
        else
          {:error, _} = error -> error
        end
    end
  end

  defp fetch_key(opts, opt_key, config_key) do
    cond do
      is_binary(opts[opt_key]) and String.trim(opts[opt_key]) != "" ->
        {:ok, String.trim(opts[opt_key])}

      is_binary(Application.get_env(:serviceradar_web_ng, config_key)) and
          String.trim(Application.get_env(:serviceradar_web_ng, config_key)) != "" ->
        {:ok, String.trim(Application.get_env(:serviceradar_web_ng, config_key))}

      true ->
        {:error, :missing_signing_key}
    end
  end

  defp decode_key(raw_key) when is_binary(raw_key) do
    raw_key = String.trim(raw_key)

    decoders = [
      fn -> Base.decode64(raw_key) end,
      fn -> Base.url_decode64(raw_key, padding: false) end,
      fn -> Base.decode16(raw_key, case: :mixed) end
    ]

    Enum.reduce_while(decoders, {:error, :invalid_key}, fn decoder, _acc ->
      case decoder.() do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        :error -> {:cont, {:error, :invalid_key}}
      end
    end)
  end

  defp normalize_required_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_required_string(_), do: ""
end
