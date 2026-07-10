defmodule ServiceRadar.Integrations.SyncConfigGenerator do
  @moduledoc """
  Builds sync configuration payloads for agents from IntegrationSource data.

  Schema isolation is handled by the database connection's search_path.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource

  require Ash.Query
  require Logger

  @default_heartbeat_interval_sec 30
  @default_config_poll_interval_sec 300
  @armis_sync_setting_keys [
    "api_version",
    "armis_api_version",
    "asset_fields",
    "armis_asset_fields",
    "attachment_fields",
    "extra_metadata_fields",
    "armis_extra_metadata_fields",
    "v3_endpoint",
    "armis_v3_endpoint",
    "v3_scopes",
    "armis_v3_scopes"
  ]

  @spec get_config_if_changed(String.t(), String.t()) ::
          :not_modified | {:ok, map()} | {:error, term()}
  def get_config_if_changed(agent_id, config_version) do
    case build_payload(agent_id) do
      {:ok, payload} ->
        encoded = Jason.encode!(payload)
        version = hash_config(payload)

        if version == config_version do
          :not_modified
        else
          {:ok,
           %{
             config_version: version,
             config_timestamp: System.os_time(:second),
             heartbeat_interval_sec: @default_heartbeat_interval_sec,
             config_poll_interval_sec: @default_config_poll_interval_sec,
             config_json: encoded
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_payload(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_payload(agent_id, opts \\ []) do
    with {:ok, sources} <- load_sources(agent_id),
         {:ok, sources_payload} <- build_sources_payload(sources, agent_id, opts) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "sources" => sources_payload
       }}
    end
  end

  defp load_sources(agent_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:sync_config_generator)

    include_unassigned? = agent_id == auto_assigned_agent_id(actor)

    # Include sources assigned to this specific agent. Unassigned sources are
    # auto-assigned to a single stable connected agent so embedded sync runtimes
    # do not all run the same external integration.
    # Load credentials_encrypted first (so AshCloak can decrypt it), then the credentials calculation
    query =
      IntegrationSource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> filter_sources_for_agent(agent_id, include_unassigned?)
      |> Ash.Query.load([:credentials_encrypted, :credentials])
      |> Ash.Query.sort(name: :asc)

    case Ash.read(query, actor: actor) do
      {:ok, sources} -> {:ok, sources}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filter_sources_for_agent(query, agent_id, true) do
    Ash.Query.filter(query, enabled == true and (agent_id == ^agent_id or is_nil(agent_id)))
  end

  defp filter_sources_for_agent(query, agent_id, false) do
    Ash.Query.filter(query, enabled == true and agent_id == ^agent_id)
  end

  defp auto_assigned_agent_id(actor) do
    case Agent.list_connected(actor: actor) do
      {:ok, agents} ->
        agents
        |> Enum.map(& &1.uid)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> List.first()

      {:error, _reason} ->
        nil
    end
  end

  defp build_sources_payload(sources, agent_id, opts) do
    Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, acc} ->
      case source_payload(source, agent_id, opts) do
        {:ok, payload} ->
          source_key = source.name || to_string(source.id)
          {:cont, {:ok, Map.put(acc, source_key, payload)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp source_payload(source, agent_id, opts) do
    with {:ok, raw_credentials} <- resolve_credentials(source, agent_id, opts) do
      credentials = normalize_credentials(raw_credentials, source.source_type)
      credentials = put_optional(credentials, "page_size", source.page_size)
      source_type = source.source_type && Atom.to_string(source.source_type)
      prefix = if source_type, do: "#{source_type}/"

      {:ok,
       compact_map(%{
         "type" => source_type,
         "endpoint" => source.endpoint,
         "prefix" => prefix,
         "credentials" => credentials,
         "settings" => source_settings_payload(source.settings, source.source_type),
         "queries" => normalize_queries(source.queries),
         "discovery_interval" => format_duration(source.discovery_interval_seconds),
         "agent_id" => source.agent_id,
         "partition" => source.partition,
         "network_blacklist" => source.network_blacklist,
         "custom_field" => first_custom_field(source.custom_fields),
         "batch_size" => get_setting(source.settings, "batch_size"),
         "insecure_skip_verify" => get_setting(source.settings, "insecure_skip_verify"),
         "sync_service_id" => to_string(source.id)
       })}
    end
  end

  defp resolve_credentials(%{credential_secret_id: secret_id} = source, agent_id, opts)
       when is_binary(secret_id) and secret_id != "" do
    actor = SystemActor.system(:sync_config_generator_credential_broker)

    broker_opts =
      maybe_put_audit_sink(
        [
          actor: actor,
          audit?: true,
          allow_external_resolution?: false,
          consumer_kind: :discovery,
          consumer_id: "integration_source:#{source.id}",
          purpose: "integration_source_credentials",
          target_kind: "integration_source",
          target_id: to_string(source.id),
          agent_id: agent_id,
          resolution_location: :control_plane
        ],
        opts
      )

    with {:ok, %{value: payload}} <-
           SecretBroker.resolve_network_credential_secret(secret_id, broker_opts),
         {:ok, credentials} <- decode_broker_credentials(payload) do
      {:ok, credentials}
    else
      {:error, reason} ->
        Logger.warning(
          "SyncConfigGenerator: failed to resolve broker credential #{secret_id} - #{inspect(reason)}"
        )

        {:error, {:credential_resolution_failed, to_string(source.id), reason}}
    end
  end

  defp resolve_credentials(source, _agent_id, _opts), do: {:ok, source.credentials || %{}}

  defp maybe_put_audit_sink(broker_opts, opts) do
    case Keyword.get(opts, :audit_sink) do
      sink when is_function(sink, 1) -> Keyword.put(broker_opts, :audit_sink, sink)
      _ -> broker_opts
    end
  end

  defp decode_broker_credentials(payload) when is_binary(payload) do
    case Jason.decode(String.trim(payload)) do
      {:ok, credentials} when is_map(credentials) and map_size(credentials) > 0 ->
        {:ok, credentials}

      _ ->
        {:error, :invalid_credentials_payload}
    end
  end

  defp decode_broker_credentials(_payload), do: {:error, :invalid_credentials_payload}

  defp first_custom_field(fields) when is_list(fields) do
    case fields do
      [value | _] -> value
      _ -> nil
    end
  end

  defp first_custom_field(_), do: nil

  defp source_settings_payload(settings, :armis) when is_map(settings) do
    settings
    |> stringify_setting_keys()
    |> Map.take(@armis_sync_setting_keys)
    |> normalize_setting_values()
    |> compact_map()
  end

  defp source_settings_payload(_, _), do: %{}

  defp normalize_credentials(credentials, :armis) when is_map(credentials) do
    credentials
    |> normalize_credentials()
    |> normalize_armis_credentials()
  end

  defp normalize_credentials(credentials, _source_type), do: normalize_credentials(credentials)

  defp normalize_credentials(credentials) when is_map(credentials) do
    credentials
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new(fn {key, value} ->
      {to_string(key), to_string(value)}
    end)
  end

  defp normalize_credentials(_), do: %{}

  defp normalize_armis_credentials(credentials) do
    case first_present(credentials, ["secret_key", "api_secret"]) do
      nil -> credentials
      secret_key -> Map.put(credentials, "secret_key", secret_key)
    end
  end

  defp normalize_queries(queries) when is_list(queries) do
    queries
    |> Enum.map(&normalize_query/1)
    |> Enum.reject(fn query -> query["query"] == "" end)
  end

  defp normalize_queries(_), do: []

  defp normalize_query(query) when is_map(query) do
    %{
      "label" => query_value(query, "label"),
      "query" => query_value(query, "query"),
      "sweep_modes" => query_modes(query)
    }
  end

  defp normalize_query(_), do: %{"label" => "", "query" => "", "sweep_modes" => []}

  defp query_value(query, key) do
    atom_key =
      case key do
        "label" -> :label
        "query" -> :query
      end

    value = Map.get(query, key) || Map.get(query, atom_key) || ""

    value
    |> to_string()
    |> String.trim()
  end

  defp query_modes(query) do
    case Map.get(query, "sweep_modes") || Map.get(query, :sweep_modes) do
      modes when is_list(modes) -> modes
      _ -> []
    end
  end

  defp stringify_setting_keys(settings) do
    Map.new(settings, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_setting_values(settings) do
    Map.new(settings, fn {key, value} -> {key, normalize_setting_value(value)} end)
  end

  defp normalize_setting_value(values) when is_list(values) do
    values
    |> Enum.map(&normalize_setting_value/1)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp normalize_setting_value(%{} = map) do
    map
    |> stringify_setting_keys()
    |> normalize_setting_values()
    |> compact_map()
  end

  defp normalize_setting_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_setting_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_setting_value(value), do: value

  defp first_present(credentials, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(credentials, key) do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        _ ->
          nil
      end
    end)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map

  defp put_optional(map, key, value) do
    Map.put(map, key, to_string(value))
  end

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      rem(seconds, 3600) == 0 -> "#{div(seconds, 3600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  defp format_duration(_), do: ""

  defp hash_config(config) do
    canonical =
      config
      |> canonicalize_for_hash()
      |> Jason.encode!()

    :sha256
    |> :crypto.hash(canonical)
    |> Base.encode16(case: :lower)
  end

  defp canonicalize_for_hash(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> [to_string(key), canonicalize_for_hash(value)] end)
    |> Enum.sort_by(fn [key, _value] -> key end)
  end

  defp canonicalize_for_hash(list) when is_list(list) do
    Enum.map(list, &canonicalize_for_hash/1)
  end

  defp canonicalize_for_hash(other), do: other

  defp compact_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, %{} = value} -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp get_setting(nil, _key), do: nil

  defp get_setting(settings, key) when is_map(settings) do
    Map.get(settings, key) || Map.get(settings, String.to_atom(key))
  end

  defp get_setting(_, _key), do: nil
end
