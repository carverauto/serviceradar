defmodule ServiceRadar.Inventory.ExposureReconciliationWorker do
  @moduledoc "Daily, resumable union enumeration and bounded per-device comparison/repair."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:device_ord],
      states: :incomplete
    ]

  import Ecto.Query

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.Inventory.ExposurePublicationPrepareWorker
  alias ServiceRadar.Inventory.ExposureReadiness
  alias ServiceRadar.Inventory.ExposureReconciliationComparison, as: Comparison
  alias ServiceRadar.Inventory.ExposureSnapshotFinalizer
  alias ServiceRadar.Inventory.ExposureSnapshotRepairs, as: Repairs
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Publisher
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession

  @table "platform.exposure_reconciliation_checks"
  @lock_base 320_102_347_440_128

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    ordinal = args["device_ord"] || 0

    cond do
      not Destination.enabled?() ->
        :ok

      not (is_integer(ordinal) and ordinal in 0..4_294_967_295) ->
        {:cancel, :invalid_exposure_scope}

      true ->
        DirectSession.run(fn session ->
          case Postgrex.query!(session, "SELECT pg_try_advisory_lock($1)", [@lock_base + ordinal]).rows do
            [[false]] -> {:snooze, 5}
            [[true]] when ordinal == 0 -> enumerate(job)
            [[true]] -> reconcile(session, ordinal)
          end
        end)
    end
  end

  defp enumerate(%Oban.Job{id: id}) when is_integer(id) do
    job = Repo.get!(Oban.Job, id)
    cursor = job.args["cursor"] || 0
    started = job.args["started_at"] || NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())

    source =
      List.flatten(
        Repo.query!(
          """
          SELECT ordinal FROM (
            SELECT ordinal FROM platform.device_fleet_ordinals WHERE ordinal > $1
            UNION SELECT device_ord FROM #{@table} WHERE device_ord > $1
          ) devices ORDER BY ordinal LIMIT 500
          """,
          [cursor]
        ).rows
      )

    with :ok <- ExposureSnapshotFinalizer.recover(nil),
         {:ok, stored} <- Warehouse.device_ordinals(cursor) do
      ordinals =
        (source ++ Enum.map(stored, & &1["device_ord"]))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(500)

      case Repo.transaction(fn ->
             locked = Repo.one!(from(j in Oban.Job, where: j.id == ^id, lock: "FOR UPDATE"))

             if locked.args != job.args,
               do: Repo.rollback(:exposure_reconciliation_cursor_changed)

             Enum.each(ordinals, fn ordinal ->
               ensure(ordinal)
               %{"device_ord" => ordinal} |> new() |> Oban.insert!()
             end)

             next = if ordinals == [], do: cursor, else: List.last(ordinals)
             args = Map.merge(job.args, %{"cursor" => next, "started_at" => started})
             Repo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [args: args])
             ensure(0)

             record(0, if(ordinals == [], do: "matched", else: "scanning"), %{
               "started_at" => started,
               "cursor" => next
             })

             if ExposureReadiness.replacement_required?(nil),
               do: Oban.insert!(Publisher.new(%{}))

             if ordinals == [], do: :ok, else: {:snooze, 1}
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reconcile(session, ordinal) do
    ensure(ordinal)

    result =
      with :ok <- settle(ordinal) do
        case Comparison.run(session, ordinal) do
          {:ok, comparison} -> finish_comparison(ordinal, comparison)
          {:repair, repairs} -> request_repairs(ordinal, repairs)
          {:error, reason} -> defer(ordinal, reason)
          {:retry, reason} -> defer(ordinal, reason)
        end
      end

    ExposureReadiness.status(ordinal)
    result
  end

  defp settle(ordinal) do
    control = control(ordinal)
    repairs = control["repairs"] || []

    with :ok <- ExposureSnapshotFinalizer.recover(ordinal),
         {:ok, remaining} <- Repairs.verify(repairs) do
      record(ordinal, "deferred", Map.put(control, "repairs", remaining), false)
      if remaining == [], do: :ok, else: {:snooze, 30}
    end
  end

  defp finish_comparison(ordinal, comparison) do
    control = Map.merge(control(ordinal), comparison)

    if comparison["matches"] do
      record(ordinal, "matched", Map.put(control, "repairs", []))

      case ExposureReadiness.status(ordinal) do
        {:ok, %{ready: true}} ->
          record(ordinal, "matched", Map.put(control, "mismatch_pending", false))
          emit(:matched)
          :ok

        {:ok, %{reasons: reasons}} ->
          if ExposureReadiness.replacement_required?(ordinal) or :comparison_pending in reasons,
            do: Oban.insert!(Publisher.new(%{"device_ord" => ordinal}))

          emit(:deferred)
          {:snooze, 30}

        {:error, reason} ->
          {:error, reason}
      end
    else
      mismatch(ordinal, control)
    end
  end

  defp request_repairs(ordinal, repairs) do
    case Repo.transaction(fn ->
           case Repairs.publish(repairs) do
             {:ok, assigned} ->
               control = ordinal |> control() |> Map.put("repairs", assigned)
               mark_mismatch(ordinal, control)

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, _} ->
        emit(:mismatch)
        {:snooze, 30}

      {:error, reason} ->
        defer(ordinal, reason)
    end
  end

  defp mismatch(ordinal, control) do
    case Repo.transaction(fn -> mark_mismatch(ordinal, control) end) do
      {:ok, _} ->
        emit(:mismatch)
        {:snooze, 30}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_mismatch(ordinal, control) do
    {generation, _} = ExposureReadiness.latest_generation(ordinal)
    # Keep the original obligation while its snapshot/repair is in flight.
    floor = if control["mismatch_pending"], do: control["generation_floor"] || 0, else: generation

    record(
      ordinal,
      "mismatch",
      Map.merge(control, %{"generation_floor" => floor, "mismatch_pending" => true})
    )

    Oban.insert!(Publisher.new(%{"device_ord" => ordinal}))
  end

  defp defer(ordinal, reason) do
    control =
      Map.put(
        control(ordinal),
        "reason",
        if(is_atom(reason), do: to_string(reason), else: "read_failed")
      )

    record(ordinal, "deferred", control, false)

    if reason == :exposure_snapshot_preparation_required,
      do: Oban.insert!(ExposurePublicationPrepareWorker.new(%{}))

    emit(:deferred)
    {:error, reason}
  end

  defp ensure(ordinal) do
    Repo.query!(
      """
      INSERT INTO #{@table} (device_ord, status, control, inserted_at, updated_at)
      VALUES ($1, 'deferred', '{}', now(), now()) ON CONFLICT DO NOTHING
      """,
      [ordinal]
    )
  end

  defp control(ordinal) do
    [[control]] =
      Repo.query!("SELECT control FROM #{@table} WHERE device_ord = $1", [ordinal]).rows

    control
  end

  defp record(ordinal, status, control, checked \\ true) do
    Repo.query!(
      """
      UPDATE #{@table} SET status = $2, control = $3, updated_at = now(),
        checked_at = CASE WHEN $4 THEN now() ELSE checked_at END WHERE device_ord = $1
      """,
      [ordinal, status, control, checked]
    )
  end

  defp emit(result) do
    :telemetry.execute(
      [:serviceradar, :exposure, :reconciliation],
      %{
        inspected: 1,
        mismatch: if(result == :mismatch, do: 1, else: 0),
        deferred: if(result == :deferred, do: 1, else: 0)
      },
      %{}
    )
  end
end
