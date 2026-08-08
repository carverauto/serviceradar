defmodule ServiceRadar.Credentials.RuleAccessors do
  @moduledoc """
  Pure accessors for reading fields and metadata off a network credential rule.

  Accessors normalize persisted Ash structs and plain test maps without
  interpreting provider-specific identifiers. Provider names, auth methods,
  and purposes come from approved plugin package descriptors.
  """

  alias ServiceRadar.Plugins.ValueUtils

  @spec value_string(map(), list()) :: String.t() | nil
  def value_string(map, keys), do: ValueUtils.string_value(map, keys)

  @spec metadata(map()) :: map()
  def metadata(rule) do
    ValueUtils.map_value(rule, [:metadata, "metadata"], stringify_keys: true) || %{}
  end

  @spec metadata_int(map(), String.t(), integer()) :: integer()
  def metadata_int(rule, key, default) do
    rule
    |> metadata()
    |> ValueUtils.int_value([key, metadata_atom_key(key)], default)
  end

  @spec metadata_bool(map(), String.t(), boolean()) :: boolean()
  def metadata_bool(rule, key, default) do
    metadata = metadata(rule)

    cond do
      is_boolean(Map.get(metadata, key)) ->
        Map.get(metadata, key)

      is_boolean(Map.get(metadata, metadata_atom_key(key))) ->
        Map.get(metadata, metadata_atom_key(key))

      true ->
        default
    end
  end

  @spec metadata_string(map(), String.t(), String.t()) :: String.t()
  def metadata_string(rule, key, default) do
    case value_string(metadata(rule), [key, metadata_atom_key(key)]) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  @spec tls_policy(map()) :: :skip_verify | :verify
  def tls_policy(rule) do
    case value_string(rule, [:tls_policy, "tls_policy"]) do
      "skip_verify" -> :skip_verify
      _ -> :verify
    end
  end

  @spec ssh_host_key_policy(map()) :: String.t()
  def ssh_host_key_policy(rule) do
    case value_string(rule, [:ssh_host_key_policy, "ssh_host_key_policy"]) do
      "trust_on_first_use" -> "trust_on_first_use"
      "skip_verify" -> "skip_verify"
      _ -> "known_hosts"
    end
  end

  @spec auth_method(map()) :: String.t() | nil
  def auth_method(rule), do: value_string(rule, [:auth_method, "auth_method"])

  @spec rule_purpose(map()) :: String.t() | nil
  def rule_purpose(rule), do: value_string(rule, [:purpose, "purpose"])

  @spec rule_purposes(map()) :: [String.t()]
  def rule_purposes(rule) do
    metadata_purposes =
      rule
      |> metadata()
      |> ValueUtils.list_value(["purposes", :purposes])
      |> nil_to_empty_list()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    if metadata_purposes == [] do
      List.wrap(rule_purpose(rule))
    else
      metadata_purposes
    end
  end

  defp nil_to_empty_list(nil), do: []
  defp nil_to_empty_list(value), do: value

  defp metadata_atom_key("chunk_size"), do: :chunk_size
  defp metadata_atom_key("auto_discovery_enabled"), do: :auto_discovery_enabled
  defp metadata_atom_key("gateway_id"), do: :gateway_id
  defp metadata_atom_key("include_guests"), do: :include_guests
  defp metadata_atom_key("interval_seconds"), do: :interval_seconds
  defp metadata_atom_key("partition_id"), do: :partition_id
  defp metadata_atom_key("credential_broker_ttl_seconds"), do: :credential_broker_ttl_seconds
  defp metadata_atom_key("timeout_ms"), do: :timeout_ms
  defp metadata_atom_key("timeout_seconds"), do: :timeout_seconds
  defp metadata_atom_key("scheme"), do: :scheme
  defp metadata_atom_key("host"), do: :host
  defp metadata_atom_key("controller_host"), do: :controller_host
  defp metadata_atom_key("static_host"), do: :static_host
  defp metadata_atom_key("rtsp_port"), do: :rtsp_port
  defp metadata_atom_key("bootstrap_path"), do: :bootstrap_path
  defp metadata_atom_key("login_path"), do: :login_path
  defp metadata_atom_key("schedule_enabled"), do: :schedule_enabled
  defp metadata_atom_key("cadence_seconds"), do: :cadence_seconds
end
