defmodule ServiceRadar.Automation.Northbound.ActionRedaction do
  @moduledoc """
  Redaction helpers for persisted northbound action inputs and results.

  The action invocation table may retain raw `input_values` for dispatch, but
  public fields, audit versions, and result summaries must only expose redacted
  values. This module combines explicit JSON-schema hints with conservative key
  name matching so new providers get safe defaults.
  """

  @policy_version "northbound-action-redaction-v1"
  @redacted "[REDACTED]"
  @sensitive_formats ~w[password secret private-key api-key bearer-token]
  @sensitive_key_fragments ~w[
    api_key
    apikey
    auth
    authorization
    bearer
    client_secret
    cookie
    credential
    credentials
    password
    passwd
    passphrase
    private_key
    refresh_token
    secret
    session
    token
  ]

  @type redaction_result :: %{
          redacted: term(),
          sha256: String.t() | nil,
          policy_version: String.t()
        }

  @spec policy_version() :: String.t()
  def policy_version, do: @policy_version

  @spec redact(term(), map() | nil) :: term()
  def redact(value, schema \\ nil), do: redact_value(value, normalize_schema(schema), nil)

  @spec for_storage(term(), map() | nil) :: redaction_result()
  def for_storage(value, schema \\ nil) do
    %{
      redacted: redact(value, schema),
      sha256: sha256(value),
      policy_version: @policy_version
    }
  end

  defp redact_value(value, _schema, key) when is_binary(key) do
    if sensitive_key?(key), do: @redacted, else: redact_by_type(value, nil)
  end

  defp redact_value(value, schema, _key) do
    if sensitive_schema?(schema), do: @redacted, else: redact_by_type(value, schema)
  end

  defp redact_by_type(%{} = value, schema) do
    properties = schema_properties(schema)

    Map.new(value, fn {key, child} ->
      key_string = to_string(key)
      child_schema = Map.get(properties, key_string) || Map.get(properties, key)
      {key, redact_value(child, child_schema, key_string)}
    end)
  end

  defp redact_by_type(value, schema) when is_list(value) do
    item_schema = schema_items(schema)
    Enum.map(value, &redact_value(&1, item_schema, nil))
  end

  defp redact_by_type(value, _schema), do: value

  defp sensitive_schema?(nil), do: false

  defp sensitive_schema?(schema) when is_map(schema) do
    truthy?(Map.get(schema, "writeOnly") || Map.get(schema, :writeOnly)) ||
      truthy?(Map.get(schema, "sensitive") || Map.get(schema, :sensitive)) ||
      truthy?(Map.get(schema, "x-sensitive") || Map.get(schema, :"x-sensitive")) ||
      truthy?(
        Map.get(schema, "x-serviceradar-sensitive") ||
          Map.get(schema, :"x-serviceradar-sensitive")
      ) ||
      truthy?(
        Map.get(schema, "x-serviceradar-redact") || Map.get(schema, :"x-serviceradar-redact")
      ) ||
      sensitive_format?(Map.get(schema, "format") || Map.get(schema, :format))
  end

  defp sensitive_schema?(_schema), do: false

  defp schema_properties(schema) when is_map(schema) do
    case Map.get(schema, "properties") || Map.get(schema, :properties) do
      %{} = properties -> properties
      _ -> %{}
    end
  end

  defp schema_properties(_schema), do: %{}

  defp schema_items(schema) when is_map(schema) do
    case Map.get(schema, "items") || Map.get(schema, :items) do
      %{} = items -> items
      _ -> nil
    end
  end

  defp schema_items(_schema), do: nil

  defp normalize_schema(%{} = schema), do: schema
  defp normalize_schema(_schema), do: nil

  defp sensitive_format?(format) when is_binary(format) do
    String.downcase(format) in @sensitive_formats
  end

  defp sensitive_format?(format) when is_atom(format),
    do: sensitive_format?(Atom.to_string(format))

  defp sensitive_format?(_format), do: false

  defp sensitive_key?(key) when is_binary(key) do
    normalized =
      key
      |> Macro.underscore()
      |> String.downcase()

    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp sha256(value) do
    value
    |> canonicalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
