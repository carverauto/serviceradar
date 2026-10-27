defmodule ServiceRadar.Inventory.ExposureSnapshotFinalizer do
  @moduledoc "Bounded end-manifest scan. Dispatching repairs is not completion evidence."
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.Inventory.ExposureSnapshotRepairs, as: Repairs
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Publisher
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo

  def step(id) do
    with {:ok, generation} <- State.get(id),
         true <- generation["status"] == "finalizing",
         true <- generation["receipts"] == generation["manifest"] and generation["pending"] == %{} do
      case custody(generation) do
        :gap ->
          abort_for_gap(id)

        _ ->
          if generation["repairs"] == [] do
            scan(generation)
          else
            settle(generation)
          end
      end
    else
      false -> {:error, :exposure_snapshot_incomplete}
      error -> error
    end
  end

  defp scan(generation) do
    with {:ok, rows} <- Warehouse.scan(generation["scope"], generation["cursor"]) do
      case rows do
        [] ->
          complete(generation)

        _ ->
          visible = Warehouse.visibility(rows, generation["snapshot"])

          candidates =
            Enum.filter(rows, fn row ->
              row["snapshot_generation"] < generation["id"] and visible[row["transition_xid"]]
            end)

          with {:ok, covered} <- Repairs.covered_retirements(candidates),
               {:ok, repairs} <-
                 repair_requests(
                   Enum.reject(candidates, &MapSet.member?(covered, Warehouse.key(&1)))
                 ),
               {:ok, :ok} <-
                 State.change(generation["id"], fn current ->
                   if current["status"] == "finalizing" and
                        current["cursor"] == generation["cursor"] and
                        current["repairs"] == [] do
                     next =
                       current
                       |> Map.put("cursor", Warehouse.key(List.last(rows)))
                       |> Map.put("repairs", repairs)

                     {:ok, next, :ok}
                   else
                     {:error, :exposure_snapshot_finalizer_changed}
                   end
                 end) do
            {:error, :exposure_snapshot_finalization_pending}
          end
      end
    end
  end

  defp repair_requests(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, repairs} ->
      case Repairs.for_fact(row) do
        {:ok, repair} -> {:cont, {:ok, [repair | repairs]}}
        error -> {:halt, error}
      end
    end)
  end

  def recover(scope) do
    case Repo.query!(
           """
           SELECT id FROM platform.exposure_snapshot_generations
           WHERE status = 'aborted' AND jsonb_array_length(control->'repairs') > 0
             AND ($1::bigint IS NULL OR control->>'scope' IS NULL OR (control->>'scope')::bigint = $1)
           ORDER BY id LIMIT 1
           """,
           [scope]
         ).rows do
      [] ->
        :ok

      [[id]] ->
        with {:ok, generation} <- State.get(id), do: settle(generation)
    end
  end

  defp settle(generation) do
    with {:ok, repairs} <-
           State.change(generation["id"], fn current ->
             if current["status"] == generation["status"] and
                  current["repairs"] == generation["repairs"] do
               with {:ok, assigned} <- Repairs.publish(current["repairs"]) do
                 {:ok, Map.put(current, "repairs", assigned), assigned}
               end
             else
               {:error, :exposure_snapshot_finalizer_changed}
             end
           end),
         {:ok, remaining} <- Repairs.verify(repairs),
         {:ok, :ok} <-
           State.change(generation["id"], fn current ->
             if current["status"] == generation["status"] and current["repairs"] == repairs do
               {:ok, Map.put(current, "repairs", remaining), :ok}
             else
               {:error, :exposure_snapshot_finalizer_changed}
             end
           end) do
      if remaining == [], do: :ok, else: {:error, :exposure_snapshot_repairs_pending}
    end
  end

  def fence(state) do
    Map.put_new(state, "retained_operations", applying_operation_ids(state["scope"]))
  end

  defp complete(generation) do
    generation["id"]
    |> State.change(fn current ->
      decision = custody(current)

      cond do
        current["status"] != "finalizing" or current["cursor"] != generation["cursor"] or
          current["repairs"] != [] or current["pending"] != %{} ->
          {:error, :exposure_snapshot_finalization_pending}

        decision == :gap ->
          {:ok, abort(current), :gap}

        decision == :clear ->
          {:ok, Map.put(current, "status", "complete"), :ok}

        true ->
          {:error, :exposure_snapshot_finalization_pending}
      end
    end)
    |> finish()
  end

  defp abort_for_gap(id) do
    id
    |> State.change(fn current ->
      if current["status"] == "finalizing" and current["pending"] == %{} and
           custody(current) == :gap do
        {:ok, abort(current), :gap}
      else
        {:error, :exposure_snapshot_finalization_pending}
      end
    end)
    |> finish()
  end

  defp finish({:ok, :ok}), do: :ok

  defp finish({:ok, :gap}) do
    queue_full_generation()
    {:error, :exposure_snapshot_input_missing}
  end

  defp finish(error), do: error

  defp abort(current) do
    current
    |> Map.put("status", "aborted")
    |> Map.put("abort_reason", "exposure_snapshot_required")
  end

  defp custody(current) do
    case device_bucket(current["scope"]) do
      :absent ->
        :clear

      bucket ->
        cond do
          phase?(bucket, "legacy") ->
            :blocked

          fenced_applying?(bucket, Map.get(current, "retained_operations", [])) ->
            :blocked

          phase?(bucket, "snapshot_required") ->
            :gap

          true ->
            :clear
        end
    end
  end

  defp applying_operation_ids(scope) do
    case device_bucket(scope) do
      :absent ->
        []

      bucket ->
        {clause, params} = bucket_clause(bucket, 1)

        List.flatten(
          Repo.query!(
            """
            SELECT operation_id::text
            FROM platform.exposure_delivery_batches
            WHERE phase = 'applying' AND operation_id IS NOT NULL
            #{clause}
            """,
            params
          ).rows
        )
    end
  end

  defp fenced_applying?(_bucket, []), do: false

  defp fenced_applying?(bucket, operation_ids) do
    {clause, params} = bucket_clause(bucket, 2)

    Repo.query!(
      """
      SELECT 1 FROM platform.exposure_delivery_batches
      WHERE phase = 'applying' AND operation_id::text = ANY($1::text[])
      #{clause}
      LIMIT 1
      """,
      [operation_ids | params]
    ).rows != []
  end

  defp phase?(bucket, phase) do
    {clause, params} = bucket_clause(bucket, 2)

    Repo.query!(
      """
      SELECT 1 FROM platform.exposure_delivery_batches
      WHERE phase = $1
      #{clause}
      LIMIT 1
      """,
      [phase | params]
    ).rows != []
  end

  defp bucket_clause(:deployment, _index), do: {"", []}

  defp bucket_clause({:bucket, bucket}, index), do: {"AND bucket = $#{index}", [bucket]}

  defp queue_full_generation do
    case %{} |> Publisher.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp device_bucket(nil), do: :deployment

  defp device_bucket(ordinal) do
    case Repo.query!("SELECT uid FROM platform.device_fleet_ordinals WHERE ordinal = $1", [
           ordinal
         ]).rows do
      [[uid]] ->
        {:bucket,
         uid
         |> ExposureTransitionRelay.subject()
         |> String.split(".")
         |> List.last()
         |> String.to_integer()}

      [] ->
        :absent
    end
  end
end
