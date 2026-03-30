defmodule ServiceRadarWebNG.Edge.EnrollmentToken do
  @moduledoc """
  Generates and verifies self-contained enrollment tokens for collector onboarding.

  Signed tokens use the format `collectorpkg-v2:<payload>.<signature>`, where
  the payload is a base64url-encoded JSON object containing:
  - `u` - API base URL
  - `p` - Package ID
  - `t` - Secret token (hashed version stored in DB)
  - `e` - Expiry timestamp (Unix seconds)
  - `f` - Optional config filename hint

  Tokens are always signed and fail closed when the signing key is unavailable.
  """

  alias ServiceRadarWebNG.Web.EndpointConfig

  @default_expiry_hours 24
  @token_v2_prefix "collectorpkg-v2:"
  @signature_separator "."

  @doc """
  Generates a new signed enrollment token for a collector package.

  Returns `{:ok, {token_string, token_hash, secret}}` where:
  - `token_string` is the signed token to give to the operator
  - `token_hash` is the SHA256 hash to store in the database
  - `secret` is the raw secret used for one-time bundle authorization
  """
  @spec generate(String.t(), keyword()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, atom()}
  def generate(package_id, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, default_base_url())
    expiry_hours = Keyword.get(opts, :expiry_hours, @default_expiry_hours)
    config_filename = Keyword.get(opts, :config_filename)
    secret = Keyword.get(opts, :secret) || generate_secret()

    expiry =
      DateTime.utc_now()
      |> DateTime.add(expiry_hours * 3600, :second)
      |> DateTime.to_unix()

    payload =
      maybe_put_config_filename(
        %{"u" => normalize_string(base_url), "p" => normalize_string(package_id), "t" => secret, "e" => expiry},
        config_filename
      )

    with :ok <- validate_payload(payload),
         {:ok, json} <- Jason.encode(payload),
         {:ok, seed} <- signing_seed(opts) do
      signature = :crypto.sign(:eddsa, :none, json, [seed, :ed25519])

      token =
        @token_v2_prefix <>
          Base.url_encode64(json, padding: false) <>
          @signature_separator <> Base.url_encode64(signature, padding: false)

      {:ok, {token, hash_secret(secret), secret}}
    end
  end

  @doc """
  Generates a secure random secret.
  """
  @spec generate_secret() :: String.t()
  def generate_secret do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  Decodes a collector enrollment token.

  Returns `{:ok, %{base_url: url, package_id: id, secret: secret, expires_at: datetime}}`
  or `{:error, reason}`.
  """
  @spec decode(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def decode(token_string, opts \\ [])

  def decode(token_string, opts) when is_binary(token_string) do
    token_string = String.trim(token_string)

    if String.starts_with?(token_string, @token_v2_prefix) do
      decode_v2(token_string, opts)
    else
      {:error, :unsupported_token_format}
    end
  end

  def decode(_token_string, _opts), do: {:error, :unsupported_token_format}

  @doc """
  Verifies a secret against a stored hash.
  """
  @spec verify_secret(String.t(), String.t()) :: boolean()
  def verify_secret(secret, stored_hash) do
    computed_hash = hash_secret(secret)
    Plug.Crypto.secure_compare(computed_hash, stored_hash)
  end

  @doc """
  Checks if a token has expired based on its expiry timestamp.
  """
  @spec expired?(DateTime.t()) :: boolean()
  def expired?(expires_at) do
    DateTime.after?(DateTime.utc_now(), expires_at)
  end

  @doc """
  Generates a CLI command for the given token.
  """
  @spec cli_command(String.t()) :: String.t()
  def cli_command(token), do: cli_command(token, "<your-serviceradar-url>")

  @spec cli_command(String.t(), String.t()) :: String.t()
  def cli_command(token, core_url) do
    "/usr/local/bin/serviceradar-cli enroll --core-url #{core_url} --token #{token}"
  end

  @doc """
  Returns the expiry DateTime for a given token.
  """
  @spec expiry_datetime(keyword()) :: DateTime.t()
  def expiry_datetime(opts \\ []) do
    expiry_hours = Keyword.get(opts, :expiry_hours, @default_expiry_hours)
    DateTime.add(DateTime.utc_now(), expiry_hours * 3600, :second)
  end

  defp decode_v2(token_string, opts) do
    encoded = String.replace_prefix(token_string, @token_v2_prefix, "")

    with [encoded_payload, encoded_signature] <- String.split(encoded, @signature_separator, parts: 2),
         {:ok, json} <- Base.url_decode64(encoded_payload, padding: false),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, public_key} <- verification_public_key(opts),
         true <- :crypto.verify(:eddsa, :none, json, signature, [public_key, :ed25519]),
         {:ok, payload} <- Jason.decode(json),
         {:ok, result} <- extract_payload(payload) do
      {:ok, result}
    else
      [_encoded_payload] -> {:error, :malformed_token}
      [] -> {:error, :malformed_token}
      false -> {:error, :invalid_signature}
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_token}
    end
  end

  defp extract_payload(payload) do
    with {:ok, base_url} <- Map.fetch(payload, "u"),
         {:ok, package_id} <- Map.fetch(payload, "p"),
         {:ok, secret} <- Map.fetch(payload, "t"),
         {:ok, expiry_unix} <- Map.fetch(payload, "e"),
         {:ok, expires_at} <- DateTime.from_unix(expiry_unix) do
      decoded =
        maybe_put_decoded_config_filename(
          %{
            base_url: normalize_string(base_url),
            package_id: normalize_string(package_id),
            secret: normalize_string(secret),
            expires_at: expires_at
          },
          Map.get(payload, "f")
        )

      case validate_decoded_payload(decoded) do
        :ok -> {:ok, decoded}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :missing_fields}
      {:error, _} -> {:error, :invalid_expiry}
    end
  end

  defp maybe_put_config_filename(payload, config_filename) when is_binary(config_filename) do
    config_filename = String.trim(config_filename)
    if config_filename == "", do: payload, else: Map.put(payload, "f", config_filename)
  end

  defp maybe_put_config_filename(payload, _config_filename), do: payload

  defp maybe_put_decoded_config_filename(payload, config_filename) when is_binary(config_filename) do
    config_filename = String.trim(config_filename)
    if config_filename == "", do: payload, else: Map.put(payload, :config_file, config_filename)
  end

  defp maybe_put_decoded_config_filename(payload, _config_filename), do: payload

  defp validate_payload(%{"u" => base_url, "p" => package_id, "t" => secret, "e" => expiry_unix} = payload) do
    cond do
      normalize_string(base_url) == "" ->
        {:error, :missing_base_url}

      normalize_string(package_id) == "" ->
        {:error, :missing_package_id}

      normalize_string(secret) == "" ->
        {:error, :missing_secret}

      not is_integer(expiry_unix) ->
        {:error, :invalid_expiry}

      Map.has_key?(payload, "f") and not is_binary(payload["f"]) ->
        {:error, :invalid_config_file}

      true ->
        :ok
    end
  end

  defp validate_payload(_payload), do: {:error, :invalid_payload}

  defp validate_decoded_payload(%{base_url: base_url, package_id: package_id, secret: secret}) do
    cond do
      base_url == "" -> {:error, :missing_base_url}
      package_id == "" -> {:error, :missing_package_id}
      secret == "" -> {:error, :missing_secret}
      true -> :ok
    end
  end

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

  defp hash_secret(secret) do
    :sha256 |> :crypto.hash(secret) |> Base.encode16(case: :lower)
  end

  defp default_base_url do
    EndpointConfig.base_url()
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: ""
end
