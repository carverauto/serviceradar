defmodule ServiceRadar.Inventory.ExposureSnapshotWorker do
  @moduledoc "Publishes one bounded generation from one finite, read-only MVCC snapshot."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:device_ord],
      states: :incomplete
    ]

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureRecovery
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Envelope
  alias ServiceRadar.Inventory.ExposurePublicationPrepareWorker
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo.DirectSession

  @lock_namespace 74_526
  @page_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    scope = args["device_ord"]

    cond do
      not Destination.enabled?() ->
        {:error, :starrocks_required}

      not is_nil(scope) and not (is_integer(scope) and scope in 1..4_294_967_295) ->
        {:cancel, :invalid_exposure_snapshot_scope}

      true ->
        DirectSession.run(&coordinate(&1, scope))
    end
  end

  defp coordinate(session, scope) do
    case Postgrex.query!(session, "SELECT pg_try_advisory_lock($1, 0)", [@lock_namespace]).rows do
      [[false]] ->
        {:snooze, 5}

      [[true]] ->
        case State.active() do
          {:ok, %{"status" => "publishing"} = old} ->
            # Acquiring the session lock proves that reader is gone. Its cursor
            # can never be used with the new transaction's snapshot.
            State.abort(old["id"], old["owner"], :reader_lost)
            {:snooze, 5}

          {:ok, _generation} ->
            {:snooze, 5}

          :none ->
            if State.unsettled?(), do: {:snooze, 5}, else: publish(session, scope)
        end
    end
  end

  @doc "A replacement owner may abort a lost reader, but never resume its cursor."
  def recover_reader do
    DirectSession.run(fn session ->
      case Postgrex.query!(session, "SELECT pg_try_advisory_lock($1, 0)", [@lock_namespace]).rows do
        [[true]] ->
          case State.active() do
            {:ok, %{"status" => "publishing"} = old} ->
              with {:ok, :ok} <- State.abort(old["id"], old["owner"], :reader_lost) do
                args = if old["scope"], do: %{"device_ord" => old["scope"]}, else: %{}
                with {:ok, _} <- args |> new() |> Oban.insert(), do: :ok
              end

            _ ->
              :ok
          end

        [[false]] ->
          :ok
      end
    end)
  end

  defp publish(session, scope) do
    timeout = Application.get_env(:serviceradar_core, :exposure_snapshot_timeout_ms, 300_000)
    timeout = min(max(timeout, 1_000), 900_000)
    deadline = System.system_time(:millisecond) + timeout
    owner = Ecto.UUID.generate()

    with :ok <- ExposureRecovery.ensure_stream() do
      # Set defaults before BEGIN: pg_current_snapshot is the first statement
      # inside the read-only transaction, and the transaction connection cannot
      # reconnect and silently resume under a different view.
      Postgrex.query!(
        session,
        "SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
        []
      )

      Postgrex.query!(session, "SELECT set_config('statement_timeout', $1, false)", [
        to_string(timeout)
      ])

      try do
        case Postgrex.transaction(
               session,
               fn reader ->
                 [[snapshot]] =
                   Postgrex.query!(reader, "SELECT pg_current_snapshot()::text", []).rows

                 with :ok <- prerequisites(reader, scope),
                      {:ok, generation} <- State.create(scope, snapshot, owner, deadline),
                      :ok <- start(generation),
                      :ok <- publish_source(reader, generation, "dimensions", nil),
                      :ok <- await(generation, &(&1["pending"] == %{})),
                      {:ok, :ok} <- State.phase(generation["id"], owner, "lifecycle"),
                      :ok <- publish_source(reader, generation, "lifecycle", nil),
                      :ok <- await(generation, &(&1["pending"] == %{})),
                      {:ok, :ok} <- State.phase(generation["id"], owner, "facts"),
                      :ok <- publish_source(reader, generation, "assessments", nil),
                      :ok <- publish_source(reader, generation, "watermarks", nil),
                      :ok <- await(generation, &(&1["pending"] == %{})),
                      {:ok, latest} <- State.get(generation["id"]),
                      :ok <- alive(reader, generation),
                      {:ok, completed} <-
                        State.end_manifest(generation["id"], owner, latest["receipts"]) do
                   completed
                 else
                   {:error, reason} -> Postgrex.rollback(reader, reason)
                 end
               end,
               timeout: timeout
             ) do
          {:ok, generation} ->
            publish_end(generation)

          {:error, :exposure_snapshot_preparation_required} ->
            %{} |> ExposurePublicationPrepareWorker.new() |> Oban.insert()
            {:snooze, 30}

          {:error, reason} ->
            {:error, reason}
        end
      after
        case State.active() do
          {:ok, %{"status" => "publishing", "owner" => ^owner} = generation} ->
            State.abort(generation["id"], owner, :reader_incomplete)

          _ ->
            :ok
        end
      end
    end
  end

  def publish_end(generation) do
    marker = generation |> marker("end") |> Map.put("manifest", generation["manifest"])

    with {:ok, body, hash} <- Envelope.encode(marker),
         {:ok, _} <-
           ExposureRecovery.retain_envelope(control_subject(generation, "end"), body, hash) do
      :ok
    end
  end

  defp start(generation) do
    marker = generation |> marker("start") |> Map.put("snapshot", generation["snapshot"])

    with {:ok, body, hash} <- Envelope.encode(marker),
         {:ok, _} <-
           ExposureRecovery.retain_envelope(control_subject(generation, "start"), body, hash) do
      await(generation, & &1["started"])
    end
  end

  defp marker(generation, kind) do
    %{
      "version" => 1,
      "generation" => generation["id"],
      "scope" => generation["scope"],
      "fence" => Envelope.digest(generation["snapshot"]),
      "kind" => kind
    }
  end

  defp control_subject(generation, kind), do: "exposure.snapshots.#{generation["id"]}.#{kind}"

  defp publish_source(reader, generation, stage, cursor) do
    with :ok <- alive(reader, generation),
         {:ok, rows} <- source_page(reader, stage, generation["scope"], cursor) do
      case rows do
        [] ->
          :ok

        _ ->
          with :ok <- publish_rows(generation, stage, rows) do
            [next, _payload] = List.last(rows)
            publish_source(reader, generation, stage, next)
          end
      end
    end
  end

  defp publish_rows(generation, stage, rows) do
    phase = if stage in ["assessments", "watermarks"], do: "facts", else: stage

    rows
    |> Enum.map(fn [_cursor, payload] -> payload end)
    |> Enum.group_by(fn payload ->
      if stage == "dimensions" do
        payload["dimension"]
      else
        bucket =
          payload["device_uid"]
          |> ExposureTransitionRelay.subject()
          |> String.split(".")
          |> List.last()

        "device-#{bucket}"
      end
    end)
    |> Enum.reduce_while(:ok, fn {lane, records}, :ok ->
      with :ok <- await(generation, &is_nil(&1["pending"][lane])),
           {:ok, current} <- State.get(generation["id"]),
           {:ok, pages} <-
             Envelope.split(generation, lane, current["receipts"][lane], phase, records),
           :ok <- publish_pages(generation, lane, pages) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp publish_pages(generation, lane, pages) do
    Enum.reduce_while(pages, :ok, fn {envelope, body, hash}, :ok ->
      with :ok <- await(generation, &is_nil(&1["pending"][lane])),
           {:ok, pending} <- State.reserve(generation["id"], generation["owner"], envelope, hash),
           {:ok, _position} <- ExposureRecovery.retain_envelope(pending["subject"], body, hash) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp await(generation, ready) do
    with {:ok, state} <- State.get(generation["id"]),
         :ok <- State.publishing(state, generation["owner"]) do
      if ready.(state) do
        :ok
      else
        Process.sleep(100)
        await(generation, ready)
      end
    end
  end

  defp alive(reader, generation) do
    with {:ok, state} <- State.get(generation["id"]),
         :ok <- State.publishing(state, generation["owner"]),
         {:ok, %{rows: [[true]]}} <-
           Postgrex.query(
             reader,
             """
             SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory'
               AND pid = pg_backend_pid() AND granted AND classid::bigint = $1
               AND objid = 0 AND objsubid = 2)
             """,
             [@lock_namespace]
           ) do
      :ok
    else
      _ -> {:error, :exposure_snapshot_reader_lost}
    end
  end

  defp prerequisites(reader, scope) do
    sql = """
    SELECT EXISTS (
      SELECT 1 FROM platform.device_fleet_ordinals o
      WHERE ($1::bigint IS NULL OR o.ordinal = $1) AND (
        (o.tombstoned AND o.lifecycle_seq = 0) OR
        EXISTS (SELECT 1 FROM platform.exposure_device_refreshes r WHERE r.device_uid = o.uid))
    ) OR EXISTS (
      SELECT 1 FROM platform.endpoint_vulnerability_assessments a
      LEFT JOIN platform.device_fleet_ordinals o ON o.uid = a.device_uid
      WHERE NOT COALESCE(o.tombstoned, false) AND ($1::bigint IS NULL OR o.ordinal = $1)
        AND (o.ordinal IS NULL OR a.last_exposure_publication IS NULL OR
          (a.last_exposure_publication->>'device_ord')::bigint IS DISTINCT FROM o.ordinal OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'cve'
            AND d.ordinal = (a.last_exposure_publication->>'cve_ord')::bigint) OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'package'
            AND d.ordinal = (a.last_exposure_publication->>'pkgver_ord')::bigint))
    ) OR EXISTS (
      SELECT 1 FROM platform.exposure_fact_watermarks w
      LEFT JOIN platform.device_fleet_ordinals o ON o.uid = w.device_uid
      WHERE NOT COALESCE(o.tombstoned, false) AND ($1::bigint IS NULL OR o.ordinal = $1)
        AND (o.ordinal IS NULL OR w.payload IS NULL OR
          (w.payload->>'device_ord')::bigint IS DISTINCT FROM o.ordinal OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'cve'
            AND d.ordinal = (w.payload->>'cve_ord')::bigint) OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'package'
            AND d.ordinal = (w.payload->>'pkgver_ord')::bigint))
    )
    """

    case Postgrex.query(reader, sql, [scope]) do
      {:ok, %{rows: [[false]]}} -> :ok
      {:ok, %{rows: [[true]]}} -> {:error, :exposure_snapshot_preparation_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_page(reader, "dimensions", scope, cursor) do
    [kind, ordinal] = cursor || ["", 0]

    query(
      reader,
      """
      SELECT jsonb_build_array(d.kind, d.ordinal), d.payload FROM platform.exposure_dimension_state d
      WHERE (d.kind, d.ordinal) > ($1, $2) AND ($3::bigint IS NULL OR EXISTS (
        SELECT 1 FROM platform.device_fleet_ordinals o
        JOIN platform.endpoint_vulnerability_assessments a ON a.device_uid = o.uid
        WHERE o.ordinal = $3 AND d.ordinal = (a.last_exposure_publication->>
          CASE d.kind WHEN 'cve' THEN 'cve_ord' ELSE 'pkgver_ord' END)::bigint
      ) OR EXISTS (
        SELECT 1 FROM platform.device_fleet_ordinals o
        JOIN platform.exposure_fact_watermarks w ON w.device_uid = o.uid
        WHERE o.ordinal = $3 AND d.ordinal = (w.payload->>
          CASE d.kind WHEN 'cve' THEN 'cve_ord' ELSE 'pkgver_ord' END)::bigint
      )) ORDER BY d.kind, d.ordinal LIMIT #{@page_size}
      """,
      [kind, ordinal, scope]
    )
  end

  defp source_page(reader, "lifecycle", scope, cursor) do
    query(
      reader,
      """
      SELECT ordinal, jsonb_build_object(
        'schema_version', 1, 'device_uid', uid, 'device_ord', ordinal,
        'event_type', CASE WHEN tombstoned THEN 'device_retired' ELSE 'device_restored' END,
        'state', CASE WHEN tombstoned THEN 'retired' ELSE 'live' END,
        'transition_seq', lifecycle_seq, 'device_lifecycle_seq', lifecycle_seq,
        'transition_xid', lifecycle_xid::text::numeric, 'changed_at', lifecycle_at,
        'retired_seq', retired_seq, 'retired_xid', retired_xid::text::numeric, 'retired_at', retired_at)
      FROM platform.device_fleet_ordinals WHERE ordinal > $1 AND lifecycle_seq > 0
        AND ($2::bigint IS NULL OR ordinal = $2) ORDER BY ordinal LIMIT #{@page_size}
      """,
      [cursor || 0, scope]
    )
  end

  defp source_page(reader, "assessments", scope, cursor) do
    query(
      reader,
      """
      SELECT a.id::text, a.last_exposure_publication
      FROM platform.endpoint_vulnerability_assessments a
      JOIN platform.device_fleet_ordinals o ON o.uid = a.device_uid
      WHERE a.id > $1::text::uuid AND NOT o.tombstoned
        AND ($2::bigint IS NULL OR o.ordinal = $2) ORDER BY a.id LIMIT #{@page_size}
      """,
      [cursor || "00000000-0000-0000-0000-000000000000", scope]
    )
  end

  defp source_page(reader, "watermarks", scope, cursor) do
    [uid, package, cve] = cursor || ["", "", ""]

    query(
      reader,
      """
      SELECT jsonb_build_array(w.device_uid, w.package_identity_key, w.cve_id), w.payload
      FROM platform.exposure_fact_watermarks w
      JOIN platform.device_fleet_ordinals o ON o.uid = w.device_uid
      WHERE (w.device_uid, w.package_identity_key, w.cve_id) > ($1, $2, $3)
        AND NOT o.tombstoned AND ($4::bigint IS NULL OR o.ordinal = $4)
      ORDER BY w.device_uid, w.package_identity_key, w.cve_id LIMIT #{@page_size}
      """,
      [uid, package, cve, scope]
    )
  end

  defp query(reader, sql, params) do
    with {:ok, %{rows: rows}} <- Postgrex.query(reader, sql, params), do: {:ok, rows}
  end
end
