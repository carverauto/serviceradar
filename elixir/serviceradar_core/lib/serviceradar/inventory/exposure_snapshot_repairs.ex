defmodule ServiceRadar.Inventory.ExposureSnapshotRepairs do
  @moduledoc "Source-locked repair obligations; only warehouse evidence discharges them."
  alias ServiceRadar.EventWriter.ExposureFactPayload
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.EventWriter.Processors.ExposureDimensions
  alias ServiceRadar.EventWriter.Processors.ExposureTransitions
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Repo

  def page(id, lane, hash) do
    with {:ok, :ok} <-
           State.update_pending(id, lane, hash, fn _state, pending ->
             with {:ok, repairs} <- publish(pending["repairs"]) do
               {:ok, Map.put(pending, "repairs", repairs), :ok}
             end
           end),
         {:ok, generation} <- State.get(id),
         pending = generation["pending"][lane],
         {:ok, remaining} <- verify(pending["repairs"]),
         {:ok, :ok} <-
           State.update_pending(id, lane, hash, fn _state, current ->
             if current["repairs"] == pending["repairs"] do
               {:ok, Map.put(current, "repairs", remaining), :ok}
             else
               {:error, :exposure_snapshot_repair_changed}
             end
           end) do
      if remaining == [], do: :ok, else: {:error, :exposure_snapshot_repairs_pending}
    end
  end

  @doc "Called inside the transaction that persists the resulting required sequence."
  def publish(repairs) do
    Repo.query!("SET LOCAL lock_timeout = '2s'")

    Enum.reduce_while(repairs, {:ok, []}, fn repair, {:ok, assigned} ->
      case publish_one(repair) do
        {:ok, next} -> {:cont, {:ok, [next | assigned]}}
        error -> {:halt, error}
      end
    end)
  end

  defp publish_one(%{"kind" => kind, "key" => key} = repair) when kind in ["cve", "package"] do
    [[publication]] =
      Repo.query!("SELECT platform.exposure_repair_dimension($1,$2,$3)", [
        kind,
        key,
        repair["observed"]
      ]).rows

    with {:ok, next} <- assign(repair, kind, publication) do
      # Replay current content without moving an assigned proof target: its
      # warehouse row may already be confirmed while a live update is in flight.
      {:ok, if(is_integer(repair["required"]), do: repair, else: next)}
    end
  end

  defp publish_one(%{"required" => required} = repair) when is_integer(required),
    do: {:ok, repair}

  defp publish_one(%{"kind" => "lifecycle", "key" => key} = repair) do
    [[publication]] =
      Repo.query!("SELECT platform.exposure_repair_lifecycle($1,$2)", [
        key,
        repair["observed"]
      ]).rows

    assign(repair, "lifecycle", publication)
  end

  defp publish_one(%{"source" => [uid, package, cve]} = repair) do
    [[publication]] =
      Repo.query!(
        "SELECT platform.exposure_repair_publication($1,$2,$3,$4,false)",
        [uid, package, cve, repair["observed"]]
      ).rows

    if is_map(publication) do
      # The existing terminal path can return an already-retained publication.
      # Queue that exact publication too: its previous PubAck is not delivery
      # evidence after an out-of-band warehouse deletion.
      Repo.query!("SELECT platform.exposure_enqueue_publication($1)", [publication])
      assign(repair, "fact", publication)
    else
      [ordinal, _, _] = repair["key"]

      [[marker]] =
        Repo.query!(
          "SELECT platform.exposure_repair_lifecycle($1,$2)",
          [ordinal, repair["observed"]]
        ).rows

      if is_map(marker) and marker["state"] == "retired" do
        {:ok,
         repair
         |> Map.put("kind", "retired_fact")
         |> Map.put("required", marker["transition_seq"])}
      else
        {:error, :exposure_snapshot_source_unavailable}
      end
    end
  end

  defp assign(repair, kind, publication) when is_map(publication) do
    with {:ok, row} <- decode(kind, publication) do
      {:ok,
       repair
       |> Map.put("kind", kind)
       |> Map.put("required", publication["transition_seq"])
       |> Map.put("expected", Warehouse.row_digest(kind, row))}
    end
  end

  defp assign(_repair, _kind, _publication), do: {:error, :exposure_snapshot_source_unavailable}

  defp decode(kind, publication) when kind in ["cve", "package"] do
    with {:ok, [{_, _, row}]} <- ExposureDimensions.decode([%{data: Jason.encode!(publication)}]),
         do: {:ok, row}
  end

  defp decode(kind, publication) do
    with {:ok, [event]} <- ExposureTransitions.decode([%{data: Jason.encode!(publication)}]) do
      case {kind, event} do
        {"fact", %{kind: :fact, fact: row}} -> {:ok, row}
        {"lifecycle", %{kind: :lifecycle, row: row}} -> {:ok, row}
        _ -> {:error, :exposure_snapshot_repair_kind_conflict}
      end
    end
  end

  def verify([]), do: {:ok, []}

  def verify(repairs) do
    repairs
    |> Enum.group_by(fn repair ->
      case repair["kind"] do
        nil -> "fact"
        "retired_fact" -> "fact"
        kind -> kind
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn {kind, group}, {:ok, remaining} ->
      case Warehouse.read(kind, Enum.map(group, & &1["key"])) do
        {:ok, current} ->
          pending = Enum.reject(group, &verified?(&1, current[&1["key"]]))
          {:cont, {:ok, pending ++ remaining}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp verified?(%{"kind" => "retired_fact"} = repair, row) do
    retirement_matches?(repair, row) or
      (is_map(row) and row["transition_seq"] > repair["required"] and
         current_publication_matches?(repair, row))
  end

  defp verified?(_repair, nil), do: false

  defp verified?(%{"required" => required, "expected" => expected} = repair, row) do
    kind = repair["kind"] || "fact"

    cond do
      row["transition_seq"] == required ->
        Warehouse.row_digest(kind, row) == expected or
          (kind == "fact" and ExposureFactPayload.compacted?(row) and
             current_publication_matches?(repair, row))

      row["transition_seq"] > required ->
        current_publication_matches?(repair, row) or
          (kind == "fact" and retirement_matches?(repair, row))

      true ->
        false
    end
  end

  defp verified?(_repair, _row), do: false

  defp retirement_matches?(%{"key" => [ordinal, _, _], "required" => required}, row) do
    [[publication]] =
      Repo.query!("SELECT platform.exposure_lifecycle_publication($1)", [ordinal]).rows

    with true <- is_map(publication) and publication["transition_seq"] >= required,
         {:ok, source} <- decode("lifecycle", publication),
         {:ok, states} <- Warehouse.read("lifecycle", [ordinal]),
         stored when is_map(stored) <- states[ordinal],
         true <-
           Warehouse.row_digest("lifecycle", stored) == Warehouse.row_digest("lifecycle", source) do
      (is_nil(row) and stored["state"] == 2) or
        (is_map(row) and row["state"] == 2 and row["transition_seq"] == stored["retired_seq"] and
           row["transition_xid"] == stored["retired_xid"] and stored["retired_seq"] >= required)
    else
      _ -> false
    end
  end

  @doc "A retired row is covered only by a matching retained source and warehouse fence."
  def covered_retirements(rows) do
    retired = Enum.filter(rows, &(&1["state"] == 2))
    ordinals = retired |> Enum.map(& &1["device_ord"]) |> Enum.uniq()

    with {:ok, stored} <- Warehouse.read("lifecycle", ordinals) do
      source =
        Map.new(
          Repo.query!(
            """
            SELECT ordinal, platform.exposure_lifecycle_publication(ordinal)
            FROM platform.device_fleet_ordinals WHERE ordinal = ANY($1::bigint[])
            """,
            [ordinals]
          ).rows,
          fn [key, publication] -> {key, publication} end
        )

      covered =
        Enum.filter(retired, fn row ->
          marker = stored[row["device_ord"]]

          with true <- is_map(marker),
               {:ok, retained} <- decode("lifecycle", source[row["device_ord"]]) do
            Warehouse.row_digest("lifecycle", retained) ==
              Warehouse.row_digest("lifecycle", marker) and
              row["transition_seq"] == marker["retired_seq"] and
              row["transition_xid"] == marker["retired_xid"]
          else
            _ -> false
          end
        end)

      {:ok, MapSet.new(covered, &Warehouse.key/1)}
    end
  end

  defp current_publication_matches?(%{"kind" => kind, "key" => key}, row)
       when kind in ["cve", "package", "lifecycle"] do
    publications =
      if kind == "lifecycle" do
        Repo.query!("SELECT platform.exposure_lifecycle_publication($1)", [key]).rows
      else
        Repo.query!(
          "SELECT payload FROM platform.exposure_dimension_state WHERE kind = $1 AND ordinal = $2",
          [kind, key]
        ).rows
      end

    Enum.any?(publications, fn [publication] ->
      case decode(kind, publication) do
        {:ok, source} -> Warehouse.row_digest(kind, source) == Warehouse.row_digest(kind, row)
        _ -> false
      end
    end)
  end

  defp current_publication_matches?(%{"source" => [uid, package, cve]}, row) do
    publications =
      Repo.query!(
        """
        SELECT last_exposure_publication FROM platform.endpoint_vulnerability_assessments
        WHERE device_uid = $1 AND package_identity_key = $2 AND cve_id = $3
        UNION ALL SELECT payload FROM platform.exposure_fact_watermarks
        WHERE device_uid = $1 AND package_identity_key = $2 AND cve_id = $3
        """,
        [uid, package, cve]
      ).rows

    Enum.any?(publications, fn
      [publication] when is_map(publication) ->
        case ExposureTransitions.decode([%{data: Jason.encode!(publication)}]) do
          {:ok, [%{fact: fact}]} -> Warehouse.identical_fact?(fact, row)
          _ -> false
        end

      _ ->
        false
    end)
  end

  def for_fact(fact) do
    [device, cve, package] = Warehouse.key(fact)

    case Repo.query!(
           """
           SELECT o.uid, p.package_identity_key,
             COALESCE(a.advisory_id, d.payload->>'cve_id',
               CASE WHEN $2 > 0 AND $2 < 100000000000 THEN
                 'CVE-' || lpad(($2 / 10000000)::text, 4, '0') || '-' ||
                 CASE WHEN $2 % 10000000 < 10000 THEN lpad(($2 % 10000000)::text, 4, '0')
                   ELSE ($2 % 10000000)::text END END)
           FROM platform.device_fleet_ordinals o
           CROSS JOIN platform.exposure_package_ordinals p
           LEFT JOIN platform.exposure_advisory_ordinals a ON a.ordinal = $2
           LEFT JOIN platform.exposure_dimension_state d ON d.kind = 'cve' AND d.ordinal = $2
           WHERE o.ordinal = $1 AND p.ordinal = $3
           """,
           [device, cve, package]
         ).rows do
      [[uid, package, cve]] when is_binary(cve) ->
        {:ok,
         %{
           "key" => Warehouse.key(fact),
           "source" => [uid, package, cve],
           "observed" => fact["transition_seq"]
         }}

      _ ->
        {:error, :exposure_snapshot_dictionary_missing}
    end
  end
end
