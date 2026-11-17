defmodule ServiceRadar.Camera.StreamSecretScrubWorker do
  @moduledoc """
  Removes camera stream addresses, path aliases and URL userinfo that Core
  stored from plugin results before `ServiceRadar.Camera.StreamAddressReduction`
  ran on entry (design D7 of the `resolve-camera-stream-sources-at-edge` change).

  ## Targets

  `@targets` is the single definition of what a pass scrubs and what `pending/0`
  counts. Each target names the change stage that brings it into scope; this
  code runs at stage 1, so it knows only the stage 1 targets:

    1. `camera_stream_profiles.metadata`: reduce, and drop keys outside the
       profile metadata allowlist (`InventoryIngestor.allowed_profile_metadata/1`).
    2. `camera_sources.metadata`: reduce. `camera_sources.last_event_message`,
       `last_event_type` and `availability_reason`, which hold plugin event text
       and the result summary: reduce, as strings.
    3. `ocsf_devices.metadata`: drop `camera_source_url`, and reduce the rest.
    4. `service_status.details`, `service_state.message` and
       `service_state.details`: reduce, and recompute the payload digests
       (`_serviceradar_plugin_result.payload_digest` and
       `downstream_ingest.payload_digest`) with the ingest function, so a
       redelivered result still matches its stored row. `service_status.message`
       (the result's summary) is reduced as well: a redelivery matches its stored
       row on that column too, and ingest now stores it reduced.

  "Reduce" is `StreamAddressReduction.reduce/1`, the same function every plugin
  result passes through on entry, so the cleanup cannot drift from the runtime.
  A row counts against a target exactly when that target's scrub would change
  it.

  `camera_sources.source_url` and `camera_stream_profiles.source_url_override`
  still hold the addresses a relay opens from until Stage 3; they are not stage
  1 targets. `pending/0` reports them separately, by column name, under
  `at_rest_until_stage_3`, so a clean stage 1 result is not mistaken for the fix.

  ## Passes

  Rows are read in primary-key batches. Each changed column is written by its own
  statement, guarded on that column still holding what was read, so a concurrent
  write to another column of the row does not stop it, and a row whose scrubbed
  column changed since it was read is skipped and re-read by a later pass.

  A pass scrubs a target only while every connected Core node
  (`ProcessRegistry.core_nodes/0`) reports, over `:erpc`, a `scrub_stage/0` no
  lower than the target's stage; a node without this worker or one that does not
  answer counts as stage 0, so an older replica that still writes copies holds
  the cleanup until it is gone.

  ## Jobs

  Each job names the stage it must complete in its args (`%{"stage" => 1}`) and
  is unique per stage. The job returns `:ok` only when (a) this code and every
  connected Core node are at or above the job's stage, (b) the pass scrubbed every
  target of the job, (c) the pass changed and skipped no row, and (d) `pending/0`
  then counts zero for every target of the job. Otherwise it snoozes for
  `:camera_stream_scrub_repass_seconds` (default 600) and runs again as the
  same job; it never inserts another. After `:camera_stream_scrub_max_passes`
  (default 1000) snoozed passes it returns an error carrying the per-target
  pending counts instead.

  ## Operator check

      bin/serviceradar_core_elx rpc 'IO.inspect(ServiceRadar.Camera.StreamSecretScrubWorker.pending())'
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete, keys: [:stage]]

  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.Camera.StreamAddressReduction
  alias ServiceRadar.Observability.PluginResultReportedMarker
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo

  require Logger

  @scrub_stage 1
  @batch_size 500
  @default_repass_seconds 600
  @default_max_passes 1000
  @stage_rpc_timeout_ms 5_000

  @targets [
    %{
      id: "camera_stream_profiles.metadata",
      stage: 1,
      type: "jsonb",
      table: "camera_stream_profiles",
      column: "metadata",
      scrub: :profile_metadata
    },
    %{
      id: "camera_sources.metadata",
      stage: 1,
      type: "jsonb",
      table: "camera_sources",
      column: "metadata",
      scrub: :reduce
    },
    %{
      id: "camera_sources.last_event_message",
      stage: 1,
      type: "text",
      table: "camera_sources",
      column: "last_event_message",
      scrub: :reduce
    },
    %{
      id: "camera_sources.last_event_type",
      stage: 1,
      type: "text",
      table: "camera_sources",
      column: "last_event_type",
      scrub: :reduce
    },
    %{
      id: "camera_sources.availability_reason",
      stage: 1,
      type: "text",
      table: "camera_sources",
      column: "availability_reason",
      scrub: :reduce
    },
    %{
      id: "ocsf_devices.metadata",
      stage: 1,
      type: "jsonb",
      table: "ocsf_devices",
      column: "metadata",
      scrub: :device_metadata
    },
    %{
      id: "service_status.details",
      stage: 1,
      type: "text",
      table: "service_status",
      column: "details",
      scrub: :plugin_document
    },
    %{
      id: "service_status.message",
      stage: 1,
      type: "text",
      table: "service_status",
      column: "message",
      scrub: :reduce
    },
    %{
      id: "service_state.message",
      stage: 1,
      type: "text",
      table: "service_state",
      column: "message",
      scrub: :plugin_document
    },
    %{
      id: "service_state.details",
      stage: 1,
      type: "text",
      table: "service_state",
      column: "details",
      scrub: :plugin_document
    }
  ]

  # Primary key columns (cast for reading, parameter cast) of each scanned table;
  # each target names its column's type. `prefilter` narrows a scan to rows that can hold a URL, an
  # escape, an alias key or `camera_source_url`; every row the reduction can change
  # matches it (a URL needs `://` or an escape, a nested JSON string needs an
  # escape, an alias key needs `alias` or an escape). The two inventory tables are
  # small and also need the allowlist, so they are scanned whole.
  @tables %{
    "camera_stream_profiles" => %{key: [{"id", :uuid}], prefilter?: false},
    "camera_sources" => %{key: [{"id", :uuid}], prefilter?: false},
    "ocsf_devices" => %{key: [{"uid", :text}], prefilter?: true},
    "service_status" => %{
      key: [{"timestamp", :timestamptz}, {"gateway_id", :text}, {"service_name", :text}],
      prefilter?: true
    },
    "service_state" => %{key: [{"id", :uuid}], prefilter?: true}
  }

  @at_rest_columns [
    {"camera_sources.source_url", "camera_sources", "source_url"},
    {"camera_stream_profiles.source_url_override", "camera_stream_profiles",
     "source_url_override"}
  ]

  @type pending_report :: %{
          required(:in_scope) => %{String.t() => non_neg_integer()},
          optional(:at_rest_until_stage_3) => %{String.t() => non_neg_integer()}
        }

  @doc "The scrub stage this code implements; peers read it over `:erpc`."
  @spec scrub_stage() :: pos_integer()
  def scrub_stage, do: @scrub_stage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"stage" => stage}, meta: meta})
      when is_integer(stage) and stage > 0 do
    run_pass(stage, Map.get(meta || %{}, "snoozed", 0))
  end

  def perform(%Oban.Job{}), do: {:cancel, "stream secret scrub job args carry no valid stage"}

  @doc """
  Runs one pass of a job for `job_stage` after `snoozed` earlier snoozed passes
  and returns the job outcome under the completion rule in the module
  documentation. Options: `:repo`, `:batch_size`, `:core_nodes` (the peer nodes
  to ask) and `:multicall` (an `:erpc.multicall/5`-shaped function).
  """
  @spec run_pass(pos_integer(), non_neg_integer(), keyword()) ::
          :ok | {:snooze, pos_integer()} | {:error, map()}
  def run_pass(job_stage, snoozed, opts \\ []) do
    pass = snoozed + 1

    if @scrub_stage < job_stage do
      Logger.warning(
        "Camera stream secret scrub pass #{pass}: this node runs scrub stage #{@scrub_stage}, " <>
          "below the job's stage #{job_stage}; no pass run"
      )

      continue(job_stage, snoozed, opts)
    else
      cluster_stage = cluster_scrub_stage(opts)
      targets = job_targets(job_stage)
      {active, held} = Enum.split_with(targets, &(&1.stage <= cluster_stage))
      report = Map.new(active, &{&1.id, scrub_target(&1, true, opts)})

      log_pass(job_stage, pass, cluster_stage, report, held)

      if cluster_stage >= job_stage and held == [] and quiet?(report) and
           pending_zero?(targets, opts) do
        complete(job_stage, pass)
      else
        continue(job_stage, snoozed, opts)
      end
    end
  end

  @doc """
  What remains to scrub, writing nothing: `in_scope` maps each target this code
  knows to the number of rows its scrub would still change, and
  `at_rest_until_stage_3` counts, by column name, the rows whose relay address
  columns are still set. Options: `:repo`, `:batch_size`.
  """
  @spec pending(keyword()) :: pending_report()
  def pending(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    %{
      in_scope: Map.new(@targets, &{&1.id, scrub_target(&1, false, opts).changed}),
      at_rest_until_stage_3:
        Map.new(@at_rest_columns, fn {name, table, column} ->
          {name, count_non_null(repo, table, column)}
        end)
    }
  end

  defp job_targets(job_stage), do: Enum.filter(@targets, &(&1.stage <= job_stage))

  defp quiet?(report),
    do: Enum.all?(report, fn {_id, counts} -> counts.changed == 0 and counts.skipped == 0 end)

  defp pending_zero?(targets, opts),
    do: Enum.all?(targets, &(scrub_target(&1, false, opts).changed == 0))

  defp complete(job_stage, pass) do
    Logger.info("Camera stream secret scrub stage #{job_stage} complete after #{pass} passes")

    :telemetry.execute(
      [:serviceradar, :camera, :stream_secret_scrub, :complete],
      %{passes: pass},
      %{stage: job_stage}
    )

    :ok
  end

  defp continue(job_stage, snoozed, opts) do
    if snoozed >= max_passes() do
      ids = MapSet.new(job_targets(job_stage), & &1.id)

      remaining =
        opts
        |> pending()
        |> Map.fetch!(:in_scope)
        |> Map.filter(&MapSet.member?(ids, elem(&1, 0)))

      Logger.error(
        "Camera stream secret scrub stage #{job_stage} incomplete after #{snoozed + 1} passes; " <>
          "pending #{inspect(remaining)}"
      )

      {:error, %{stage: job_stage, pending: remaining}}
    else
      {:snooze, repass_seconds()}
    end
  end

  defp log_pass(job_stage, pass, cluster_stage, report, held) do
    counts =
      Enum.map_join(report, " ", fn {id, counts} ->
        "#{id}=scanned:#{counts.scanned},changed:#{counts.changed},skipped:#{counts.skipped}"
      end)

    held_ids = Enum.map_join(held, ",", & &1.id)

    Logger.info(
      "Camera stream secret scrub stage #{job_stage} pass #{pass}: cluster_stage=#{cluster_stage} " <>
        "#{counts} held=[#{held_ids}]"
    )
  end

  defp cluster_scrub_stage(opts) do
    nodes = Keyword.get_lazy(opts, :core_nodes, &ProcessRegistry.core_nodes/0)
    multicall = Keyword.get(opts, :multicall, &:erpc.multicall/5)

    nodes
    |> multicall.(__MODULE__, :scrub_stage, [], @stage_rpc_timeout_ms)
    |> Enum.map(&reported_stage/1)
    |> Enum.min(fn -> @scrub_stage end)
    |> min(@scrub_stage)
  end

  defp reported_stage({:ok, stage}) when is_integer(stage) and stage >= 0, do: stage
  defp reported_stage(_result), do: 0

  defp repass_seconds,
    do: positive_setting(:camera_stream_scrub_repass_seconds, @default_repass_seconds)

  defp max_passes, do: positive_setting(:camera_stream_scrub_max_passes, @default_max_passes)

  defp positive_setting(key, default) do
    case Application.get_env(:serviceradar_core, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  # Scans one target in primary-key batches. With `apply?` it writes each changed
  # value; without, it only counts rows whose value the scrub would change.
  defp scrub_target(target, apply?, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    table = Map.fetch!(@tables, target.table)

    scan(repo, target, table, batch_size, apply?, nil, %{scanned: 0, changed: 0, skipped: 0})
  end

  defp scan(repo, target, table, batch_size, apply?, cursor, report) do
    case fetch_batch(repo, target, table, batch_size, cursor) do
      [] ->
        report

      rows ->
        report =
          Enum.reduce(rows, %{report | scanned: report.scanned + length(rows)}, fn row, acc ->
            tally(acc, scrub_row(repo, target, table, apply?, row))
          end)

        scan(repo, target, table, batch_size, apply?, List.last(rows).key, report)
    end
  end

  defp tally(report, :clean), do: report
  defp tally(report, :changed), do: %{report | changed: report.changed + 1}
  defp tally(report, :skipped), do: %{report | skipped: report.skipped + 1}

  defp scrub_row(repo, target, table, apply?, %{key: key, value: value}) do
    scrubbed = scrub_value(target.scrub, value)

    cond do
      scrubbed == value -> :clean
      not apply? -> :changed
      update_column(repo, target, table, key, value, scrubbed) -> :changed
      true -> :skipped
    end
  end

  defp fetch_batch(repo, target, table, batch_size, cursor) do
    key_columns = table.key
    key_count = length(key_columns)

    select_keys =
      key_columns
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {{name, type}, index} ->
        "#{read_cast(name, type)} AS k#{index}"
      end)

    {cursor_sql, cursor_params} = cursor_condition(key_columns, cursor)

    where =
      [cursor_sql, table.prefilter? && prefilter(target)]
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> ""
        conditions -> "WHERE " <> Enum.join(conditions, " AND ")
      end

    order = Enum.map_join(key_columns, ", ", fn {name, _type} -> name end)

    %{rows: rows} =
      repo.query!(
        """
        SELECT #{select_keys}, #{target.column} AS value
        FROM platform.#{target.table}
        #{where}
        ORDER BY #{order}
        LIMIT $#{length(cursor_params) + 1}
        """,
        cursor_params ++ [batch_size]
      )

    Enum.map(rows, fn row ->
      {keys, [value]} = Enum.split(row, key_count)
      %{key: keys, value: value}
    end)
  end

  defp cursor_condition(_key_columns, nil), do: {nil, []}

  defp cursor_condition(key_columns, cursor) do
    names = Enum.map_join(key_columns, ", ", &elem(&1, 0))

    params =
      key_columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{_name, type}, index} -> param_cast(index, type) end)

    {"(#{names}) > (#{params})", cursor}
  end

  defp prefilter(%{column: column} = target) do
    text = if target.type == "jsonb", do: "#{column}::text", else: column

    extra =
      if target.scrub == :device_metadata, do: " OR #{column} ? 'camera_source_url'", else: ""

    "(#{text} LIKE '%://%' OR strpos(#{text}, chr(92)) > 0 OR #{text} ILIKE '%alias%'#{extra})"
  end

  defp update_column(repo, target, table, key, old_value, new_value) do
    key_columns = table.key
    value_index = length(key_columns) + 1

    key_match =
      key_columns
      |> Enum.with_index(1)
      |> Enum.map_join(" AND ", fn {{name, type}, index} ->
        "#{name} = #{param_cast(index, type)}"
      end)

    %{num_rows: num_rows} =
      repo.query!(
        """
        UPDATE platform.#{target.table}
        SET #{target.column} = $#{value_index}::#{target.type}
        WHERE #{key_match}
          AND #{target.column} IS NOT DISTINCT FROM $#{value_index + 1}::#{target.type}
        """,
        key ++ [new_value, old_value]
      )

    num_rows == 1
  end

  defp read_cast(name, :uuid), do: "#{name}::text"
  defp read_cast(name, _type), do: name

  defp param_cast(index, :uuid), do: "$#{index}::text::uuid"
  defp param_cast(index, :timestamptz), do: "$#{index}::timestamptz"
  defp param_cast(index, :text), do: "$#{index}::text"

  defp count_non_null(repo, table, column) do
    %{rows: [[count]]} =
      repo.query!("SELECT count(*) FROM platform.#{table} WHERE #{column} IS NOT NULL", [])

    count
  end

  defp scrub_value(:reduce, value), do: StreamAddressReduction.reduce(value)

  defp scrub_value(:profile_metadata, metadata) when is_map(metadata) do
    metadata
    |> StreamAddressReduction.reduce()
    |> InventoryIngestor.allowed_profile_metadata()
  end

  defp scrub_value(:device_metadata, metadata) when is_map(metadata) do
    metadata
    |> Map.delete("camera_source_url")
    |> StreamAddressReduction.reduce()
  end

  defp scrub_value(:plugin_document, text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, document} when is_map(document) or is_list(document) ->
        case StreamAddressReduction.reduce(document) do
          ^document -> text
          reduced -> reduced |> recompute_digests(document) |> Jason.encode!()
        end

      _not_a_document ->
        StreamAddressReduction.reduce(text)
    end
  end

  defp scrub_value(_scrub, value), do: StreamAddressReduction.reduce(value)

  # A stored plugin result carries digests of its own payload. Where a digest
  # matched the payload as stored, it is recomputed over the reduced payload with
  # the function ingest uses, so a redelivery of the same result (now reduced on
  # entry) still finds the stored row and its handler markers.
  defp recompute_digests(reduced, original) when is_map(reduced) and is_map(original) do
    reduced
    |> recompute_reported_digest(original)
    |> recompute_downstream_digest(original)
  end

  defp recompute_digests(reduced, _original), do: reduced

  defp recompute_reported_digest(reduced, original) do
    key = PluginResultReportedMarker.marker_key()

    with %{"payload_digest" => digest} <- Map.get(original, key),
         true <- digest == PluginResultReportedMarker.payload_digest(Map.delete(original, key)),
         %{} = marker <- Map.get(reduced, key) do
      digest = PluginResultReportedMarker.payload_digest(Map.delete(reduced, key))
      Map.put(reduced, key, Map.put(marker, "payload_digest", digest))
    else
      _ -> reduced
    end
  end

  defp recompute_downstream_digest(reduced, original) do
    with %{"payload_digest" => digest} <- Map.get(original, "downstream_ingest"),
         true <- digest == reported_result_digest(Map.get(original, "reported_result")),
         %{} = downstream <- Map.get(reduced, "downstream_ingest") do
      digest = reported_result_digest(Map.get(reduced, "reported_result"))
      Map.put(reduced, "downstream_ingest", Map.put(downstream, "payload_digest", digest))
    else
      _ -> reduced
    end
  end

  defp reported_result_digest(result) when is_map(result),
    do:
      PluginResultReportedMarker.payload_digest(
        Map.delete(result, PluginResultReportedMarker.marker_key())
      )

  defp reported_result_digest(result) when is_list(result),
    do: PluginResultReportedMarker.payload_digest(result)

  defp reported_result_digest(_result), do: nil
end
