defmodule ServiceRadar.Observability.ServiceStateRegistry.PluginStateContract do
  @moduledoc false

  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginStateRank

  @pending_message "plugin assignment pending result"
  @streaming_ready_message "streaming plugin ready"
  @reported_marker "_serviceradar_plugin_result"

  @doc false
  def logical_identity(identity) when is_map(identity) do
    %{
      agent_id: normalize_string(fetch(identity, :agent_id), "unknown"),
      partition:
        normalize_string(fetch(identity, :partition) || fetch(identity, :partition_id), "default"),
      service_type: normalize_string(fetch(identity, :service_type), "plugin"),
      service_name: normalize_string(fetch(identity, :service_name), "unknown")
    }
  end

  @doc false
  def status_identity(identity) when is_map(identity) do
    identity
    |> logical_identity()
    |> Map.put(:gateway_id, normalize_string(fetch(identity, :gateway_id), "unknown"))
  end

  @doc false
  defdelegate state_rank(state), to: PluginStateRank

  @doc false
  defdelegate snapshot_rank(snapshot), to: PluginStateRank

  @doc false
  defdelegate compare_snapshots(left, right), to: PluginStateRank

  @doc false
  defdelegate same_logical_observation?(left, right), to: PluginStateRank

  @doc false
  defdelegate placeholder_state?(state), to: PluginStateRank

  @doc false
  defdelegate details_payload_digest(details), to: PluginStateRank

  @doc false
  defdelegate snapshot_payload_digest(snapshot), to: PluginStateRank

  @doc false
  defdelegate details_logical_observed_at(details, fallback), to: PluginStateRank

  @doc false
  defdelegate snapshot_logical_observed_at(snapshot), to: PluginStateRank

  @doc false
  def state_winner_order_sql do
    winner_order_sql(
      "service_state.message",
      logical_observed_at_sql("service_state.details", "service_state.last_observed_at"),
      "service_state.available",
      "service_state.gateway_id",
      payload_order_key_sql("service_state.details", "service_state.message")
    )
  end

  @doc false
  def history_normalized_fields_sql do
    """
    #{logical_observed_at_sql("service_status.details", "service_status.timestamp")} AS logical_observed_at,
    #{payload_lineage_sql("service_status.details")} AS payload_lineage,
    #{payload_digest_sql("service_status.details")} AS payload_digest,
    #{payload_order_key_sql("service_status.details", "service_status.message")} AS payload_order_key,
    #{history_record_kind_rank_sql()} AS record_kind_rank,
    #{history_handler_generation_sql()} AS handler_generation
    """
  end

  @doc false
  def history_payload_winner_order_sql do
    """
    normalized.record_kind_rank DESC,
    normalized.handler_generation DESC,
    CASE
      WHEN normalized.record_kind_rank < 2 AND normalized.available = false THEN 1
      ELSE 0
    END DESC,
    normalized.timestamp DESC
    """
  end

  @doc false
  def history_logical_winner_order_sql do
    """
    #{winner_order_sql("payload_winner.message",
    "payload_winner.logical_observed_at",
    "payload_winner.available",
    "payload_winner.gateway_id",
    "payload_winner.payload_order_key")},
    payload_winner.record_kind_rank DESC,
    payload_winner.handler_generation DESC,
    payload_winner.timestamp DESC
    """
  end

  @doc false
  def trusted_reported_marker_sql do
    expected_service_id =
      service_identity_sql(
        "service_status.agent_id",
        "service_status.gateway_id",
        "service_status.partition",
        "service_status.service_type",
        "service_status.service_name"
      )

    verified_service_id =
      "CASE WHEN service_status.service_id = #{expected_service_id} " <>
        "THEN service_status.service_id END"

    PluginResultReportedMarker.trusted_sql(
      "service_status.details",
      "service_status.timestamp",
      verified_service_id
    )
  end

  @doc false
  def state_matches_package_sql(:package_params) do
    state_matches_package_sql("$1", "$2")
  end

  def state_matches_package_sql(:agent_package_params) do
    state_matches_package_sql("$2", "$3")
  end

  @doc false
  def state_matches_joined_package_sql do
    state_matches_package_sql("package.name", "package.plugin_id")
  end

  @doc false
  def status_matches_joined_package_sql do
    package_match_sql(
      "service_status.details",
      "service_status.service_name",
      "package.name",
      "package.plugin_id"
    )
  end

  @doc false
  def package_match_sql(details, service_name, package_name, plugin_id) do
    extracted_plugin_id = extracted_plugin_id_sql(details)

    """
    CASE
      WHEN #{details} IS JSON AND NULLIF(#{extracted_plugin_id}, '') IS NOT NULL
      THEN #{extracted_plugin_id} = #{plugin_id}
      ELSE #{service_name} = #{package_name}
    END
    """
  end

  @doc false
  def package_matches_state?(state, package_name, plugin_id) when is_map(state) do
    case state_plugin_id(state) do
      nil ->
        normalize_optional_string(fetch(state, :service_name)) ==
          normalize_optional_string(package_name)

      state_plugin_id ->
        state_plugin_id == normalize_optional_string(plugin_id)
    end
  end

  @doc false
  def state_plugin_id(state) when is_map(state) do
    state
    |> fetch(:details)
    |> decode_details()
    |> plugin_id_from_details()
  end

  defp winner_order_sql(message, observed_at, available, gateway_id, payload_order_key) do
    """
    CASE
      WHEN #{message} IN ('#{@pending_message}', '#{@streaming_ready_message}') THEN 0
      ELSE 1
    END DESC,
    #{observed_at} DESC,
    CASE WHEN #{available} = false THEN 1 ELSE 0 END DESC,
    COALESCE(#{gateway_id}, '') COLLATE "C" DESC,
    COALESCE(#{payload_order_key}, '') COLLATE "C" DESC
    """
  end

  defp logical_observed_at_sql(details, fallback_timestamp) do
    """
    CASE
      WHEN #{server_reported_marker_sql(details)} THEN
        COALESCE(
          NULLIF(#{details}::jsonb #>> '{#{@reported_marker},observation_timestamp}', '')::timestamptz,
          #{fallback_timestamp}
        )
      WHEN #{server_downstream_marker_sql(details)} THEN
        COALESCE(
          NULLIF(#{details}::jsonb #>> '{downstream_ingest,observation_timestamp}', '')::timestamptz,
          #{fallback_timestamp}
        )
      ELSE #{fallback_timestamp}
    END
    """
  end

  defp payload_digest_sql(details) do
    """
    CASE
      WHEN #{server_reported_marker_sql(details)} THEN
        COALESCE(
          NULLIF(#{details}::jsonb #>> '{#{@reported_marker},payload_digest}', ''),
          encode(
            digest(convert_to((#{details}::jsonb - '#{@reported_marker}')::text, 'UTF8'), 'sha256'),
            'hex'
          )
        )
      WHEN #{server_downstream_marker_sql(details)} THEN
        COALESCE(
          NULLIF(#{details}::jsonb #>> '{downstream_ingest,payload_digest}', ''),
          encode(
            digest(
              convert_to((#{details}::jsonb -> 'reported_result')::text, 'UTF8'),
              'sha256'
            ),
            'hex'
          )
        )
      ELSE ''
    END
    """
  end

  defp payload_order_key_sql(details, message) do
    """
    CASE
      WHEN #{server_reported_marker_sql(details)}
        AND NULLIF(#{details}::jsonb #>> '{#{@reported_marker},payload_digest}', '') IS NOT NULL
      THEN '1:' || (#{details}::jsonb #>> '{#{@reported_marker},payload_digest}')
      WHEN #{server_downstream_marker_sql(details)}
        AND NULLIF(#{details}::jsonb #>> '{downstream_ingest,payload_digest}', '') IS NOT NULL
      THEN '1:' || (#{details}::jsonb #>> '{downstream_ingest,payload_digest}')
      ELSE '0:' || COALESCE(#{message}, '')
    END
    """
  end

  defp payload_lineage_sql(details) do
    """
    CASE
      WHEN #{server_reported_marker_sql(details)}
      THEN #{details}::jsonb - '#{@reported_marker}'
      WHEN #{server_downstream_marker_sql(details)}
      THEN #{details}::jsonb -> 'reported_result'
      WHEN #{details} IS JSON
      THEN #{details}::jsonb
      ELSE to_jsonb(#{details})
    END
    """
  end

  defp history_record_kind_rank_sql do
    """
    CASE
      WHEN #{server_reported_marker_sql("service_status.details")} THEN 1
      WHEN #{server_downstream_marker_sql("service_status.details")} THEN 2
      ELSE 0
    END
    """
  end

  defp history_handler_generation_sql do
    """
    CASE
      WHEN #{server_downstream_marker_sql("service_status.details")}
      THEN (service_status.details::jsonb #>> '{downstream_ingest,generation}')::bigint
      ELSE 0
    END
    """
  end

  defp server_reported_marker_sql("service_status.details"), do: trusted_reported_marker_sql()

  defp server_reported_marker_sql("service_state.details") do
    expected_service_id =
      service_identity_sql(
        "service_state.agent_id",
        "service_state.gateway_id",
        "service_state.partition",
        "service_state.service_type",
        "service_state.service_name"
      )

    PluginResultReportedMarker.trusted_sql(
      "service_state.details",
      "service_state.last_observed_at",
      expected_service_id
    )
  end

  defp server_reported_marker_sql(_details), do: "FALSE"

  defp service_identity_sql(agent_id, gateway_id, partition, service_type, service_name) do
    normalized = fn expression, fallback ->
      "COALESCE(NULLIF(btrim(#{expression}), ''), '#{fallback}')"
    end

    seed =
      "'serviceradar-service-v1:agent:' || #{normalized.(agent_id, "unknown")} || " <>
        "'|gateway:' || #{normalized.(gateway_id, "unknown")} || " <>
        "'|partition:' || #{normalized.(partition, "default")} || " <>
        "'|type:' || #{normalized.(service_type, "unknown")} || " <>
        "'|name:' || #{normalized.(service_name, "unknown")}"

    hash = "digest(convert_to(#{seed}, 'UTF8'), 'sha256')"
    bytes = "substring(#{hash} FROM 1 FOR 16)"

    versioned =
      "set_byte(set_byte(#{bytes}, 6, (get_byte(#{bytes}, 6) & 15) | 80), " <>
        "8, (get_byte(#{bytes}, 8) & 63) | 128)"

    hex = "encode(#{versioned}, 'hex')"

    "(substring(#{hex} FROM 1 FOR 8) || '-' || " <>
      "substring(#{hex} FROM 9 FOR 4) || '-' || " <>
      "substring(#{hex} FROM 13 FOR 4) || '-' || " <>
      "substring(#{hex} FROM 17 FOR 4) || '-' || " <>
      "substring(#{hex} FROM 21 FOR 12))::uuid"
  end

  defp server_downstream_marker_sql(details) do
    """
    (
      #{details} IS JSON
      AND #{details}::jsonb ? 'reported_result'
      AND #{details}::jsonb #>> '{downstream_ingest,status}' IN ('failed', 'succeeded')
      AND #{details}::jsonb #>> '{downstream_ingest,generation}' ~ '^[0-9]{1,3}$'
      AND (#{details}::jsonb #>> '{downstream_ingest,generation}')::integer BETWEEN 1 AND 128
      AND #{details}::jsonb #>> '{downstream_ingest,handler_set,version}' = '1'
      AND NULLIF(#{details}::jsonb #>> '{downstream_ingest,handler_set,id}', '') IS NOT NULL
      AND #{details}::jsonb #>> '{downstream_ingest,observation_timestamp}'
        ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$'
    )
    """
  end

  defp state_matches_package_sql(package_name, plugin_id) do
    package_match_sql(
      "service_state.details",
      "service_state.service_name",
      package_name,
      plugin_id
    )
  end

  defp extracted_plugin_id_sql(details) do
    """
    COALESCE(
      #{details}::jsonb #>> '{labels,plugin_id}',
      #{details}::jsonb ->> 'plugin_id',
      #{details}::jsonb #>> '{reported_result,labels,plugin_id}',
      #{details}::jsonb #>> '{reported_result,plugin_id}'
    )
    """
  end

  defp decode_details(details) when is_map(details), do: details

  defp decode_details(details) when is_binary(details) do
    case Jason.decode(details) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_details(_details), do: %{}

  defp plugin_id_from_details(details) do
    reported_result = fetch(details, :reported_result) || %{}

    Enum.find_value(
      [
        details |> fetch(:labels) |> fetch_nested(:plugin_id),
        fetch(details, :plugin_id),
        reported_result |> fetch(:labels) |> fetch_nested(:plugin_id),
        fetch(reported_result, :plugin_id)
      ],
      &normalize_optional_string/1
    )
  end

  defp fetch_nested(map, key) when is_map(map), do: fetch(map, key)
  defp fetch_nested(_value, _key), do: nil

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_value, _key), do: nil

  defp normalize_string(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      normalized -> normalized
    end
  end

  defp normalize_string(_value, fallback), do: fallback

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil
end
