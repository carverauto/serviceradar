defmodule ServiceRadar.Plugins.SecretRefs do
  @moduledoc """
  Helpers for storing plugin secret-reference params without echoing raw secrets.
  """

  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Plugins.MapUtils

  @secret_prefix "secretref:"
  @network_credential_prefix "credentialref:network-credential-secret:"
  @network_credential_grant_prefix "credentialref:network-credential-grant:"
  @network_credential_grant_schema "serviceradar.network_credential_grant_ref.v1"
  @network_credential_grant_default_ttl_seconds 60
  @network_credential_grant_max_ttl_seconds 60
  @network_credential_grant_replay_table :serviceradar_network_credential_grant_replays
  @secret_material_key "_secret_material"

  @spec prepare_params_for_storage(map(), map(), map()) :: map()
  def prepare_params_for_storage(schema, params, existing_params \\ %{})

  def prepare_params_for_storage(schema, params, existing_params)
      when is_map(schema) and is_map(params) and is_map(existing_params) do
    params =
      params
      |> stringify_keys()
      |> apply_selected_credentials(schema)

    existing_params = stringify_keys(existing_params)

    params
    |> prepare_direct_params_for_storage(schema, existing_params)
    |> maybe_prepare_template_for_storage(schema, params, existing_params)
  end

  def prepare_params_for_storage(_schema, params, _existing_params) when is_map(params),
    do: public_params(params)

  def prepare_params_for_storage(_schema, _params, _existing_params), do: %{}

  @credential_select_suffix "__credential"

  @doc """
  The submitted-params key the settings UI uses to offer a reusable credential
  for a `secretRef` field.

  A separate key rather than the field's own name: the form renders the credential
  select *and* the raw-entry input together, and two controls sharing one name means
  the last one submitted wins -- the empty password box would clobber a chosen
  credential every time.
  """
  @spec credential_select_key(String.t()) :: String.t()
  def credential_select_key(field), do: field <> @credential_select_suffix

  # Fold a chosen credential into its field, then drop the sidecar so it never
  # reaches stored params. A blank selection leaves the field alone, so raw entry
  # and "leave unchanged" both behave exactly as they did before.
  defp apply_selected_credentials(params, schema) do
    schema
    |> secret_ref_fields()
    |> Enum.reduce(params, fn field, acc ->
      key = credential_select_key(field)

      case Map.get(acc, key) do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> Map.delete(acc, key)
            ref -> acc |> Map.put(field, ref) |> Map.delete(key)
          end

        _ ->
          Map.delete(acc, key)
      end
    end)
  end

  defp prepare_direct_params_for_storage(params, schema, existing_params) do
    existing_material = secret_material(existing_params)

    {result, kept_material} =
      Enum.reduce(secret_ref_fields(schema), {public_params(params), %{}}, fn field,
                                                                              {acc, material} ->
        preserve_secret_field(acc, material, field, params, existing_params, existing_material)
      end)

    if map_size(kept_material) == 0 do
      Map.delete(result, @secret_material_key)
    else
      Map.put(result, @secret_material_key, kept_material)
    end
  end

  @spec public_params(map()) :: map()
  def public_params(params) when is_map(params) do
    params
    |> stringify_keys()
    |> remove_secret_material()
  end

  def public_params(_params), do: %{}

  @doc """
  Resolves stored secret references into runtime params.

  Options:

    * `:grant` — a credential broker grant (struct or map). Network credential
      references whose secret matches the grant resolve through
      `SecretBroker.resolve_with_grant/2`, which permits external-reference
      secrets and validates grant scope/expiry.
    * `:broker_opts` — extra options forwarded to the broker call (e.g.
      `audit?: true`, `:actor`, `:agent_id`); applies to both grant-backed and
      grant-less resolution so each resolution can be audited.
  """
  @spec resolve_runtime_params(map(), map(), keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def resolve_runtime_params(schema, params, opts \\ [])

  def resolve_runtime_params(schema, params, opts) when is_map(schema) and is_map(params) do
    params = stringify_keys(params)

    with {:ok, resolved} <- resolve_direct_runtime_params(schema, params, opts) do
      maybe_resolve_template_runtime(schema, resolved, params, opts)
    end
  end

  def resolve_runtime_params(_schema, params, _opts) when is_map(params),
    do: {:ok, public_params(params)}

  def resolve_runtime_params(_schema, _params, _opts), do: {:ok, %{}}

  @spec validate_secret_linkage(map(), map()) :: :ok | {:error, [String.t()]}
  def validate_secret_linkage(schema, params) when is_map(schema) and is_map(params) do
    params = stringify_keys(params)

    errors =
      direct_secret_linkage_errors(schema, params) ++
        template_secret_linkage_errors(schema, params)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  def validate_secret_linkage(_schema, _params), do: :ok

  @spec secret_ref_fields(map()) :: [String.t()]
  def secret_ref_fields(schema) when is_map(schema) do
    schema
    |> stringify_keys()
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {name, property} ->
      if secret_ref_property?(property), do: [name], else: []
    end)
  end

  def secret_ref_fields(_schema), do: []

  @spec secret_ref_property?(map()) :: boolean()
  def secret_ref_property?(property) when is_map(property) do
    property
    |> stringify_keys()
    |> Map.get("secretRef") == true
  end

  def secret_ref_property?(_property), do: false

  @spec runtime_field_name(String.t()) :: String.t()
  def runtime_field_name(field) when is_binary(field) do
    String.replace_suffix(field, "_secret_ref", "")
  end

  @spec secret_ref?(String.t()) :: boolean()
  def secret_ref?(value) when is_binary(value) do
    String.starts_with?(value, @secret_prefix) or network_credential_ref?(value)
  end

  def secret_ref?(_value), do: false

  @spec network_credential_ref(String.t()) :: String.t()
  def network_credential_ref(secret_id) when is_binary(secret_id) do
    @network_credential_prefix <> secret_id
  end

  @spec network_credential_grant_ref(String.t(), keyword()) :: String.t()
  def network_credential_grant_ref(secret_id, opts \\ []) when is_binary(secret_id) do
    ttl_seconds =
      opts
      |> Keyword.get(:ttl_seconds, @network_credential_grant_default_ttl_seconds)
      |> clamp_int(1, @network_credential_grant_max_ttl_seconds)

    payload =
      %{
        "schema" => @network_credential_grant_schema,
        "secret_id" => secret_id,
        "exp" => Keyword.get(opts, :expires_at_unix, current_unix_second() + ttl_seconds),
        "nonce" => Crypto.generate_token()
      }
      |> put_optional_claims(Keyword.get(opts, :claims, %{}))
      |> Jason.encode!()

    @network_credential_grant_prefix <>
      Base.url_encode64(payload, padding: false) <>
      "." <>
      Base.url_encode64(sign_network_credential_grant_payload(payload), padding: false)
  end

  @spec network_credential_ref_id(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def network_credential_ref_id(ref) when is_binary(ref) do
    cond do
      legacy_network_credential_ref?(ref) ->
        network_credential_secret_ref_id(ref)

      network_credential_grant_ref?(ref) ->
        network_credential_grant_ref_id(ref)

      true ->
        {:error, "is not a network credential reference"}
    end
  end

  @doc "Returns the credential ID from a canonical stored network-credential reference."
  @spec network_credential_secret_ref_id(String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def network_credential_secret_ref_id(ref) when is_binary(ref) do
    if legacy_network_credential_ref?(ref) do
      legacy_network_credential_ref_id(ref)
    else
      {:error, "is not a stored network credential reference"}
    end
  end

  defp preserve_secret_field(acc, material, field, params, existing_params, existing_material) do
    incoming = normalize_string(Map.get(params, field))
    existing_ref = secret_ref_value(existing_params, field)

    case classify_secret_update(incoming, existing_ref, existing_material) do
      :keep_existing ->
        keep_existing_secret(acc, material, field, existing_ref, existing_material)

      :delete ->
        {Map.delete(acc, field), material}

      :existing_material_ref ->
        {Map.put(acc, field, incoming),
         Map.put(material, incoming, Map.fetch!(existing_material, incoming))}

      :passthrough_ref ->
        {Map.put(acc, field, incoming), material}

      :new_secret ->
        ref = generate_secret_ref(field)

        {
          Map.put(acc, field, ref),
          Map.put(material, ref, Crypto.encrypt(incoming))
        }
    end
  end

  defp resolve_secret_field(acc, field, material, opts) do
    with ref when not is_nil(ref) <- secret_ref_value(acc, field),
         {:ok, secret} <- resolve_secret_ref(material, ref, field, opts) do
      {:ok, Map.put(acc, runtime_field_name(field), secret)}
    else
      nil -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_secret_ref(material, ref, field, opts) do
    if network_credential_ref?(ref) do
      resolve_network_credential_ref(ref, field, opts)
    else
      with {:ok, encrypted} <- fetch_secret_material(material, ref, field) do
        decrypt_secret_material(encrypted, field)
      end
    end
  end

  defp fetch_secret_material(material, ref, field) do
    case Map.get(material, ref) do
      nil -> {:error, "#{field} is missing secret material"}
      encrypted -> {:ok, encrypted}
    end
  end

  defp decrypt_secret_material(encrypted, field) do
    case Crypto.decrypt_safe(encrypted) do
      {:ok, secret} -> {:ok, secret}
      {:error, :decrypt_failed} -> {:error, "#{field} could not be decrypted"}
    end
  end

  defp resolve_network_credential_ref(ref, field, opts) do
    with {:ok, secret_id} <- network_credential_ref_id(ref),
         {:ok, %{secret: secret, value: payload}} <- broker_resolve(secret_id, opts),
         true <- payload != "" do
      {:ok, format_network_credential_payload(secret, payload)}
    else
      {:error, reason} -> {:error, "#{field} #{format_broker_error(reason)}"}
      _ -> {:error, "#{field} referenced network credential has no secret payload"}
    end
  end

  defp broker_resolve(secret_id, opts) do
    broker_opts = Keyword.get(opts, :broker_opts, [])

    case grant_for_secret(Keyword.get(opts, :grant), secret_id) do
      nil ->
        SecretBroker.resolve_network_credential_secret(
          secret_id,
          Keyword.merge(
            [
              allow_external_resolution?: false,
              consumer_kind: :plugin,
              resolution_location: :agent
            ],
            broker_opts
          )
        )

      grant ->
        SecretBroker.resolve_with_grant(grant, broker_opts)
    end
  end

  # Only route through the grant when it actually covers the referenced secret;
  # otherwise fall back to the historical grant-less resolution path.
  defp grant_for_secret(nil, _secret_id), do: nil

  defp grant_for_secret(grant, secret_id) when is_map(grant) do
    grant_secret_id =
      grant_value(grant, :secret_id) || grant_ref_secret_id(grant_value(grant, :secret_ref))

    if to_string(grant_secret_id || "") == secret_id, do: grant
  end

  defp grant_for_secret(_grant, _secret_id), do: nil

  defp grant_value(grant, key), do: Map.get(grant, key) || Map.get(grant, to_string(key))

  defp grant_ref_secret_id(ref) when is_binary(ref) do
    case network_credential_ref_id(ref) do
      {:ok, secret_id} -> secret_id
      {:error, _reason} -> nil
    end
  end

  defp grant_ref_secret_id(_ref), do: nil

  defp format_broker_error(reason) when is_binary(reason), do: reason
  defp format_broker_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_broker_error(reason), do: inspect(reason)

  defp format_network_credential_payload(secret, payload) do
    if proxmox_api_token_secret?(secret) do
      format_proxmox_api_token(secret, payload)
    else
      payload
    end
  end

  defp proxmox_api_token_secret?(secret) do
    Map.get(secret, :provider) == "proxmox" and Map.get(secret, :credential_kind) == :api_token
  end

  defp format_proxmox_api_token(secret, payload) do
    payload = String.trim(payload)
    token_id = proxmox_token_id(secret)
    {_payload_token_id, payload_secret} = split_proxmox_api_token_payload(payload)

    cond do
      String.starts_with?(payload, "PVEAPIToken=") ->
        String.replace_prefix(payload, "PVEAPIToken=", "")

      token_id in [nil, ""] ->
        payload

      String.starts_with?(payload, token_id <> "=") ->
        payload

      payload_secret not in [nil, ""] ->
        token_id <> "=" <> payload_secret

      true ->
        token_id <> "=" <> payload
    end
  end

  defp split_proxmox_api_token_payload(payload) when is_binary(payload) do
    case String.split(payload, "=", parts: 2) do
      [token_id, secret] when token_id != "" and secret != "" ->
        if String.contains?(token_id, "!") do
          {token_id, secret}
        else
          {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp proxmox_token_id(secret) do
    metadata = Map.get(secret, :metadata) || %{}

    Enum.find_value(
      [Map.get(metadata, "token_id"), Map.get(metadata, :token_id), Map.get(secret, :username)],
      fn
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        _ ->
          nil
      end
    )
  end

  defp classify_secret_update(nil, existing_ref, _existing_material)
       when not is_nil(existing_ref), do: :keep_existing

  defp classify_secret_update(nil, _existing_ref, _existing_material), do: :delete

  defp classify_secret_update(incoming, existing_ref, _existing_material)
       when not is_nil(existing_ref) and incoming == existing_ref, do: :keep_existing

  defp classify_secret_update(incoming, _existing_ref, existing_material) do
    cond do
      secret_ref?(incoming) and Map.has_key?(existing_material, incoming) ->
        :existing_material_ref

      secret_ref?(incoming) ->
        :passthrough_ref

      true ->
        :new_secret
    end
  end

  defp keep_existing_secret(acc, material, field, existing_ref, existing_material) do
    if encrypted = Map.get(existing_material, existing_ref) do
      {
        Map.put(acc, field, existing_ref),
        Map.put(material, existing_ref, encrypted)
      }
    else
      {Map.put(acc, field, existing_ref), material}
    end
  end

  defp secret_ref_value(params, field) do
    case normalize_string(Map.get(params, field)) do
      nil -> nil
      value -> value
    end
  end

  defp generate_secret_ref(field) do
    suffix =
      field
      |> runtime_field_name()
      |> String.replace(~r/[^a-zA-Z0-9_:-]/, "-")

    @secret_prefix <> suffix <> ":" <> Crypto.generate_token()
  end

  defp secret_material(params) do
    params
    |> Map.get(@secret_material_key, %{})
    |> stringify_keys()
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp maybe_prepare_template_for_storage(result, schema, params, existing_params) do
    template = Map.get(params, "template")

    if plugin_inputs_payload?(params) and is_map(template) do
      existing_template =
        existing_params
        |> Map.get("template", %{})
        |> stringify_keys()

      prepared_template =
        template
        |> stringify_keys()
        |> prepare_direct_params_for_storage(schema, existing_template)

      Map.put(result, "template", prepared_template)
    else
      result
    end
  end

  defp resolve_direct_runtime_params(schema, params, opts) do
    material = secret_material(params)

    Enum.reduce_while(secret_ref_fields(schema), {:ok, public_params(params)}, fn field,
                                                                                  {:ok, acc} ->
      case resolve_secret_field(acc, field, material, opts) do
        {:ok, resolved} ->
          {:cont, {:ok, resolved}}

        {:error, reason} ->
          {:halt, {:error, [reason]}}
      end
    end)
  end

  defp maybe_resolve_template_runtime(schema, resolved, params, opts) do
    template = Map.get(params, "template")

    if plugin_inputs_payload?(params) and is_map(template) do
      case resolve_direct_runtime_params(schema, stringify_keys(template), opts) do
        {:ok, runtime_template} -> {:ok, Map.put(resolved, "template", runtime_template)}
        {:error, _} = error -> error
      end
    else
      {:ok, resolved}
    end
  end

  defp direct_secret_linkage_errors(schema, params) do
    material = secret_material(params)

    Enum.flat_map(secret_ref_fields(schema), fn field ->
      ref = secret_ref_value(params, field)

      cond do
        is_nil(ref) ->
          []

        not secret_ref?(ref) ->
          ["#{field} must be a secret reference"]

        network_credential_ref?(ref) ->
          []

        is_nil(Map.get(material, ref)) ->
          ["#{field} is missing linked secret material"]

        true ->
          []
      end
    end)
  end

  defp template_secret_linkage_errors(schema, params) do
    template = Map.get(params, "template")

    if plugin_inputs_payload?(params) and is_map(template) do
      schema
      |> direct_secret_linkage_errors(stringify_keys(template))
      |> Enum.map(&("template." <> &1))
    else
      []
    end
  end

  defp plugin_inputs_payload?(params) when is_map(params) do
    Map.get(params, "schema") == "serviceradar.plugin_inputs.v1" or Map.has_key?(params, "inputs")
  end

  defp plugin_inputs_payload?(_params), do: false

  defp network_credential_ref?(value) when is_binary(value) do
    legacy_network_credential_ref?(value) or network_credential_grant_ref?(value)
  end

  defp network_credential_ref?(_value), do: false

  defp legacy_network_credential_ref?(value) when is_binary(value) do
    String.starts_with?(value, @network_credential_prefix)
  end

  defp legacy_network_credential_ref?(_value), do: false

  defp network_credential_grant_ref?(value) when is_binary(value) do
    String.starts_with?(value, @network_credential_grant_prefix)
  end

  defp network_credential_grant_ref?(_value), do: false

  defp legacy_network_credential_ref_id(ref) do
    secret_id = String.replace_prefix(ref, @network_credential_prefix, "")

    if secret_id == "" do
      {:error, "has an empty network credential reference"}
    else
      {:ok, secret_id}
    end
  end

  defp network_credential_grant_ref_id(ref) do
    token = String.replace_prefix(ref, @network_credential_grant_prefix, "")

    with [payload_token, mac_token] <- String.split(token, ".", parts: 2),
         {:ok, payload} <-
           decode_url64(payload_token, "has an invalid network credential grant payload"),
         {:ok, mac} <-
           decode_url64(mac_token, "has an invalid network credential grant signature"),
         :ok <- verify_network_credential_grant_signature(payload, mac),
         {:ok, claims} <- decode_network_credential_grant_claims(payload),
         :ok <- validate_network_credential_grant_claims(claims),
         :ok <- consume_network_credential_grant_nonce(claims),
         {:ok, secret_id} <- network_credential_grant_secret_id(claims) do
      {:ok, secret_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "has a malformed network credential grant reference"}
    end
  end

  defp decode_url64(value, error) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, error}
    end
  end

  defp verify_network_credential_grant_signature(payload, mac) do
    expected = sign_network_credential_grant_payload(payload)

    if secure_compare(mac, expected),
      do: :ok,
      else: {:error, "has an invalid network credential grant signature"}
  end

  defp sign_network_credential_grant_payload(payload) do
    :crypto.mac(:hmac, :sha256, network_credential_grant_key(), payload)
  end

  defp network_credential_grant_key do
    secret = Application.get_env(:serviceradar_core, :crypto_secret)

    if is_binary(secret) and byte_size(secret) >= 32 do
      :crypto.mac(:hmac, :sha256, "serviceradar-network-credential-grant-ref", secret)
    else
      raise "crypto_secret must be configured and at least 32 bytes"
    end
  end

  defp decode_network_credential_grant_claims(payload) do
    case Jason.decode(payload) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _ -> {:error, "has an invalid network credential grant payload"}
    end
  end

  defp validate_network_credential_grant_claims(%{
         "schema" => @network_credential_grant_schema,
         "exp" => exp,
         "nonce" => nonce
       })
       when is_integer(exp) and is_binary(nonce) and nonce != "" do
    if exp >= current_unix_second(),
      do: :ok,
      else: {:error, "has an expired network credential grant reference"}
  end

  defp validate_network_credential_grant_claims(_claims),
    do: {:error, "has an invalid network credential grant payload"}

  defp network_credential_grant_secret_id(%{"secret_id" => secret_id})
       when is_binary(secret_id) and secret_id != "",
       do: {:ok, secret_id}

  defp network_credential_grant_secret_id(_claims),
    do: {:error, "has an empty network credential reference"}

  defp consume_network_credential_grant_nonce(%{"exp" => exp, "nonce" => nonce})
       when is_integer(exp) and is_binary(nonce) do
    table = ensure_network_credential_grant_replay_table()
    now = current_unix_second()

    :ets.select_delete(table, [{{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}])

    if :ets.insert_new(table, {nonce, exp}),
      do: :ok,
      else: {:error, "has already been used"}
  end

  defp ensure_network_credential_grant_replay_table do
    case :ets.whereis(@network_credential_grant_replay_table) do
      :undefined ->
        try do
          :ets.new(@network_credential_grant_replay_table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> @network_credential_grant_replay_table
        end

      table ->
        table
    end
  end

  defp put_optional_claims(payload, claims) when is_map(claims) do
    claims
    |> stringify_keys()
    |> Map.take(["session_id", "actor_id", "agent_id", "gateway_id", "protocol", "target"])
    |> Enum.reject(fn {_key, value} ->
      is_nil(value) or value == "" or value == %{} or value == []
    end)
    |> Map.new()
    |> Map.merge(payload)
  end

  defp put_optional_claims(payload, _claims), do: payload

  defp clamp_int(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp_int(_value, min, _max), do: min

  defp current_unix_second, do: System.system_time(:second)

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left_bytes = :binary.bin_to_list(left)
    right_bytes = :binary.bin_to_list(right)

    result =
      left_bytes
      |> Enum.zip(right_bytes)
      |> Enum.reduce(0, fn {left_byte, right_byte}, acc ->
        Bitwise.bor(acc, Bitwise.bxor(left_byte, right_byte))
      end)

    result == 0
  end

  defp secure_compare(_left, _right), do: false

  defp remove_secret_material(%{} = map) do
    map
    |> Map.delete(@secret_material_key)
    |> Map.new(fn {key, value} -> {key, remove_secret_material(value)} end)
  end

  defp remove_secret_material(list) when is_list(list),
    do: Enum.map(list, &remove_secret_material/1)

  defp remove_secret_material(value), do: value

  defp stringify_keys(value), do: MapUtils.stringify_keys_or_empty(value)
end
