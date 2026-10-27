defmodule ServiceRadar.Inventory.ExposureReconciliationComparison do
  @moduledoc "One bounded per-device source view compared with paged warehouse state."
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.EventWriter.Processors.ExposureDimensions
  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.Inventory.ExposureReconciliationDigest, as: Digest
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Publisher

  @timeout 60_000

  def run(session, ordinal) do
    Postgrex.query!(
      session,
      "SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
      []
    )

    Postgrex.query!(session, "SET statement_timeout = '30s'", [])
    deadline = System.monotonic_time(:millisecond) + @timeout

    case Postgrex.transaction(
           session,
           fn reader ->
             [[snapshot, started_at]] =
               Postgrex.query!(
                 reader,
                 "SELECT pg_current_snapshot()::text, now() AT TIME ZONE 'utc'",
                 []
               ).rows

             with :ok <- Publisher.prerequisites(reader, ordinal),
                  :ok <- lifecycle(reader, ordinal),
                  :ok <- dimensions(reader, ordinal, nil, deadline),
                  {:ok, source} <- assessments(reader, ordinal, nil, Digest.empty(), deadline),
                  {:ok, stored} <- warehouse(ordinal, [0, 0, 0], Digest.empty(), deadline) do
               {:ok,
                %{
                  "source" => Digest.export(source),
                  "warehouse" => Digest.export(stored),
                  "snapshot" => snapshot,
                  "started_at" => NaiveDateTime.to_iso8601(started_at),
                  "matches" => source == stored
                }}
             end
           end,
           timeout: @timeout + 5_000
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp lifecycle(reader, ordinal) do
    case Postgrex.query!(
           reader,
           "SELECT platform.exposure_lifecycle_publication(ordinal) FROM platform.device_fleet_ordinals WHERE ordinal = $1",
           [ordinal]
         ).rows do
      [] ->
        {:error, :exposure_reconciliation_dictionary_missing}

      [[nil]] ->
        with {:ok, rows} <- Warehouse.read("lifecycle", [ordinal]) do
          if map_size(rows) == 0,
            do: :ok,
            else: {:error, :exposure_reconciliation_lifecycle_conflict}
        end

      [[publication]] ->
        with {:ok, [%{row: expected}]} <- ExposureTransitions.decode([message(publication)]),
             {:ok, rows} <- Warehouse.read("lifecycle", [ordinal]) do
          compare_rows("lifecycle", [{ordinal, expected}], rows)
        end
    end
  end

  defp dimensions(reader, ordinal, cursor, deadline) do
    with :ok <- within_deadline(deadline),
         {:ok, rows} <- Publisher.source_page(reader, "dimensions", ordinal, cursor),
         :ok <- compare_dimensions(rows) do
      case rows do
        [] ->
          :ok

        _ ->
          [next, _] = List.last(rows)
          dimensions(reader, ordinal, next, deadline)
      end
    end
  end

  defp compare_dimensions(rows) do
    rows
    |> Enum.group_by(fn [[kind, _], _] -> kind end)
    |> Enum.reduce_while(:ok, fn {kind, group}, :ok ->
      with {:ok, decoded} <-
             ExposureDimensions.decode(Enum.map(group, fn [_, body] -> message(body) end)),
           expected = Enum.map(decoded, fn {_, key, row} -> {key, row} end),
           {:ok, stored} <- Warehouse.read(kind, Enum.map(expected, &elem(&1, 0))),
           :ok <- compare_rows(kind, expected, stored) do
        {:cont, :ok}
      else
        result -> {:halt, result}
      end
    end)
  end

  defp compare_rows(kind, expected, stored) do
    repairs =
      Enum.flat_map(expected, fn {key, row} ->
        current = stored[key]

        if current && Warehouse.row_digest(kind, current) == Warehouse.row_digest(kind, row) do
          []
        else
          [
            %{
              "kind" => kind,
              "key" => key,
              "observed" => (current && current["transition_seq"]) || 0
            }
          ]
        end
      end)

    if repairs == [], do: :ok, else: {:repair, repairs}
  end

  defp assessments(reader, ordinal, cursor, acc, deadline) do
    with :ok <- within_deadline(deadline),
         {:ok, %{rows: rows}} <-
           Postgrex.query(
             reader,
             """
             SELECT a.id::text, a.last_exposure_publication,
               a.last_exposure_publication || jsonb_build_object(
                 'transition_seq', a.last_transition_seq, 'device_lifecycle_seq', o.lifecycle_seq,
                 'state', CASE WHEN platform.exposure_assessment_actionable(a.status,a.assessment,a.disposition)
                   THEN 'active' ELSE 'resolved' END,
                 'pkgver_ord', v.ordinal, 'source_scope', a.source_scope,
                 'severity', a.severity, 'cvss_score', a.cvss_score, 'kev', a.kev,
                 'exploit_available', a.exploit_available,
                 'fix_available', COALESCE(btrim(a.fixed_version), '') <> '')
             FROM platform.endpoint_vulnerability_assessments a
             JOIN platform.device_fleet_ordinals o ON o.uid = a.device_uid
             LEFT JOIN platform.exposure_package_version_ordinals v
               ON v.package_identity_key = a.package_identity_key
               AND v.installed_version = COALESCE(a.installed_version, '')
             WHERE o.ordinal = $1 AND NOT o.tombstoned AND a.id > $2::text::uuid
             ORDER BY a.id LIMIT 500
             """,
             [ordinal, cursor || "00000000-0000-0000-0000-000000000000"]
           ),
         {:ok, next_acc} <- source_digest(rows, acc) do
      case rows do
        [] -> {:ok, next_acc}
        _ -> assessments(reader, ordinal, hd(List.last(rows)), next_acc, deadline)
      end
    end
  end

  defp source_digest(rows, acc) do
    Enum.reduce_while(rows, {:ok, acc}, fn [_id, retained, current], {:ok, digest} ->
      with {:ok, [%{fact: fact}]} <- ExposureTransitions.decode([message(current)]),
           {:ok, [%{fact: replay}]} <- ExposureTransitions.decode([message(retained)]),
           true <- Digest.add(Digest.empty(), fact) == Digest.add(Digest.empty(), replay) do
        {:cont, {:ok, Digest.add(digest, fact)}}
      else
        _ ->
          # The comparison is read-only. The worker re-reads under source locks
          # in a fresh transaction before assigning and retaining this repair.
          {:halt,
           {:repair,
            [
              %{
                "key" => Warehouse.key(retained),
                "source" => Enum.map(~w(device_uid package_identity_key cve_id), &retained[&1]),
                "observed" => retained["transition_seq"]
              }
            ]}}
      end
    end)
  end

  defp warehouse(ordinal, cursor, acc, deadline) do
    with :ok <- within_deadline(deadline),
         {:ok, rows} <- Warehouse.scan(ordinal, cursor) do
      case rows do
        [] ->
          {:ok, acc}

        _ ->
          warehouse(
            ordinal,
            Warehouse.key(List.last(rows)),
            Enum.reduce(rows, acc, &Digest.add(&2, &1)),
            deadline
          )
      end
    end
  end

  defp within_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: {:error, :exposure_reconciliation_deadline}
  end

  defp message(body), do: %{data: Jason.encode!(body)}
end
