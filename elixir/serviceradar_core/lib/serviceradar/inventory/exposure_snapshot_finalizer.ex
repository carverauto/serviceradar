defmodule ServiceRadar.Inventory.ExposureSnapshotFinalizer do
  @moduledoc "Bounded end-manifest scan. Dispatching repairs is not completion evidence."
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.Inventory.ExposureSnapshotRepairs, as: Repairs
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo

  def step(id) do
    with {:ok, generation} <- State.get(id),
         true <- generation["status"] == "finalizing",
         true <- generation["receipts"] == generation["manifest"] and generation["pending"] == %{} do
      if generation["repairs"] == [] do
        scan(generation)
      else
        settle(generation)
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

  defp settle(generation) do
    with {:ok, repairs} <-
           State.change(generation["id"], fn current ->
             if current["status"] == "finalizing" and current["repairs"] == generation["repairs"] do
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
             if current["status"] == "finalizing" and current["repairs"] == repairs do
               {:ok, Map.put(current, "repairs", remaining), :ok}
             else
               {:error, :exposure_snapshot_finalizer_changed}
             end
           end) do
      if remaining == [], do: :ok, else: {:error, :exposure_snapshot_repairs_pending}
    end
  end

  defp complete(generation) do
    with {:ok, :ok} <-
           State.change(generation["id"], fn current ->
             if current["status"] == "finalizing" and current["cursor"] == generation["cursor"] and
                  current["repairs"] == [] and current["pending"] == %{} and
                  not unresolved_recovery?(current["scope"]) do
               {:ok, Map.put(current, "status", "complete"), :ok}
             else
               {:error, :exposure_snapshot_finalization_pending}
             end
           end),
         do: :ok
  end

  defp unresolved_recovery?(scope) do
    case device_bucket(scope) do
      :absent ->
        false

      scope ->
        {bucket_sql, params} =
          case scope do
            :deployment -> {"", []}
            {:bucket, bucket} -> {" AND bucket = $1", [bucket]}
          end

        Repo.query!(
          """
          SELECT 1 FROM platform.exposure_delivery_batches
          WHERE phase IN ('legacy', 'snapshot_required', 'applying')
          #{bucket_sql} LIMIT 1
          """,
          params
        ).rows != []
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
