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
