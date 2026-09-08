defmodule ServiceRadar.Automation.CallbackGrants.KeyedVerifier do
  @moduledoc """
  Contract for keyed callback-bearer verification.

  Implementations return a stable keyed digest suitable for equality lookup.
  The key identifier may be stored with the grant; key material and plaintext
  bearers must never be persisted in the grant or audit rows.
  """

  @callback active_key_id(term()) :: {:ok, binary()} | {:error, term()}
  @callback digest(binary(), binary(), term()) :: {:ok, binary()} | {:error, term()}
end

defmodule ServiceRadar.Automation.CallbackGrants.HMACKeyedVerifier do
  @moduledoc """
  HMAC-SHA-256 implementation of the callback keyed-verifier contract.

  Configuration is a keyword list with `:active_key_id` and a `:keys` map.
  Every verifier key must contain at least 256 bits of independently generated
  secret material. Rotation keeps old key IDs available only for the maximum
  outstanding grant lifetime.
  """

  @behaviour ServiceRadar.Automation.CallbackGrants.KeyedVerifier

  @impl true
  def active_key_id(config) when is_list(config) do
    with {:ok, key_id} <- Keyword.fetch(config, :active_key_id),
         :ok <- validate_key_id(key_id),
         {:ok, _key} <- fetch_key(key_id, config) do
      {:ok, key_id}
    end
  end

  def active_key_id(_config), do: {:error, :invalid_verifier_config}

  @impl true
  def digest(key_id, bearer, config) when is_binary(bearer) and is_list(config) do
    with :ok <- validate_key_id(key_id),
         {:ok, key} <- fetch_key(key_id, config) do
      {:ok, :crypto.mac(:hmac, :sha256, key, bearer)}
    end
  end

  def digest(_key_id, _bearer, _config), do: {:error, :invalid_verifier_input}

  defp fetch_key(key_id, config) do
    with {:ok, keys} <- Keyword.fetch(config, :keys),
         true <- is_map(keys),
         key when is_binary(key) <- Map.get(keys, key_id),
         true <- byte_size(key) >= 32 do
      {:ok, key}
    else
      _ -> {:error, :verifier_key_unavailable}
    end
  end

  defp validate_key_id(key_id) when is_binary(key_id) and byte_size(key_id) in 1..64 do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, key_id),
      do: :ok,
      else: {:error, :invalid_verifier_key_id}
  end

  defp validate_key_id(_key_id), do: {:error, :invalid_verifier_key_id}
end

defmodule ServiceRadar.Automation.CallbackGrants.Token do
  @moduledoc false

  @entropy_bytes 32

  @type issued :: %{bearer: binary(), verifier_key_id: binary(), verifier_digest: binary()}
  @type issued_idempotency :: %{
          idempotency_key: binary(),
          verifier_key_id: binary(),
          verifier_digest: binary()
        }

  @spec issue(module(), term(), keyword()) :: {:ok, issued()} | {:error, term()}
  def issue(verifier, verifier_config, opts \\ []) when is_atom(verifier) do
    random_bytes = Keyword.get(opts, :random_bytes, &:crypto.strong_rand_bytes/1)

    with {:ok, key_id} <- verifier.active_key_id(verifier_config),
         {:ok, entropy} <- safe_random(random_bytes),
         bearer = Base.url_encode64(entropy, padding: false),
         {:ok, digest} <-
           verifier.digest(
             key_id,
             "serviceradar-callback-bearer-v1\0" <> bearer,
             verifier_config
           ) do
      {:ok, %{bearer: bearer, verifier_key_id: key_id, verifier_digest: digest}}
    end
  end

  @spec issue_idempotency_key(module(), term(), keyword()) ::
          {:ok, issued_idempotency()} | {:error, term()}
  def issue_idempotency_key(verifier, verifier_config, opts \\ []) when is_atom(verifier) do
    random_bytes = Keyword.get(opts, :random_bytes, &:crypto.strong_rand_bytes/1)

    with {:ok, key_id} <- verifier.active_key_id(verifier_config),
         {:ok, entropy} <- safe_random(random_bytes),
         idempotency_key = "srci_v1_" <> Base.url_encode64(entropy, padding: false),
         {:ok, digest} <- idempotency_digest(verifier, key_id, idempotency_key, verifier_config) do
      {:ok,
       %{
         idempotency_key: idempotency_key,
         verifier_key_id: key_id,
         verifier_digest: digest
       }}
    end
  end

  @spec verify(binary(), map(), module(), term()) :: :ok | {:error, :invalid_callback_grant}
  def verify(bearer, grant, verifier, verifier_config)
      when is_binary(bearer) and is_map(grant) and is_atom(verifier) do
    key_id = value(grant, :verifier_key_id)
    expected = value(grant, :verifier_digest)

    with true <- is_binary(key_id) and is_binary(expected),
         {:ok, actual} <-
           verifier.digest(
             key_id,
             "serviceradar-callback-bearer-v1\0" <> bearer,
             verifier_config
           ),
         true <- secure_compare(actual, expected) do
      :ok
    else
      _ -> {:error, :invalid_callback_grant}
    end
  end

  def verify(_bearer, _grant, _verifier, _verifier_config), do: {:error, :invalid_callback_grant}

  @spec verify_idempotency_key(binary(), map(), module(), term()) ::
          :ok | {:error, :invalid_idempotency_key}
  def verify_idempotency_key(idempotency_key, grant, verifier, verifier_config)
      when is_binary(idempotency_key) and is_map(grant) and is_atom(verifier) do
    key_id = value(grant, :idempotency_verifier_key_id)
    expected = value(grant, :idempotency_verifier_digest)

    with true <- is_binary(key_id) and is_binary(expected),
         {:ok, actual} <-
           idempotency_digest(verifier, key_id, idempotency_key, verifier_config),
         true <- secure_compare(actual, expected) do
      :ok
    else
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  def verify_idempotency_key(_idempotency_key, _grant, _verifier, _verifier_config),
    do: {:error, :invalid_idempotency_key}

  defp idempotency_digest(verifier, key_id, idempotency_key, verifier_config) do
    verifier.digest(
      key_id,
      "serviceradar-callback-idempotency-v1\0" <> idempotency_key,
      verifier_config
    )
  end

  defp safe_random(random_bytes) do
    case random_bytes.(@entropy_bytes) do
      bytes when is_binary(bytes) and byte_size(bytes) == @entropy_bytes -> {:ok, bytes}
      _ -> {:error, :insufficient_callback_token_entropy}
    end
  rescue
    _ -> {:error, :callback_token_generation_failed}
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
