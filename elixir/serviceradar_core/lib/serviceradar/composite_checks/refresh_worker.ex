defmodule ServiceRadar.CompositeChecks.RefreshWorker do
  @moduledoc """
  Re-evaluates one device against the enabled composite checks that already hold
  a result for it.

  Oban's `unique` window is the debounce: several input changes for the same
  device inside the window collapse into one evaluation, which matters because
  one sweep cycle over a large scope produces one trigger per device.
  """

  use Oban.Worker,
    queue: :monitoring,
    max_attempts: 3,
    unique: [period: 30, keys: [:device_uid], states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.CompositeCheckInput
  alias ServiceRadar.CompositeChecks.CompositeCheckRule
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Evaluation
  alias ServiceRadar.CompositeChecks.VerdictEventWriter
  alias ServiceRadar.Inventory.Identity.Fence

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"device_uid" => device_uid} = args}) do
    # Observe-only identity fence. The unique window debounces by design, so there
    # is a real gap between the trigger that enqueued this and the evaluation
    # below; a merge inside that gap writes a verdict for a device that no longer
    # owns the inputs. This reports the gap without acting on it.
    observe_identity(device_uid, args)

    actor = SystemActor.system(:composite_check_refresh)
    now = DateTime.utc_now()

    case DeviceCompositeCheckResult.list_by_device(device_uid, actor: actor) do
      {:ok, results} ->
        refreshed =
          results
          |> Enum.map(& &1.check_id)
          |> Enum.uniq()
          |> Enum.count(&refresh_check(&1, device_uid, now, actor))

        {:ok, refreshed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Oban args are string-keyed. Jobs enqueued before this shipped carry no pin,
  # and are left alone rather than reported as missing.
  defp observe_identity(device_uid, %{"identity_revision" => revision})
       when is_integer(revision) do
    Fence.observe({device_uid, revision}, :composite_check_refresh)
  end

  defp observe_identity(_device_uid, _args), do: :ok

  defp refresh_check(check_id, device_uid, now, actor) do
    with {:ok, %{state: :enabled} = check} <- CompositeCheck.get_by_id(check_id, actor: actor),
         {:ok, inputs} <- CompositeCheckInput.list_by_check(check_id, actor: actor),
         {:ok, rules} <- CompositeCheckRule.list_by_check(check_id, actor: actor),
         {:ok, [row]} <- Evaluation.evaluate_devices(check, inputs, rules, [device_uid], now: now),
         {:ok, prior} <-
           DeviceCompositeCheckResult.get_by_device_check(device_uid, check_id, actor: actor) do
      apply_refresh(check, prior, row, now, actor)
      true
    else
      _ -> false
    end
  end

  defp apply_refresh(check, prior, row, now, actor) do
    changed? = prior.verdict != row.verdict

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: row.device_uid,
        check_id: check.id,
        verdict: row.verdict,
        status: row.status,
        matched_rule_id: row.matched_rule_id,
        inputs: row.inputs,
        evaluated_at: now,
        changed_at: if(changed?, do: now, else: prior.changed_at)
      },
      actor: actor,
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()

    if changed? do
      VerdictEventWriter.write_transitions(check, [
        %{
          device_uid: row.device_uid,
          check_id: check.id,
          from_verdict: prior.verdict,
          to_verdict: row.verdict,
          from_status: prior.status,
          to_status: row.status,
          inputs: row.inputs
        }
      ])
    end

    :ok
  end
end
