defmodule ServiceRadar.ColdTier.Registry do
  @moduledoc """
  Single source of truth for tables that participate in the tiered telemetry
  cold-storage path (OpenSpec change: add-tiered-telemetry-offload).

  Every cold-tier surface derives from this registry: the chunk exporter's
  column lists and canonical casts, the offload-gated retention fence, the
  analytics-head view generation, storage/retention telemetry, and (M2) SRQL
  cold-eligibility. Adding a table here is the only wiring step; schema
  migrations that alter a registry table must update its entry in the same
  change (enforced by the registry drift test).

  The registry is pure data. Whether the cold tier is *active* is a
  deployment decision keyed off runtime configuration (see `enabled?/0`);
  when the configuration is absent every consumer of this module must behave
  exactly as it did before the cold tier existed.
  """

  alias ServiceRadar.ColdTier.Registry.Table

  @schema "platform"
  @layout_version "v1"

  # Column tuples are {name, postgres_type, export_cast}. Casts are canonical
  # per design D2/R7: uuid and jsonb are exported as text (parquet has neither;
  # jsonb operator semantics are re-mapped on the cold read path), arrays stay
  # native (parquet LIST), everything else exports as-is. timestamptz lands in
  # parquet as UTC TIMESTAMP (µs).
  @tables [
    %Table{
      table: "logs",
      time_column: "timestamp",
      signal_class: :logs,
      retention_config_key: :logs_retention_days,
      default_hot_days: 30,
      chunk_interval_key: :logs_chunk_interval_hours,
      default_chunk_hours: 6,
      update_prone: false,
      tiebreakers: ["id"],
      columns: [
        {"timestamp", "timestamptz", :none},
        {"id", "uuid", :text},
        {"trace_id", "text", :none},
        {"span_id", "text", :none},
        {"severity_text", "text", :none},
        {"severity_number", "integer", :none},
        {"body", "text", :none},
        {"service_name", "text", :none},
        {"service_version", "text", :none},
        {"service_instance", "text", :none},
        {"scope_name", "text", :none},
        {"scope_version", "text", :none},
        {"attributes", "text", :none},
        {"resource_attributes", "text", :none},
        {"created_at", "timestamptz", :none},
        {"observed_timestamp", "timestamptz", :none},
        {"trace_flags", "integer", :none},
        {"event_name", "text", :none},
        {"scope_attributes", "text", :none},
        {"source", "text", :none},
        {"ingest_identity", "text", :none},
        {"ingest_agent_id", "text", :none},
        {"ingest_partition", "text", :none},
        # Added by 20260715120000_add_logs_source_ip, i.e. after this registry was
        # first written, so it is physically last. Caught by RegistryDriftTest --
        # without it the cold tier would export `logs` minus this column.
        {"source_ip", "text", :none}
      ]
    },
    %Table{
      table: "otel_traces",
      time_column: "timestamp",
      signal_class: :traces,
      retention_config_key: :otel_traces_retention_days,
      default_hot_days: 3,
      chunk_interval_key: :otel_traces_chunk_interval_hours,
      default_chunk_hours: 1,
      update_prone: false,
      tiebreakers: ["trace_id", "span_id"],
      columns: [
        {"timestamp", "timestamptz", :none},
        {"trace_id", "text", :none},
        {"span_id", "text", :none},
        {"parent_span_id", "text", :none},
        {"name", "text", :none},
        {"kind", "integer", :none},
        {"start_time_unix_nano", "bigint", :none},
        {"end_time_unix_nano", "bigint", :none},
        {"service_name", "text", :none},
        {"service_version", "text", :none},
        {"service_instance", "text", :none},
        {"scope_name", "text", :none},
        {"scope_version", "text", :none},
        {"status_code", "integer", :none},
        {"status_message", "text", :none},
        {"attributes", "text", :none},
        {"resource_attributes", "text", :none},
        {"events", "text", :none},
        {"links", "text", :none},
        {"created_at", "timestamptz", :none},
        {"trace_state", "text", :none},
        {"scope_attributes", "text", :none},
        {"dropped_attributes_count", "integer", :none},
        {"dropped_events_count", "integer", :none},
        {"dropped_links_count", "integer", :none},
        {"service_namespace", "text", :none},
        {"deployment_environment", "text", :none},
        {"ingest_identity", "text", :none},
        {"ingest_agent_id", "text", :none},
        {"ingest_partition", "text", :none}
      ]
    },
    %Table{
      table: "otel_metrics",
      time_column: "timestamp",
      signal_class: :otel_metrics,
      retention_config_key: :otel_metrics_retention_days,
      default_hot_days: 30,
      chunk_interval_key: :otel_metrics_chunk_interval_hours,
      default_chunk_hours: 24,
      update_prone: false,
      tiebreakers: ["span_id", "span_name", "service_name"],
      columns: [
        {"timestamp", "timestamptz", :none},
        {"trace_id", "text", :none},
        {"span_id", "text", :none},
        {"service_name", "text", :none},
        {"span_name", "text", :none},
        {"span_kind", "text", :none},
        {"duration_ms", "double precision", :none},
        {"duration_seconds", "double precision", :none},
        {"metric_type", "text", :none},
        {"http_method", "text", :none},
        {"http_route", "text", :none},
        {"http_status_code", "text", :none},
        {"grpc_service", "text", :none},
        {"grpc_method", "text", :none},
        {"grpc_status_code", "text", :none},
        {"is_slow", "boolean", :none},
        {"component", "text", :none},
        {"level", "text", :none},
        {"unit", "text", :none},
        {"created_at", "timestamptz", :none},
        {"ingest_identity", "text", :none},
        {"ingest_agent_id", "text", :none},
        {"ingest_partition", "text", :none}
      ]
    },
    %Table{
      table: "otel_metric_points",
      time_column: "timestamp",
      signal_class: :otel_metric_points,
      retention_config_key: :otel_metric_points_retention_days,
      default_hot_days: 30,
      chunk_interval_key: :otel_metric_points_chunk_interval_hours,
      default_chunk_hours: 6,
      update_prone: false,
      tiebreakers: ["metric_name", "service_name", "attributes_hash"],
      columns: [
        {"timestamp", "timestamptz", :none},
        {"metric_name", "text", :none},
        {"metric_type", "text", :none},
        {"unit", "text", :none},
        {"temporality", "text", :none},
        {"is_monotonic", "boolean", :none},
        {"service_name", "text", :none},
        {"attributes", "text", :none},
        {"attributes_hash", "text", :none},
        {"value", "double precision", :none},
        {"count", "bigint", :none},
        {"sum", "double precision", :none},
        {"bucket_counts", "text", :none},
        {"explicit_bounds", "text", :none},
        {"created_at", "timestamptz", :none},
        {"start_time_unix_nano", "bigint", :none},
        {"scope_name", "text", :none},
        {"service_instance_id", "text", :none},
        {"ingest_identity", "text", :none},
        {"ingest_agent_id", "text", :none},
        {"ingest_partition", "text", :none}
      ]
    },
    %Table{
      table: "timeseries_metrics",
      time_column: "timestamp",
      signal_class: :timeseries,
      retention_config_key: :timeseries_metrics_retention_days,
      default_hot_days: 7,
      chunk_interval_key: :raw_metrics_chunk_interval_hours,
      default_chunk_hours: 24,
      update_prone: false,
      tiebreakers: ["gateway_id", "series_key"],
      columns: [
        {"timestamp", "timestamptz", :none},
        {"gateway_id", "text", :none},
        {"agent_id", "text", :none},
        {"metric_name", "text", :none},
        {"metric_type", "text", :none},
        {"device_id", "text", :none},
        {"value", "double precision", :none},
        {"unit", "text", :none},
        {"tags", "jsonb", :text},
        {"partition", "text", :none},
        {"scale", "double precision", :none},
        {"is_delta", "boolean", :none},
        {"target_device_ip", "text", :none},
        {"if_index", "integer", :none},
        {"metadata", "jsonb", :text},
        {"created_at", "timestamptz", :none},
        {"series_key", "text", :none},
        {"counter_width", "integer", :none}
      ]
    },
    %Table{
      table: "ocsf_events",
      time_column: "time",
      signal_class: :events,
      retention_config_key: :ocsf_events_retention_days,
      default_hot_days: 14,
      chunk_interval_key: :ocsf_events_chunk_interval_hours,
      default_chunk_hours: 6,
      update_prone: true,
      tiebreakers: ["id"],
      columns: [
        {"id", "uuid", :text},
        {"time", "timestamptz", :none},
        {"class_uid", "integer", :none},
        {"category_uid", "integer", :none},
        {"type_uid", "integer", :none},
        {"activity_id", "integer", :none},
        {"activity_name", "text", :none},
        {"severity_id", "integer", :none},
        {"severity", "text", :none},
        {"message", "text", :none},
        {"status_id", "integer", :none},
        {"status", "text", :none},
        {"status_code", "text", :none},
        {"status_detail", "text", :none},
        {"metadata", "jsonb", :text},
        {"observables", "jsonb", :text},
        {"trace_id", "text", :none},
        {"span_id", "text", :none},
        {"actor", "jsonb", :text},
        {"device", "jsonb", :text},
        {"src_endpoint", "jsonb", :text},
        {"dst_endpoint", "jsonb", :text},
        {"log_name", "text", :none},
        {"log_provider", "text", :none},
        {"log_level", "text", :none},
        {"log_version", "text", :none},
        {"unmapped", "jsonb", :text},
        {"raw_data", "text", :none},
        {"created_at", "timestamptz", :none}
      ]
    },
    %Table{
      table: "ocsf_network_activity",
      time_column: "time",
      signal_class: :flows,
      retention_config_key: :ocsf_network_activity_retention_days,
      default_hot_days: 90,
      chunk_interval_key: :ocsf_network_activity_chunk_interval_hours,
      default_chunk_hours: 24,
      update_prone: false,
      # No unique key exists on this table; deterministic cold ordering must
      # order over the full projection or a synthetic export row id (M2).
      tiebreakers: [],
      columns: [
        {"time", "timestamptz", :none},
        {"class_uid", "integer", :none},
        {"category_uid", "integer", :none},
        {"activity_id", "integer", :none},
        {"type_uid", "integer", :none},
        {"severity_id", "integer", :none},
        {"start_time", "timestamptz", :none},
        {"end_time", "timestamptz", :none},
        {"src_endpoint_ip", "text", :none},
        {"src_endpoint_port", "integer", :none},
        {"src_as_number", "integer", :none},
        {"dst_endpoint_ip", "text", :none},
        {"dst_endpoint_port", "integer", :none},
        {"dst_as_number", "integer", :none},
        {"protocol_num", "integer", :none},
        {"protocol_name", "text", :none},
        {"tcp_flags", "integer", :none},
        {"bytes_total", "bigint", :none},
        {"packets_total", "bigint", :none},
        {"bytes_in", "bigint", :none},
        {"bytes_out", "bigint", :none},
        {"sampler_address", "text", :none},
        {"ocsf_payload", "jsonb", :text},
        {"partition", "text", :none},
        {"created_at", "timestamptz", :none},
        {"protocol_source", "text", :none},
        {"tcp_flags_labels", "text[]", :none},
        {"tcp_flags_source", "text", :none},
        {"dst_service_label", "text", :none},
        {"dst_service_source", "text", :none},
        {"direction_label", "text", :none},
        {"direction_source", "text", :none},
        {"src_hosting_provider", "text", :none},
        {"src_hosting_provider_source", "text", :none},
        {"dst_hosting_provider", "text", :none},
        {"dst_hosting_provider_source", "text", :none},
        {"src_mac", "text", :none},
        {"dst_mac", "text", :none},
        {"src_mac_vendor", "text", :none},
        {"src_mac_vendor_source", "text", :none},
        {"dst_mac_vendor", "text", :none},
        {"dst_mac_vendor_source", "text", :none},
        {"packets_in", "bigint", :none},
        {"packets_out", "bigint", :none},
        {"sampling_rate", "bigint", :none},
        # Prefix-tag flow enrichment (add-flow-prefix-tag-enrichment), added after
        # this registry was written. jsonb exports as text, matching every other
        # jsonb column here. Caught by RegistryDriftTest.
        {"src_prefix_tags", "jsonb", :text},
        {"dst_prefix_tags", "jsonb", :text},
        {"src_prefix_tags_source", "text", :none},
        {"dst_prefix_tags_source", "text", :none}
      ]
    }
  ]

  @tables_by_name Map.new(@tables, &{&1.table, &1})

  @doc "All registry entries."
  @spec tables() :: [Table.t()]
  def tables, do: @tables

  @doc "All registry table names."
  @spec table_names() :: [String.t()]
  def table_names, do: Enum.map(@tables, & &1.table)

  @doc "Look up a registry entry by table name."
  @spec fetch(String.t()) :: {:ok, Table.t()} | :error
  def fetch(table_name), do: Map.fetch(@tables_by_name, table_name)

  @spec fetch!(String.t()) :: Table.t()
  def fetch!(table_name), do: Map.fetch!(@tables_by_name, table_name)

  @doc "Whether a table participates in the cold tier."
  @spec member?(String.t()) :: boolean()
  def member?(table_name), do: Map.has_key?(@tables_by_name, table_name)

  @doc "Signal classes represented in the registry."
  @spec signal_classes() :: [atom()]
  def signal_classes, do: @tables |> Enum.map(& &1.signal_class) |> Enum.uniq()

  @spec tables_for_class(atom()) :: [Table.t()]
  def tables_for_class(class), do: Enum.filter(@tables, &(&1.signal_class == class))

  @doc """
  Whether the cold tier is active for this deployment.

  Purely configuration-driven (tenant-capabilities pattern): true only when
  deployment-supplied cold-tier configuration is present. Absent
  configuration means every cold-tier consumer must preserve current
  behavior.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:serviceradar_core, ServiceRadar.ColdTier, [])

    Keyword.get(config, :enabled, false) == true and
      Keyword.get(config, :bucket_url) not in [nil, ""]
  end

  @doc "Object-store base URL (e.g. `s3://tenant-bucket`) or nil."
  @spec bucket_url() :: String.t() | nil
  def bucket_url do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.ColdTier, [])
    |> Keyword.get(:bucket_url)
  end

  @doc """
  Hot retention window in days for a registry table.

  Reads the same configuration the retention worker consumes so there is a
  single retention-window authority.
  """
  @spec hot_retention_days(Table.t()) :: pos_integer()
  def hot_retention_days(%Table{} = entry) do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.Observability.DataRetentionWorker, [])
    |> Keyword.get(entry.retention_config_key, entry.default_hot_days)
    |> positive_integer(entry.default_hot_days)
  end

  @doc """
  Cold retention window in days for a registry table, or `nil` when the
  deployment has not stated one.

  There is deliberately NO default: this value is what the pruner deletes
  archived data by, and design D9 says an absent window means no expiry
  pruning at all (manifest hygiene only). Inventing 365 here would silently
  destroy archives on any deployment that never configured a window.
  """
  @spec cold_window_days(Table.t()) :: pos_integer() | nil
  def cold_window_days(%Table{} = entry) do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.ColdTier, [])
    |> Keyword.get(:cold_windows, [])
    |> Keyword.get(entry.signal_class)
    |> case do
      days when is_integer(days) and days > 0 -> days
      _ -> nil
    end
  end

  @doc """
  SELECT list applying canonical export casts, for use in export queries.

  Example: `"timestamp", id::text AS id, trace_id, ...`
  """
  @spec export_select_list(Table.t()) :: String.t()
  def export_select_list(%Table{columns: columns}) do
    Enum.map_join(columns, ", ", fn
      {name, _type, :none} -> quote_ident(name)
      {name, _type, :text} -> "#{quote_ident(name)}::text AS #{quote_ident(name)}"
    end)
  end

  @doc """
  Deterministic object-key prefix for a table + UTC date partition, e.g.
  `cold/v1/logs/date=2026-07-01`.
  """
  @spec object_prefix(Table.t(), Date.t()) :: String.t()
  def object_prefix(%Table{table: table}, %Date{} = date) do
    "cold/#{@layout_version}/#{table}/date=#{Date.to_iso8601(date)}"
  end

  @doc "Schema-qualified relation name, e.g. `platform.logs`."
  @spec qualified_table(Table.t()) :: String.t()
  def qualified_table(%Table{table: table}), do: "#{@schema}.#{quote_ident(table)}"

  @doc "Expected column names+types for the drift check, ordered."
  @spec expected_columns(Table.t()) :: [{String.t(), String.t()}]
  def expected_columns(%Table{columns: columns}) do
    Enum.map(columns, fn {name, type, _cast} -> {name, type} end)
  end

  @doc "Postgres schema holding the registry tables."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Object layout version segment."
  @spec layout_version() :: String.t()
  def layout_version, do: @layout_version

  defp quote_ident(name), do: ~s("#{name}")

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
