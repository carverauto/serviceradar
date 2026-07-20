defmodule ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData do
  @moduledoc false

  import Ash.Expr

  alias Ash.Query, as: AshQuery
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Observability.AnomalyEpisode
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData

  require AshQuery
  require Logger

  @metric_classes ~w(cpu memory disk interface snmp other)
  @anomaly_page_limit 5
  @capacity_limit 12
  @query_timeout_ms 5_000
  @episode_cursor_prefix "offset:"

  def empty(status \\ :ok) do
    %{
      status: status,
      anomaly_rows: [],
      capacity_rows: [],
      anomaly_query: nil,
      capacity_query: nil,
      anomaly_filter: nil,
      capacity_filter: nil,
      anomaly_pagination: %{"next_cursor" => nil, "prev_cursor" => nil, "limit" => @anomaly_page_limit},
      anomaly_error: nil,
      capacity_error: nil,
      metric_statuses: metric_statuses([])
    }
  end

  def load(srql_module, identity, scope, opts \\ [])

  def load(_srql_module, identity, _scope, _opts) when identity in [nil, %{}], do: empty()

  def load(srql_module, identity, scope, opts) when is_map(identity) do
    anomaly_candidates = anomaly_filter_candidates(identity)
    capacity_candidates = capacity_filter_candidates(identity)

    if anomaly_candidates == [] and capacity_candidates == [] do
      empty()
    else
      anomaly_task =
        Task.Supervisor.async_nolink(ServiceRadarWebNG.TaskSupervisor, fn ->
          load_anomaly_first(srql_module, anomaly_candidates, scope,
            cursor: Keyword.get(opts, :anomaly_cursor),
            limit: @anomaly_page_limit,
            severity: Keyword.get(opts, :anomaly_severity),
            status: Keyword.get(opts, :anomaly_status),
            sort: Keyword.get(opts, :anomaly_sort),
            source: Keyword.get(opts, :anomaly_source)
          )
        end)

      capacity_task =
        Task.Supervisor.async_nolink(ServiceRadarWebNG.TaskSupervisor, fn ->
          load_first(
            srql_module,
            capacity_candidates,
            scope,
            fn candidate, _opts -> capacity_query(candidate) end,
            &project_capacity_row/1,
            dedupe_by: &capacity_row_identity/1
          )
        end)

      anomaly = await_load_task(anomaly_task, "anomaly")
      capacity = await_load_task(capacity_task, "capacity")

      %{
        status: combined_status(anomaly, capacity),
        identity: identity,
        anomaly_rows: anomaly.rows,
        capacity_rows: capacity.rows,
        anomaly_query: anomaly.query,
        capacity_query: capacity.query,
        anomaly_filter: anomaly.filter,
        capacity_filter: capacity.filter,
        anomaly_pagination: anomaly.pagination,
        anomaly_error: anomaly.error,
        capacity_error: capacity.error,
        metric_statuses: metric_statuses(anomaly.rows)
      }
    end
  end

  defp await_load_task(task, label) do
    case Task.yield(task, @query_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        error = "#{label} SRQL task failed: #{Exception.format_exit(reason)}"
        Logger.warning(error)
        task_error_result(error)

      nil ->
        error = "#{label} SRQL query timed out after #{@query_timeout_ms}ms"
        Logger.warning(error)
        task_error_result(error)
    end
  end

  defp task_error_result(error) do
    %{rows: [], query: nil, filter: nil, pagination: empty_pagination(), error: error, status: :error}
  end

  defp load_anomaly_first(srql_module, candidates, scope, opts) do
    source = anomaly_source(opts)

    candidates
    |> Enum.reduce_while(nil, fn candidate, acc ->
      case load_anomaly_source(source, srql_module, candidate, scope, opts) do
        {:ok, %{} = response} ->
          rows =
            response
            |> response_rows()
            |> Enum.filter(&is_map/1)
            |> Enum.map(&project_anomaly_row/1)
            |> Enum.reject(&is_nil/1)

          result = %{
            rows: rows,
            query: response_query(response) || anomaly_episode_drilldown_query(candidate, opts),
            filter: Map.take(candidate, [:field, :label, :value]),
            pagination: response |> response_pagination() |> normalize_pagination(opts),
            error: nil,
            status: :ok
          }

          if result.rows == [] do
            {:cont, acc || result}
          else
            {:halt, result}
          end

        {:error, reason} ->
          query = anomaly_episode_drilldown_query(candidate, opts)
          error = "anomaly episode error: #{QueryData.format_error(reason)}"
          Logger.warning("Failed device anomaly episode query #{query}: #{error}")
          {:cont, acc || error_result(candidate, query, error)}
      end
    end)
    |> case do
      nil -> %{rows: [], query: nil, filter: nil, pagination: empty_pagination(), error: nil, status: :ok}
      result -> result
    end
  end

  defp load_first(srql_module, candidates, scope, query_fun, project_fun, opts) do
    candidates
    |> Enum.reduce_while(nil, fn candidate, acc ->
      query = query_fun.(candidate, opts)

      query_opts =
        %{scope: scope}
        |> maybe_put_query_opt(:cursor, Keyword.get(opts, :cursor))
        |> maybe_put_query_opt(:limit, Keyword.get(opts, :limit))

      case srql_module.query(query, query_opts) do
        {:ok, %{"results" => rows} = response} when is_list(rows) ->
          rows =
            rows
            |> Enum.filter(&is_map/1)
            |> Enum.map(project_fun)
            |> Enum.reject(&is_nil/1)
            |> maybe_dedupe_rows(Keyword.get(opts, :dedupe_by))

          result = %{
            rows: rows,
            query: query,
            filter: Map.take(candidate, [:field, :label, :value]),
            pagination: response |> Map.get("pagination") |> normalize_pagination(opts),
            error: nil,
            status: :ok
          }

          if result.rows == [] do
            {:cont, acc || result}
          else
            {:halt, result}
          end

        {:ok, other} ->
          error = "unexpected SRQL response: #{inspect(other)}"
          Logger.warning("Unexpected device anomaly/capacity SRQL response for #{query}: #{error}")
          {:cont, acc || error_result(candidate, query, error)}

        {:error, reason} ->
          error = "SRQL error: #{QueryData.format_error(reason)}"
          Logger.warning("Failed device anomaly/capacity SRQL query #{query}: #{error}")
          {:cont, acc || error_result(candidate, query, error)}
      end
    end)
    |> case do
      nil -> %{rows: [], query: nil, filter: nil, pagination: empty_pagination(), error: nil, status: :ok}
      result -> result
    end
  end

  defp anomaly_source(opts) do
    Keyword.get(opts, :source) ||
      Application.get_env(:serviceradar_web_ng, :anomaly_capacity_anomaly_source, :ash)
  end

  defp load_anomaly_source(:ash, _srql_module, candidate, scope, opts) do
    load_anomaly_episode_rows(candidate, scope, opts)
  end

  defp load_anomaly_source(:legacy_srql, srql_module, candidate, scope, opts) do
    query = anomaly_query(candidate, opts)

    query_opts =
      %{scope: scope}
      |> maybe_put_query_opt(:cursor, Keyword.get(opts, :cursor))
      |> maybe_put_query_opt(:limit, Keyword.get(opts, :limit))

    case srql_module.query(query, query_opts) do
      {:ok, %{"results" => rows} = response} when is_list(rows) ->
        {:ok, %{rows: rows, query: query, pagination: Map.get(response, "pagination")}}

      {:ok, other} ->
        {:error, "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_anomaly_source(source, srql_module, candidate, scope, opts) when is_atom(source) do
    if function_exported?(source, :load, 4) do
      source.load(srql_module, candidate, scope, opts)
    else
      {:error, "unsupported anomaly source #{inspect(source)}"}
    end
  end

  defp load_anomaly_source(source, srql_module, candidate, scope, opts) when is_function(source, 4) do
    source.(srql_module, candidate, scope, opts)
  end

  defp load_anomaly_source(source, _srql_module, _candidate, _scope, _opts) do
    {:error, "unsupported anomaly source #{inspect(source)}"}
  end

  defp response_rows(%{rows: rows}) when is_list(rows), do: rows
  defp response_rows(%{"rows" => rows}) when is_list(rows), do: rows
  defp response_rows(_), do: []

  defp response_query(%{query: query}) when is_binary(query), do: query
  defp response_query(%{"query" => query}) when is_binary(query), do: query
  defp response_query(_), do: nil

  defp response_pagination(%{pagination: pagination}) when is_map(pagination), do: pagination
  defp response_pagination(%{"pagination" => pagination}) when is_map(pagination), do: pagination
  defp response_pagination(_), do: %{}

  defp empty_pagination do
    %{"next_cursor" => nil, "prev_cursor" => nil, "limit" => @anomaly_page_limit}
  end

  defp maybe_put_query_opt(opts, _key, nil), do: opts
  defp maybe_put_query_opt(opts, _key, ""), do: opts
  defp maybe_put_query_opt(opts, key, value), do: Map.put(opts, key, value)

  defp normalize_pagination(pagination, opts) when is_map(pagination) do
    %{
      "next_cursor" => Map.get(pagination, "next_cursor"),
      "prev_cursor" => Map.get(pagination, "prev_cursor") || Map.get(pagination, "previous_cursor"),
      "limit" => Map.get(pagination, "limit") || Keyword.get(opts, :limit)
    }
  end

  defp normalize_pagination(_pagination, opts) do
    %{
      "next_cursor" => nil,
      "prev_cursor" => nil,
      "limit" => Keyword.get(opts, :limit)
    }
  end

  defp error_result(candidate, query, error) do
    %{
      rows: [],
      query: query,
      filter: Map.take(candidate, [:field, :label, :value]),
      pagination: empty_pagination(),
      error: error,
      status: :error
    }
  end

  defp combined_status(%{status: :error}, _capacity), do: :error
  defp combined_status(_anomaly, %{status: :error}), do: :error
  defp combined_status(_anomaly, _capacity), do: :ok

  defp anomaly_filter_candidates(identity) do
    # Canonical device pages must not fall back to agent/host-scoped findings:
    # that is exactly how polled-device SNMP findings end up displayed on the
    # polling agent. Device pages may still query the host alias because sysmon
    # findings can be host-keyed before canonical device attribution is present.
    device_candidate = candidate(identity, :device_uid, "service_radar_device_uid", "device")
    host_candidate = candidate(identity, :host_id, "service_radar_device_uid", "host")

    candidates =
      if device_candidate do
        [device_candidate, host_candidate]
      else
        [
          candidate(identity, :agent_id, "service_radar_device_uid", "agent"),
          host_candidate
        ]
      end

    Enum.reject(candidates, &is_nil/1)
  end

  defp capacity_filter_candidates(identity) do
    Enum.reject(
      [
        candidate(identity, :device_uid, "resource_id", "device"),
        candidate(identity, :agent_id, "resource_id", "agent"),
        candidate(identity, :host_id, "resource_id", "host")
      ],
      &is_nil/1
    )
  end

  defp candidate(identity, key, field, label) do
    case Map.get(identity, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: %{field: field, label: label, value: value}

      _ ->
        nil
    end
  end

  defp anomaly_query(%{field: field, value: value}, opts) do
    [
      "in:events",
      "class_uid:2004",
      # Anomaly findings carry source_type='anomaly_detection' in
      # metadata.service_radar; event_type is NULL on these rows. Filtering
      # source_type (not event_type) is what returns the findings.
      #
      # Index note: this query does NOT ride the anomaly-specific partial index
      # idx_ocsf_events_sr_anomaly_device_time (class_uid=2004 AND
      # source_type='anomaly_detection'). SRQL expands `source_type:...` into a
      # nine-way OR (log_provider / log_name / metadata #>> service_radar &
      # serviceradar source_type & addon_id / metadata->>source / unmapped
      # source_type & addon_id), and an OR cannot imply that partial index's
      # source_type='anomaly_detection' predicate — so the narrow index is dead
      # for this query. What actually serves it is the broad class_uid=2004-only
      # device index idx_ocsf_events_sr_device_uid_time ((device_uid, time DESC)
      # WHERE class_uid = 2004): class_uid=2004 implies its partial predicate,
      # device_uid=X seeks the leading key, time DESC satisfies the ORDER BY, and
      # the 9-way OR collapses to a cheap residual Filter over that one device's
      # 2004 rows. Do NOT re-narrow the device index onto source_type (see
      # migration 20260625120000_restore_ocsf_events_broad_device_index) — doing
      # so drops the plan back to a 7-day full scan that trips the 5000ms panel
      # timeout for every device. A durable fix is a dedicated narrow SRQL field
      # that compiles source_type to a single pushable equality (future work).
      "source_type:anomaly_detection",
      ~s|#{field}:"#{QueryData.escape_value(value)}"|,
      "time:last_7d",
      anomaly_severity_token(Keyword.get(opts, :severity)),
      anomaly_status_token(Keyword.get(opts, :status)),
      anomaly_sort_token(Keyword.get(opts, :sort)),
      "limit:#{Keyword.get(opts, :limit, @anomaly_page_limit)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp anomaly_severity_token("critical"), do: "severity:Critical"
  defp anomaly_severity_token("high"), do: "severity:High"
  defp anomaly_severity_token("medium"), do: "severity:(Medium,Warning)"
  defp anomaly_severity_token("low"), do: "severity:Low"
  defp anomaly_severity_token(_), do: nil

  defp anomaly_status_token("open"), do: "status:(active,open,anomaly_open,confirmed,anomalous)"
  defp anomaly_status_token("cleared"), do: "status:(inactive,cleared,resolved)"
  defp anomaly_status_token("pending"), do: "status:(pending,pending_anomaly,pending_confirmation,warming)"
  defp anomaly_status_token(_), do: "status:(active,open,anomaly_open,confirmed,anomalous,inactive,cleared,resolved)"

  defp anomaly_sort_token("oldest"), do: "sort:time:asc"
  defp anomaly_sort_token(_), do: "sort:time:desc"

  defp load_anomaly_episode_rows(%{value: device_uid} = candidate, scope, opts) do
    limit = Keyword.get(opts, :limit, @anomaly_page_limit)
    offset = episode_cursor_offset(Keyword.get(opts, :cursor))

    query =
      AnomalyEpisode
      |> AshQuery.for_read(:read, %{}, scope: scope)
      |> AshQuery.filter(expr(device_uid == ^device_uid))
      |> maybe_filter_episode_status(Keyword.get(opts, :status))
      |> maybe_filter_episode_severity(Keyword.get(opts, :severity))
      |> sort_episode_query(Keyword.get(opts, :sort))
      |> AshQuery.limit(limit + 1)
      |> AshQuery.offset(offset)

    case Ash.read(query, scope: scope) do
      {:ok, episodes} ->
        {page_rows, has_next?} = split_episode_page(episodes, limit)

        {:ok,
         %{
           rows: Enum.map(page_rows, &project_episode/1),
           query: anomaly_episode_drilldown_query(candidate, opts),
           pagination: episode_pagination(offset, limit, has_next?)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_filter_episode_status(query, "open"), do: AshQuery.filter(query, expr(status == "open"))

  defp maybe_filter_episode_status(query, "cleared"),
    do: AshQuery.filter(query, expr(status in ["cleared", "stale_closed"]))

  defp maybe_filter_episode_status(query, "pending"), do: AshQuery.filter(query, expr(status == "__pending__"))
  defp maybe_filter_episode_status(query, _), do: query

  defp maybe_filter_episode_severity(query, severity) do
    case episode_severity_id(severity) do
      nil -> query
      id -> AshQuery.filter(query, expr(peak_severity_id == ^id))
    end
  end

  defp episode_severity_id("critical"), do: OCSF.severity_critical()
  defp episode_severity_id("high"), do: OCSF.severity_high()
  defp episode_severity_id("medium"), do: OCSF.severity_medium()
  defp episode_severity_id("low"), do: OCSF.severity_low()
  defp episode_severity_id(_), do: nil

  defp sort_episode_query(query, "oldest"), do: AshQuery.sort(query, opened_at: :asc)
  defp sort_episode_query(query, "severity"), do: AshQuery.sort(query, peak_severity_id: :desc, last_seen_at: :desc)
  defp sort_episode_query(query, _), do: AshQuery.sort(query, last_seen_at: :desc)

  defp split_episode_page(rows, limit) do
    if length(rows) > limit do
      {Enum.take(rows, limit), true}
    else
      {rows, false}
    end
  end

  defp episode_pagination(offset, limit, has_next?) do
    %{
      "next_cursor" => if(has_next?, do: "#{@episode_cursor_prefix}#{offset + limit}"),
      "prev_cursor" => if(offset > 0, do: "#{@episode_cursor_prefix}#{max(offset - limit, 0)}"),
      "limit" => limit
    }
  end

  defp episode_cursor_offset(value) when is_binary(value) do
    if String.starts_with?(value, @episode_cursor_prefix) do
      value
      |> String.replace_prefix(@episode_cursor_prefix, "")
      |> parse_non_negative_int()
    else
      0
    end
  end

  defp episode_cursor_offset(_), do: 0

  defp parse_non_negative_int(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp anomaly_episode_drilldown_query(%{field: field, value: value}, opts) do
    [
      "in:events",
      "finding_rollup:health",
      ~s|#{field}:"#{QueryData.escape_value(value)}"|,
      "time:last_7d",
      anomaly_severity_token(Keyword.get(opts, :severity)),
      anomaly_status_token(Keyword.get(opts, :status)),
      anomaly_sort_token(Keyword.get(opts, :sort)),
      "limit:50"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp capacity_query(%{field: field, value: value}) do
    Enum.join(
      [
        "in:capacity_forecasts",
        # The worker/DB only ever persist status projected|skipped (DB CHECK);
        # at_risk/exhaustion_projected never occur as row statuses.
        "status:projected",
        "has_exhaustion:true",
        ~s|#{field}:"#{QueryData.escape_value(value)}"|,
        "time:last_24h",
        "sort:forecasted_at:desc",
        "limit:#{@capacity_limit}"
      ],
      " "
    )
  end

  defp maybe_dedupe_rows(rows, dedupe_fun) when is_function(dedupe_fun, 1), do: Enum.uniq_by(rows, dedupe_fun)
  defp maybe_dedupe_rows(rows, _dedupe_fun), do: rows

  defp capacity_row_identity(row) when is_map(row) do
    {
      map_value(row, "resource_id"),
      map_value(row, "resource_key"),
      map_value(row, "metric_name")
    }
  end

  @doc false
  def project_episode(episode) do
    payload = episode |> episode_value(:last_payload) |> normalize_payload()
    metadata = payload |> map_value("metadata") |> normalize_payload()
    anomaly = payload |> map_value("anomaly") |> normalize_payload()
    status = episode_value(episode, :status)
    opened_at = episode_value(episode, :opened_at)
    last_seen_at = episode_value(episode, :last_seen_at)
    cleared_at = episode_value(episode, :cleared_at)
    severity_id = episode_value(episode, :severity_id) || OCSF.severity_unknown()
    peak_severity_id = episode_value(episode, :peak_severity_id) || severity_id
    metric_name = episode_value(episode, :metric_name)
    metric_class = episode_value(episode, :metric_class)
    detector = episode_value(episode, :detector)
    clear_reason = episode_value(episode, :clear_reason)
    opening_reason = reason(payload)

    anomaly =
      Map.merge(
        anomaly,
        reject_nil_values(%{
          "state" => episode_state(status),
          "status" => status,
          "score" => episode_value(episode, :peak_score),
          "reason" => episode_reason(status, opening_reason, clear_reason),
          "opening_reason" => opening_reason,
          "resolution_reason" => clear_reason,
          "episode_started_at_unix_nano" => unix_nano(opened_at),
          "episode_ended_at_unix_nano" => unix_nano(cleared_at),
          "observed_at_unix_nano" => unix_nano(last_seen_at)
        })
      )

    base = %{
      "id" => episode_value(episode, :episode_uid),
      "episode_uid" => episode_value(episode, :episode_uid),
      "finding_uid" => episode_value(episode, :finding_uid),
      "source_device_uid" => episode_value(episode, :device_uid),
      "device_label" => episode_value(episode, :device_uid),
      "time" => iso8601(last_seen_at),
      "finding_title" => episode_title(payload, metric_name, metric_class, detector),
      "message" => episode_message(payload, status, clear_reason),
      "metric_class" => metric_class,
      "metric_name" => metric_name,
      "series_key" => episode_value(episode, :series_key),
      "if_index" => episode_value(episode, :if_index),
      "severity" => OCSF.severity_name(severity_id),
      "severity_id" => severity_id,
      "peak_severity_id" => peak_severity_id,
      "status" => status,
      "state" => episode_state(status),
      "score" => episode_value(episode, :peak_score),
      "effect_size" => episode_value(episode, :effect_size),
      "window_started_at" => iso8601(opened_at),
      "window_ended_at" => iso8601(cleared_at),
      "episode_started_at_unix_nano" => unix_nano(opened_at),
      "episode_ended_at_unix_nano" => unix_nano(cleared_at),
      "observed_at_unix_nano" => unix_nano(last_seen_at),
      "occurrence_count" => episode_value(episode, :occurrence_count),
      "reopen_count" => episode_value(episode, :reopen_count),
      "producer_version" => episode_value(episode, :producer_version),
      "last_transition" => episode_value(episode, :last_transition),
      "reason" => episode_reason(status, opening_reason, clear_reason),
      "opening_reason" => opening_reason,
      "resolution_reason" => clear_reason,
      "anomaly" => anomaly,
      "anomaly_disposition" => episode_anomaly_disposition(payload),
      "metadata" =>
        metadata
        |> merge_nested_map("service_radar", %{
          "metric_class" => metric_class,
          "metric_name" => metric_name,
          "series_key" => episode_value(episode, :series_key),
          "status" => status
        })
        |> merge_nested_map("anomaly", %{
          "state" => episode_state(status),
          "status" => status,
          "score" => episode_value(episode, :peak_score),
          "reason" => episode_reason(status, opening_reason, clear_reason),
          "opening_reason" => opening_reason,
          "resolution_reason" => clear_reason,
          "episode_started_at_unix_nano" => unix_nano(opened_at),
          "episode_ended_at_unix_nano" => unix_nano(cleared_at),
          "observed_at_unix_nano" => unix_nano(last_seen_at)
        })
    }

    payload
    |> Map.merge(base)
    |> reject_nil_values()
  end

  defp episode_value(%{} = episode, field), do: Map.get(episode, field) || Map.get(episode, to_string(field))
  defp episode_value(_episode, _field), do: nil

  defp normalize_payload(%{} = payload), do: payload
  defp normalize_payload(_), do: %{}

  defp episode_title(payload, metric_name, metric_class, detector) do
    finding_title(payload) ||
      [
        metric_name,
        metric_class,
        detector,
        "anomaly episode"
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
  end

  defp episode_message(payload, status, clear_reason) do
    episode_reason(status, reason(payload), clear_reason) || "Anomaly episode #{status}"
  end

  defp episode_reason(status, _opening_reason, clear_reason) when status in ["cleared", "stale_closed"] do
    clear_reason || "Anomaly episode resolved"
  end

  defp episode_reason(_status, opening_reason, _clear_reason), do: opening_reason

  defp episode_state("open"), do: "confirmed"
  defp episode_state("cleared"), do: "cleared"
  defp episode_state("stale_closed"), do: "cleared"
  defp episode_state(status), do: status

  defp episode_anomaly_disposition(payload) do
    anomaly_disposition(payload) || %{"action" => "escalate", "source" => "anomaly_episodes"}
  end

  defp merge_nested_map(map, key, additions) do
    existing = map |> map_value(key) |> normalize_payload()
    Map.put(map, key, Map.merge(existing, reject_nil_values(additions)))
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(%NaiveDateTime{} = naive), do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_), do: nil

  defp unix_nano(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :nanosecond)
  defp unix_nano(%NaiveDateTime{} = naive), do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:nanosecond)
  defp unix_nano(_), do: nil

  defp project_anomaly_row(row) do
    row = maybe_project_episode_row(row)

    projected =
      reject_nil_values(%{
        "id" => map_value(row, "id"),
        "episode_uid" => map_value(row, "episode_uid"),
        "finding_uid" => finding_uid(row),
        "time" => map_value(row, "time"),
        "finding_title" => finding_title(row),
        "message" => map_value(row, "message"),
        "metric_class" => metric_class(row),
        "metric_name" => metric_name(row),
        "resource_id" => capacity_field(row, "resource_id"),
        "resource_key" => capacity_field(row, "resource_key"),
        "resource_label" => capacity_field(row, "resource_label"),
        "resource_type" => capacity_field(row, "resource_type"),
        "metric_value" => metric_value(row),
        "current_value" => capacity_field(row, "current_value"),
        "projected_value" => capacity_field(row, "projected_value"),
        "projected_exhaustion_at" => capacity_field(row, "projected_exhaustion_at"),
        "exhaustion_threshold" => capacity_field(row, "exhaustion_threshold"),
        "horizon_seconds" => capacity_field(row, "horizon_seconds"),
        "horizon_ends_at" => capacity_field(row, "horizon_ends_at"),
        "confidence" => capacity_field(row, "confidence"),
        "lower_bound" => capacity_field(row, "lower_bound"),
        "upper_bound" => capacity_field(row, "upper_bound"),
        "related_finding_uid" => related_finding_uid(row),
        "peak_value" => peak_value(row),
        "sample_value" => sample_value(row),
        "threshold_value" => threshold_value(row),
        "score" => score_value(row),
        "window_started_at" => anomaly_window_started_at(row),
        "window_ended_at" => anomaly_window_ended_at(row),
        "series_key" => series_key(row),
        "interface_uid" => interface_uid(row),
        "if_index" => if_index(row),
        "device_label" => device_label(row),
        "severity" => map_value(row, "severity"),
        "effective_severity" => effective_severity(row),
        "disposition" => disposition(row),
        "reason" => reason(row),
        "state" => anomaly_state(row),
        "status" => status_value(row),
        "consecutive_anomalous" => detection_value(row, "consecutive_anomalous"),
        "episode_started_at_unix_nano" => detection_value(row, "episode_started_at_unix_nano"),
        "episode_ended_at_unix_nano" => detection_value(row, "episode_ended_at_unix_nano"),
        "episode_peak_value" => detection_value(row, "episode_peak_value"),
        "episode_peak_at_unix_nano" => detection_value(row, "episode_peak_at_unix_nano"),
        "observed_at_unix_nano" => detection_value(row, "observed_at_unix_nano"),
        "signals" => detection_value(row, "signals"),
        "anomaly_disposition" => anomaly_disposition(row)
      })

    if operator_visible_anomaly_row?(projected), do: projected
  end

  # The built-in Ash source already converts an `AnomalyEpisode` into the
  # display contract. Custom episode sources are allowed to return the raw
  # record, though, and must receive that same projection; otherwise a stale
  # last_payload.anomaly lifecycle can override the authoritative DB status.
  defp maybe_project_episode_row(%{} = row) do
    if is_binary(map_value(row, "episode_uid")) and is_map(map_value(row, "last_payload")) do
      project_episode(row)
    else
      row
    end
  end

  defp maybe_project_episode_row(row), do: row

  defp capacity_field(row, field) do
    first_present(row, [
      [field],
      ["metadata", "capacity_forecast", field],
      ["unmapped", "capacity_forecast", field],
      ["raw_data", "capacity_forecast", field],
      ["capacity_forecast", field]
    ])
  end

  defp related_finding_uid(row) do
    if capacity_notice?(row) do
      first_present(row, [
        ["related_finding_uid"],
        ["clears_finding_uid"],
        ["trigger_finding_uid"],
        ["metadata", "capacity_forecast", "clears_finding_uid"],
        ["unmapped", "capacity_forecast", "clears_finding_uid"],
        ["metadata", "finding_info", "group_uid"],
        ["metadata", "finding_info", "uid"]
      ])
    end
  end

  defp project_capacity_row(row) do
    unit = capacity_value_unit(row)
    projected = row |> map_value("projected_value") |> number_value()

    if implausible_percent_projection?(projected, unit) or projection_outside_horizon?(row) do
      nil
    else
      reject_nil_values(%{
        "forecasted_at" => map_value(row, "forecasted_at"),
        "resource_type" => map_value(row, "resource_type"),
        "resource_label" => map_value(row, "resource_label"),
        "resource_key" => map_value(row, "resource_key"),
        "resource_id" => map_value(row, "resource_id"),
        "metric_name" => map_value(row, "metric_name"),
        "metric_class" => map_value(row, "metric_class"),
        "value_unit" => unit,
        "status" => map_value(row, "status"),
        "model" => map_value(row, "model"),
        "sample_count" => map_value(row, "sample_count"),
        "horizon_seconds" => map_value(row, "horizon_seconds"),
        "horizon_ends_at" => map_value(row, "horizon_ends_at"),
        "window_started_at" => map_value(row, "window_started_at"),
        "window_ended_at" => map_value(row, "window_ended_at"),
        "current_value" => map_value(row, "current_value"),
        "projected_value" => map_value(row, "projected_value"),
        "projected_exhaustion_at" => map_value(row, "projected_exhaustion_at"),
        "exhaustion_threshold" => map_value(row, "exhaustion_threshold"),
        "confidence" => map_value(row, "confidence"),
        "lower_bound" => map_value(row, "lower_bound"),
        "upper_bound" => map_value(row, "upper_bound")
      })
    end
  end

  defp projection_outside_horizon?(row) do
    status = row |> map_value("status") |> normalize_text()
    projected_exhaustion_at = row |> map_value("projected_exhaustion_at") |> datetime_value()
    horizon_ends_at = row |> map_value("horizon_ends_at") |> datetime_value()

    status in ["projected", "at_risk", "exhaustion_projected"] and
      match?(%DateTime{}, projected_exhaustion_at) and
      match?(%DateTime{}, horizon_ends_at) and
      DateTime.after?(projected_exhaustion_at, horizon_ends_at)
  end

  defp finding_title(row) do
    first_present(row, [
      ["finding_title"],
      ["metadata", "finding_info", "title"],
      ["metadata", "detection_finding", "title"],
      ["message"]
    ])
  end

  defp reason(row) do
    first_present(row, [
      ["reason"],
      ["message"],
      ["metadata", "finding_info", "desc"],
      ["metadata", "finding_info", "description"],
      ["metadata", "finding_info", "reason"],
      ["metadata", "detection_finding", "reason"],
      ["metadata", "detection_finding", "description"],
      ["metadata", "anomaly", "reason"],
      ["metadata", "capacity_forecast", "reason"],
      ["unmapped", "reason"],
      ["raw_data", "reason"],
      ["raw_data", "anomaly", "reason"],
      ["raw_data", "capacity_forecast", "reason"]
    ])
  end

  defp finding_uid(row) do
    first_present(row, [
      ["finding_uid"],
      ["metadata", "finding_info", "uid"],
      ["metadata", "security_signal", "finding_uid"],
      ["metadata", "event_id"],
      ["metadata", "uid"],
      ["id"]
    ])
  end

  defp metric_name(row) do
    first_present(row, [
      ["metric_name"],
      ["metadata", "service_radar", "metric_name"],
      ["metadata", "anomaly", "metric_name"],
      ["metadata", "detection_finding", "metric_name"],
      ["unmapped", "metric_name"],
      ["raw_data", "metric_name"]
    ])
  end

  defp metric_value(row) do
    first_present(row, [
      ["metric_value"],
      ["metadata", "service_radar", "metric_value"],
      ["metadata", "anomaly", "value"],
      ["metadata", "anomaly", "sample_value"],
      ["metadata", "anomaly", "metric_value"],
      ["metadata", "detection_finding", "sample_value"],
      ["metadata", "finding_info", "dimensions", "sample_value"],
      ["unmapped", "metric_value"],
      ["raw_data", "metric_value"]
    ])
  end

  defp sample_value(row) do
    first_present(row, [
      ["sample_value"],
      ["metric_value"],
      ["metadata", "detection_finding", "sample_value"],
      ["metadata", "finding_info", "dimensions", "sample_value"],
      ["metadata", "anomaly", "sample_value"],
      ["metadata", "anomaly", "value"],
      ["raw_data", "anomaly", "sample_value"],
      ["raw_data", "anomaly", "value"]
    ])
  end

  defp threshold_value(row) do
    first_present(row, [
      ["threshold_value"],
      ["metadata", "service_radar", "threshold_value"],
      ["metadata", "anomaly", "threshold_value"],
      ["unmapped", "threshold_value"],
      ["raw_data", "threshold_value"]
    ])
  end

  defp peak_value(row) do
    first_present(row, [
      ["peak_value"],
      ["metadata", "service_radar", "peak_value"],
      ["metadata", "anomaly", "peak_value"],
      ["metadata", "anomaly", "peak"],
      ["metadata", "detection_finding", "peak_value"],
      ["metadata", "finding_info", "dimensions", "peak_value"],
      ["raw_data", "anomaly", "peak_value"],
      ["unmapped", "peak_value"],
      ["raw_data", "peak_value"]
    ])
  end

  defp score_value(row) do
    first_present(row, [
      ["score"],
      ["metadata", "service_radar", "score"],
      ["metadata", "anomaly", "score"],
      ["metadata", "anomaly", "z_score"],
      ["unmapped", "score"],
      ["raw_data", "score"]
    ])
  end

  defp anomaly_window_started_at(row) do
    first_present(row, [
      ["window_started_at"],
      ["window_start"],
      ["metadata", "service_radar", "window_started_at"],
      ["metadata", "anomaly", "window_started_at"],
      ["metadata", "anomaly", "window_start"],
      ["metadata", "detection_finding", "window_started_at"],
      ["metadata", "finding_info", "dimensions", "window_started_at"],
      ["unmapped", "window_started_at"],
      ["raw_data", "window_started_at"]
    ])
  end

  defp anomaly_window_ended_at(row) do
    first_present(row, [
      ["window_ended_at"],
      ["window_end"],
      ["metadata", "service_radar", "window_ended_at"],
      ["metadata", "anomaly", "window_ended_at"],
      ["metadata", "anomaly", "window_end"],
      ["metadata", "detection_finding", "window_ended_at"],
      ["metadata", "finding_info", "dimensions", "window_ended_at"],
      ["unmapped", "window_ended_at"],
      ["raw_data", "window_ended_at"]
    ])
  end

  defp effective_severity(row) do
    first_present(row, [
      ["effective_severity"],
      ["metadata", "service_radar", "effective_severity"],
      ["metadata", "anomaly", "effective_severity"],
      ["metadata", "detection_finding", "effective_severity"],
      ["metadata", "finding_info", "dimensions", "effective_severity"],
      ["unmapped", "effective_severity"],
      ["raw_data", "effective_severity"]
    ])
  end

  defp disposition(row) do
    first_present(row, [
      ["disposition"],
      ["metadata", "service_radar", "disposition"],
      ["metadata", "anomaly", "disposition"],
      ["metadata", "detection_finding", "disposition"],
      ["metadata", "finding_info", "dimensions", "disposition"],
      ["unmapped", "disposition"],
      ["raw_data", "disposition"]
    ])
  end

  defp detection_value(row, key) do
    first_present(row, [
      [key],
      ["metadata", "finding_info", "dimensions", key],
      ["metadata", "detection_finding", key],
      ["metadata", "anomaly", key],
      ["raw_data", "anomaly", key],
      ["unmapped", "anomaly", key],
      ["anomaly", key]
    ])
  end

  defp anomaly_disposition(row) do
    first_present(row, [
      ["anomaly_disposition"],
      ["metadata", "service_radar", "anomaly_disposition"],
      ["metadata", "serviceradar", "anomaly_disposition"],
      ["metadata", "diagnostics", "source", "source_anomaly_disposition"],
      ["metadata", "serviceradar", "diagnostics", "source", "source_anomaly_disposition"],
      ["unmapped", "anomaly_disposition"],
      ["raw_data", "anomaly_disposition"]
    ])
  end

  defp operator_visible_anomaly_row?(row) do
    status = status_value(row)
    reason = row |> reason() |> normalize_text()
    # normalize_text(nil) would stringify the atom to "nil"; an absent
    # disposition/action must normalize to "" so it reads as not-explicit.
    disposition_action =
      case row |> map_value("anomaly_disposition") |> map_value("action") do
        nil -> ""
        action -> normalize_text(action)
      end

    not pending_or_warmup_status?(status) and not pending_or_warmup_reason?(reason) and
      disposition_action != "suppress" and
      actionable_anomaly_row?(row, disposition_action)
  end

  # CPU edge spikes are deliberately high-recall detector evidence. A central
  # disposition that explicitly routes them away (action other than "escalate")
  # hides them; rows carrying no disposition stay visible, matching the default
  # the episode path synthesizes in project_episode/1 — no producer
  # persists anomaly_disposition on event rows, so requiring an explicit
  # "escalate" would unconditionally hide every cpu finding.
  defp actionable_anomaly_row?(row, disposition_action) do
    case metric_class(row) do
      "cpu" -> disposition_action in ["", "escalate"]
      _ -> true
    end
  end

  defp pending_or_warmup_status?(status) do
    status = normalize_text(status)

    status in ["pending", "pending_anomaly", "pending_confirmation", "warming"] or
      String.contains?(status, "pending")
  end

  defp pending_or_warmup_reason?(reason) do
    reason = normalize_text(reason)

    String.contains?(reason, "pending confirmation") or
      String.contains?(reason, "pending_anomaly") or
      String.contains?(reason, "warming")
  end

  defp anomaly_state(row) do
    first_present(row, [
      ["state"],
      ["metadata", "service_radar", "state"],
      ["metadata", "anomaly", "state"],
      ["metadata", "detection_finding", "state"],
      ["metadata", "detection_finding", "dimensions", "state"],
      ["metadata", "finding_info", "dimensions", "state"],
      ["unmapped", "state"],
      ["raw_data", "state"],
      ["raw_data", "anomaly", "state"]
    ])
  end

  defp series_key(row) do
    first_present(row, [
      ["series_key"],
      ["metadata", "service_radar", "series_key"],
      ["metadata", "anomaly", "series_key"],
      ["metadata", "detection_finding", "dimensions", "series_key"],
      ["unmapped", "series_key"],
      ["raw_data", "series_key"]
    ])
  end

  defp interface_uid(row) do
    first_present(row, [
      ["interface_uid"],
      ["metadata", "service_radar", "interface_uid"],
      ["metadata", "anomaly", "interface_uid"],
      ["metadata", "detection_finding", "dimensions", "interface_uid"],
      ["unmapped", "interface_uid"],
      ["raw_data", "interface_uid"]
    ])
  end

  defp if_index(row) do
    first_present(row, [
      ["if_index"],
      ["metadata", "service_radar", "if_index"],
      ["metadata", "anomaly", "if_index"],
      ["metadata", "detection_finding", "dimensions", "if_index"],
      ["unmapped", "if_index"],
      ["raw_data", "if_index"]
    ])
  end

  defp device_label(row) do
    first_present(row, [
      ["device_label"],
      ["host"],
      ["source"],
      ["source_device_uid"],
      ["device", "hostname"],
      ["device", "name"],
      ["metadata", "service_radar", "device_label"],
      ["metadata", "service_radar", "source_device_uid"],
      ["metadata", "detection_finding", "dimensions", "device_uid"]
    ])
  end

  defp capacity_value_unit(row) do
    first_present(row, [
      ["value_unit"],
      ["unit"],
      ["metadata", "forecast_value_unit"],
      ["metadata", "raw_value_unit"],
      ["metadata", "unit"]
    ])
  end

  defp implausible_percent_projection?(projected, unit) when is_number(projected) do
    percent_unit?(unit) and (projected < 0.0 or projected > 100.0)
  end

  defp implausible_percent_projection?(_projected, _unit), do: false

  defp percent_unit?(unit) when is_binary(unit) do
    unit
    |> normalize_text()
    |> case do
      "%" -> true
      "percent" -> true
      "percentage" -> true
      _ -> false
    end
  end

  defp percent_unit?(_unit), do: false

  defp number_value(value) when is_integer(value), do: value * 1.0
  defp number_value(value) when is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_), do: nil

  defp datetime_value(%DateTime{} = value), do: value
  defp datetime_value(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp datetime_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime_value(_), do: nil

  defp reject_nil_values(row) do
    Map.reject(row, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp metric_statuses(rows) do
    counts =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reject(&capacity_notice?/1)
      |> Enum.group_by(&metric_class/1)

    Enum.map(@metric_classes, fn class ->
      class_rows = Map.get(counts, class, [])
      status = anomaly_status(class_rows)

      %{
        class: class,
        label: metric_label(class),
        status: status,
        count: length(class_rows),
        latest: List.first(class_rows)
      }
    end)
  end

  defp anomaly_status([]), do: "normal"

  defp anomaly_status(rows) do
    cond do
      Enum.any?(rows, &(status_value(&1) == "suppressed")) ->
        "suppressed"

      Enum.any?(rows, &(normalize_text(anomaly_state(&1)) in ["confirmed", "anomalous"])) ->
        "confirmed"

      Enum.any?(rows, &(normalize_text(anomaly_state(&1)) in ["pending", "pending_anomaly"])) ->
        "pending"

      true ->
        "active"
    end
  end

  defp capacity_notice?(row) do
    text =
      [
        finding_title(row),
        map_value(row, "message"),
        reason(row),
        metric_name(row)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> normalize_text()

    String.contains?(text, "capacity forecast")
  end

  defp metric_class(row) do
    row
    |> first_present([
      ["metric_class"],
      ["metadata", "service_radar", "metric_class"],
      ["metadata", "anomaly", "metric_class"],
      ["metadata", "detection_finding", "metric_class"],
      ["unmapped", "metric_class"],
      ["raw_data", "metric_class"]
    ])
    |> normalize_class()
  end

  defp status_value(row) do
    row
    |> first_present([
      ["status"],
      ["state"],
      ["metadata", "service_radar", "status"],
      ["metadata", "anomaly", "status"],
      ["metadata", "anomaly", "state"],
      ["metadata", "finding_info", "dimensions", "status"],
      ["metadata", "finding_info", "dimensions", "state"],
      ["metadata", "detection_finding", "status"],
      ["metadata", "detection_finding", "state"],
      ["unmapped", "status"],
      ["unmapped", "state"],
      ["raw_data", "status"],
      ["raw_data", "state"],
      ["raw_data", "anomaly", "status"],
      ["raw_data", "anomaly", "state"]
    ])
    |> normalize_text()
  end

  defp first_present(row, paths) do
    Enum.find_value(paths, &nested_value(row, &1))
  end

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> map_value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp map_value(%{} = row, key) do
    Map.get(row, key) || Map.get(row, known_atom_key(key))
  end

  defp map_value(_row, _key), do: nil

  defp known_atom_key("metadata"), do: :metadata
  defp known_atom_key("raw_data"), do: :raw_data
  defp known_atom_key("unmapped"), do: :unmapped
  defp known_atom_key("service_radar"), do: :service_radar
  defp known_atom_key("serviceradar"), do: :serviceradar
  defp known_atom_key("diagnostics"), do: :diagnostics
  defp known_atom_key("anomaly"), do: :anomaly
  defp known_atom_key("anomaly_disposition"), do: :anomaly_disposition
  defp known_atom_key("source_anomaly_disposition"), do: :source_anomaly_disposition
  defp known_atom_key("detection_finding"), do: :detection_finding
  defp known_atom_key("metric_class"), do: :metric_class
  defp known_atom_key("metric_name"), do: :metric_name
  defp known_atom_key("metric_value"), do: :metric_value
  defp known_atom_key("threshold_value"), do: :threshold_value
  defp known_atom_key("score"), do: :score
  defp known_atom_key("series_key"), do: :series_key
  defp known_atom_key("interface_uid"), do: :interface_uid
  defp known_atom_key("if_index"), do: :if_index
  defp known_atom_key("device_label"), do: :device_label
  defp known_atom_key("device"), do: :device
  defp known_atom_key("hostname"), do: :hostname
  defp known_atom_key("name"), do: :name
  defp known_atom_key("host"), do: :host
  defp known_atom_key("source"), do: :source
  defp known_atom_key("source_device_uid"), do: :source_device_uid
  defp known_atom_key("id"), do: :id
  defp known_atom_key("finding_uid"), do: :finding_uid
  defp known_atom_key("security_signal"), do: :security_signal
  defp known_atom_key("event_id"), do: :event_id
  defp known_atom_key("uid"), do: :uid
  defp known_atom_key("z_score"), do: :z_score
  defp known_atom_key("value"), do: :value
  defp known_atom_key("dimensions"), do: :dimensions
  defp known_atom_key("forecasted_at"), do: :forecasted_at
  defp known_atom_key("resource_type"), do: :resource_type
  defp known_atom_key("resource_label"), do: :resource_label
  defp known_atom_key("resource_key"), do: :resource_key
  defp known_atom_key("resource_id"), do: :resource_id
  defp known_atom_key("value_unit"), do: :value_unit
  defp known_atom_key("unit"), do: :unit
  defp known_atom_key("model"), do: :model
  defp known_atom_key("sample_count"), do: :sample_count
  defp known_atom_key("horizon_seconds"), do: :horizon_seconds
  defp known_atom_key("horizon_ends_at"), do: :horizon_ends_at
  defp known_atom_key("window_started_at"), do: :window_started_at
  defp known_atom_key("window_ended_at"), do: :window_ended_at
  defp known_atom_key("current_value"), do: :current_value
  defp known_atom_key("projected_value"), do: :projected_value
  defp known_atom_key("projected_exhaustion_at"), do: :projected_exhaustion_at
  defp known_atom_key("exhaustion_threshold"), do: :exhaustion_threshold
  defp known_atom_key("confidence"), do: :confidence
  defp known_atom_key("lower_bound"), do: :lower_bound
  defp known_atom_key("upper_bound"), do: :upper_bound
  defp known_atom_key("forecast_value_unit"), do: :forecast_value_unit
  defp known_atom_key("raw_value_unit"), do: :raw_value_unit
  defp known_atom_key("status"), do: :status
  defp known_atom_key("state"), do: :state
  defp known_atom_key("action"), do: :action
  defp known_atom_key(_), do: nil

  defp normalize_class(value) do
    value
    |> normalize_text()
    |> case do
      "memory_metrics" -> "memory"
      "cpu_metrics" -> "cpu"
      "disk_metrics" -> "disk"
      "interface_metrics" -> "interface"
      "snmp" <> _ -> "snmp"
      class when class in @metric_classes -> class
      _ -> "other"
    end
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""

  defp metric_label("cpu"), do: "CPU"
  defp metric_label("memory"), do: "Memory"
  defp metric_label("disk"), do: "Disk"
  defp metric_label("interface"), do: "Interfaces"
  defp metric_label("snmp"), do: "SNMP"
  defp metric_label("other"), do: "Other signals"
  defp metric_label(class), do: class
end
