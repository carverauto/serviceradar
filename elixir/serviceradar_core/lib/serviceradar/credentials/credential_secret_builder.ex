defmodule ServiceRadar.Credentials.CredentialSecretBuilder do
  @moduledoc """
  Builds encrypted credential attributes from a validated package descriptor.

  Package manifests choose only a bounded storage encoding. They never supply
  executable serializers and never receive the submitted plaintext values.
  """

  alias ServiceRadar.Credentials.SshPrivateKeyCredential

  @credential_kinds %{
    "api_token" => :api_token,
    "username_password" => :username_password,
    "ssh_private_key" => :ssh_private_key,
    "certificate" => :certificate,
    # SNMP needs no encoder of its own: a descriptor declares the fields its
    # version uses (community, or username + auth/priv protocol and password)
    # and the default `json` payload format stores exactly the map
    # `SNMPProfiles.CredentialResolver.broker_json_credential/3` already reads.
    "snmp" => :snmp,
    "opaque" => :opaque
  }

  @rotatable_states [:active, :rotation_due, :rotation_failed]
  @rotation_attributes [
    :secret_payload,
    :username,
    :public_fingerprint,
    :metadata,
    :next_rotation_due_at
  ]

  @spec build(map(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def build(profile, auth_method, values, common_attrs)
      when is_map(profile) and is_binary(auth_method) and is_map(values) and is_map(common_attrs) do
    with %{} = method <- find_method(profile, auth_method),
         {:ok, normalized_values} <- validate_values(method, values),
         {:ok, payload} <- encode_payload(method, normalized_values),
         {:ok, credential_kind} <- credential_kind(method["credential_kind"]),
         {:ok, public_fingerprint} <-
           public_fingerprint(credential_kind, method, normalized_values, payload) do
      metadata = %{
        "auth_method" => auth_method,
        "credential_descriptor" => "package_manifest.v1",
        "plugin_id" => profile["plugin_id"],
        "plugin_version" => profile["plugin_version"]
      }

      {:ok,
       Map.merge(common_attrs, %{
         provider: profile["provider"],
         credential_kind: credential_kind,
         username: public_username(method, normalized_values),
         public_fingerprint: public_fingerprint,
         secret_payload: payload,
         last_rotated_at: DateTime.utc_now(),
         metadata: metadata |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
       })}
    else
      nil -> {:error, :credential_method_not_found}
      {:error, _reason} = error -> error
    end
  end

  def build(_profile, _auth_method, _values, _common_attrs),
    do: {:error, :invalid_credential_descriptor}

  @doc """
  Builds a complete replacement for one descriptor-backed internal credential.

  The current approved profile must match the credential's stored provider,
  kind, and authentication method. Existing plaintext is never loaded or
  merged; all required values must be present in `submitted_values`.
  """
  @spec build_rotation(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_rotation(secret, profile, submitted_values, opts)
      when is_map(secret) and is_map(profile) and is_map(submitted_values) and is_list(opts) do
    with :ok <- validate_rotation_source(secret),
         :ok <- validate_rotation_state(secret),
         :ok <- validate_rotation_provider(secret, profile),
         {:ok, auth_method} <- rotation_auth_method(secret, profile),
         %{} = method <- find_method(profile, auth_method),
         {:ok, method_kind} <- credential_kind(method["credential_kind"]),
         :ok <- validate_rotation_kind(secret, method_kind),
         {:ok, attrs} <- build(profile, auth_method, submitted_values, %{}) do
      {:ok,
       attrs
       |> Map.take(@rotation_attributes)
       |> Map.put(:next_rotation_due_at, Map.get(secret, :next_rotation_due_at))}
    else
      nil -> {:error, :credential_method_not_found}
      {:error, _reason} = error -> error
    end
  end

  def build_rotation(_secret, _profile, _submitted_values, _opts),
    do: {:error, :invalid_credential_rotation}

  defp validate_rotation_source(%{source_type: :internal_encrypted}), do: :ok
  defp validate_rotation_source(_secret), do: {:error, :credential_rotation_not_supported}

  defp validate_rotation_state(%{rotation_state: state}) when state in @rotatable_states, do: :ok

  defp validate_rotation_state(_secret), do: {:error, :credential_rotation_not_allowed}

  defp rotation_auth_method(%{metadata: metadata} = secret, profile) when is_map(metadata) do
    case {
      Map.fetch(metadata, "credential_descriptor"),
      Map.fetch(metadata, "auth_method")
    } do
      {{:ok, "package_manifest.v1"}, {:ok, auth_method}}
      when is_binary(auth_method) and auth_method != "" ->
        {:ok, auth_method}

      {:error, :error} ->
        infer_legacy_auth_method(secret, profile)

      _partial_or_stale ->
        {:error, :credential_descriptor_unavailable}
    end
  end

  defp rotation_auth_method(_secret, _profile), do: {:error, :credential_descriptor_unavailable}

  defp infer_legacy_auth_method(%{credential_kind: stored_kind}, %{"auth_methods" => auth_methods})
       when is_list(auth_methods) do
    matching_methods =
      Enum.filter(auth_methods, fn method ->
        is_map(method) and credential_kind(method["credential_kind"]) == {:ok, stored_kind}
      end)

    case matching_methods do
      [%{"id" => auth_method}] when is_binary(auth_method) and auth_method != "" ->
        {:ok, auth_method}

      [] ->
        {:error, :credential_descriptor_unavailable}

      [_first, _second | _rest] ->
        {:error, :credential_auth_method_ambiguous}

      _invalid_method ->
        {:error, :credential_descriptor_unavailable}
    end
  end

  defp infer_legacy_auth_method(_secret, _profile),
    do: {:error, :credential_descriptor_unavailable}

  defp validate_rotation_provider(%{provider: provider}, %{"provider" => provider})
       when is_binary(provider), do: :ok

  defp validate_rotation_provider(_secret, _profile), do: {:error, :credential_provider_mismatch}

  defp validate_rotation_kind(%{credential_kind: credential_kind}, credential_kind), do: :ok

  defp validate_rotation_kind(_secret, _method_kind), do: {:error, :credential_kind_mismatch}

  defp find_method(profile, auth_method) do
    Enum.find(profile["auth_methods"] || [], &(&1["id"] == auth_method))
  end

  defp validate_values(method, values) do
    fields = method["fields"] || []
    fields_by_id = Map.new(fields, &{&1["id"], &1})

    if Enum.any?(Map.keys(values), &(not Map.has_key?(fields_by_id, to_string(&1)))) do
      {:error, :undeclared_credential_field}
    else
      Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
        id = field["id"]
        value = Map.get(values, id, "")

        cond do
          not is_binary(value) ->
            {:halt, {:error, {:invalid_credential_field, id}}}

          field["required"] and String.trim(value) == "" ->
            {:halt, {:error, {:missing_credential_field, id}}}

          byte_size(value) < (field["min_length"] || 0) ->
            {:halt, {:error, {:invalid_credential_field, id}}}

          byte_size(value) > (field["max_length"] || 16_384) ->
            {:halt, {:error, {:invalid_credential_field, id}}}

          value == "" ->
            {:cont, {:ok, acc}}

          true ->
            {:cont, {:ok, Map.put(acc, id, value)}}
        end
      end)
    end
  end

  defp encode_payload(method, values) do
    case method["payload"] || %{"format" => "json"} do
      %{"format" => "scalar", "field" => field} ->
        required_payload_value(values, field)

      %{"format" => "template", "template" => template} ->
        render_payload_template(template, values)

      %{"format" => "json"} ->
        Jason.encode(values)

      _ ->
        {:error, :invalid_credential_payload_encoding}
    end
  end

  defp required_payload_value(values, field) do
    case Map.get(values, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_credential_field, field}}
    end
  end

  defp render_payload_template(template, values) when is_binary(template) do
    placeholders = Regex.scan(~r/\{\{([a-z0-9_.-]+)\}\}/, template, capture: :all_but_first)

    Enum.reduce_while(placeholders, {:ok, template}, fn [field], {:ok, rendered} ->
      case Map.get(values, field) do
        value when is_binary(value) and value != "" ->
          {:cont, {:ok, String.replace(rendered, "{{#{field}}}", value)}}

        _ ->
          {:halt, {:error, {:missing_credential_field, field}}}
      end
    end)
  end

  defp render_payload_template(_template, _values),
    do: {:error, :invalid_credential_payload_encoding}

  defp public_username(method, values) do
    username_field =
      get_in(method, ["payload", "username_field"]) ||
        Enum.find_value(method["fields"] || [], fn field ->
          if field["public"], do: field["id"]
        end)

    case Map.get(values, username_field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          username -> username
        end

      _ ->
        nil
    end
  end

  defp credential_kind(kind) do
    case Map.fetch(@credential_kinds, kind) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :unsupported_credential_kind}
    end
  end

  defp public_fingerprint(:ssh_private_key, method, values, _payload) do
    private_key =
      method
      |> Map.get("fields", [])
      |> Enum.filter(& &1["secret"])
      |> Enum.find_value(fn field ->
        case Map.get(values, field["id"]) do
          value when is_binary(value) -> if ssh_private_key?(value), do: value
          _value -> nil
        end
      end)

    case private_key do
      value when is_binary(value) -> {:ok, SshPrivateKeyCredential.fingerprint(value)}
      _missing -> {:error, :invalid_private_key}
    end
  end

  defp public_fingerprint(_credential_kind, _method, _values, payload),
    do: {:ok, fingerprint(payload)}

  defp ssh_private_key?(value) when is_binary(value) do
    String.contains?(value, "-----BEGIN ") and String.contains?(value, " PRIVATE KEY-----")
  end

  defp ssh_private_key?(_value), do: false

  defp fingerprint(payload) do
    digest = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
    "sha256:" <> digest
  end
end
