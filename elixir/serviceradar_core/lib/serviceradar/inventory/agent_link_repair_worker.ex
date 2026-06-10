defmodule ServiceRadar.Inventory.AgentLinkRepairWorker do
  @moduledoc """
  Periodic Oban worker that repairs agent-to-device links.

  Agent enrollment repairs links once at hello time; after that, device
  merges, tombstones, and manual remediation can leave
  `ocsf_agents.device_uid` pointing at a tombstoned device, or leave the
  `agent_id` device identifier on a different device than the agent row.
  This worker re-verifies every connected/available agent on a fixed
  cadence (default 15 minutes):

  1. If `device_uid` points at a tombstoned device, it follows the merge
     audit trail (`IdentityReconciler.follow_canonical_device_id/2`) and
     repoints the agent at the surviving canonical device via the audited
     `:reassign_device` action.
  2. If the `agent_id` device identifier does not point at the same device
     as `ocsf_agents.device_uid`, the identifier is repointed via the
     audited `DeviceIdentifier` `:reassign_device` action. A missing
     `agent_id` identifier is re-registered.

  Every repair is logged and emits
  `[:serviceradar, :agent_link_repair, :repaired]`. Each run emits a
  `[:serviceradar, :agent_link_repair, :run]` summary. The worker is
  idempotent and streams agents in bounded batches (no full-table loads).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_reschedule_seconds 900
  @default_batch_size 100
  @repair_statuses [:connected, :connecting, :degraded]

  @empty_stats %{
    agents_checked: 0,
    device_links_repaired: 0,
    identifiers_repaired: 0,
    identifiers_registered: 0,
    unrepairable: 0,
    errors: 0
  }

  @spec ensure_scheduled() :: {:ok, Oban.Job.t() | :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if job_already_scheduled?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    stats =
      if Keyword.get(config, :enabled, true) do
        run_repair(config)
      else
        Logger.info("AgentLinkRepairWorker: disabled, skipping run")
        @empty_stats
      end

    emit_run_telemetry(stats)
    reschedule(config)
    :ok
  end

  @doc """
  Run a single repair pass and return run statistics.

  Exposed for tests and manual invocation; `perform/1` wraps this with
  run-summary telemetry and rescheduling.
  """
  @spec run_repair(keyword()) :: map()
  def run_repair(config \\ []) do
    actor = SystemActor.system(:agent_link_repair_worker)
    batch_size = positive_int(Keyword.get(config, :batch_size), @default_batch_size)

    stats =
      Agent
      |> Ash.Query.filter(status in ^@repair_statuses and not is_nil(device_uid))
      |> Ash.stream!(
        actor: actor,
        batch_size: batch_size,
        stream_with: :offset,
        allow_stream_with: :offset
      )
      |> Enum.reduce(@empty_stats, fn agent, stats ->
        repair_agent(agent, actor, stats)
      end)

    if stats.device_links_repaired + stats.identifiers_repaired + stats.identifiers_registered >
         0 or stats.unrepairable > 0 or stats.errors > 0 do
      Logger.info("AgentLinkRepairWorker: run completed", Map.to_list(stats))
    end

    stats
  end

  defp repair_agent(agent, actor, stats) do
    stats = %{stats | agents_checked: stats.agents_checked + 1}

    case resolve_canonical_device(agent.device_uid, actor) do
      {:live, device_uid} ->
        repair_identifier(agent, device_uid, actor, stats)

      {:repoint, canonical_uid} ->
        case repoint_agent(agent, canonical_uid, actor) do
          {:ok, updated_agent} ->
            stats = %{stats | device_links_repaired: stats.device_links_repaired + 1}
            repair_identifier(updated_agent, canonical_uid, actor, stats)

          {:error, reason} ->
            Logger.warning(
              "AgentLinkRepairWorker: failed to repoint agent #{agent.uid} " <>
                "from #{agent.device_uid} to #{canonical_uid}: #{inspect(reason)}"
            )

            %{stats | errors: stats.errors + 1}
        end

      {:unrepairable, reason} ->
        Logger.warning(
          "AgentLinkRepairWorker: agent #{agent.uid} device link #{agent.device_uid} " <>
            "is unrepairable: #{inspect(reason)}"
        )

        emit_unrepairable_telemetry(agent, reason)
        %{stats | unrepairable: stats.unrepairable + 1}
    end
  rescue
    error ->
      Logger.warning(
        "AgentLinkRepairWorker: repair failed for agent #{agent.uid}: #{inspect(error)}"
      )

      %{stats | errors: stats.errors + 1}
  end

  defp resolve_canonical_device(device_uid, actor) do
    case Device.get_by_uid(device_uid, true, actor: actor) do
      {:ok, %Device{deleted_at: nil}} ->
        {:live, device_uid}

      {:ok, %Device{}} ->
        canonical = IdentityReconciler.follow_canonical_device_id(device_uid, actor)

        cond do
          canonical == device_uid ->
            {:unrepairable, :tombstoned_without_canonical}

          live_device?(canonical, actor) ->
            {:repoint, canonical}

          true ->
            {:unrepairable, {:canonical_not_live, canonical}}
        end

      {:error, _} ->
        {:unrepairable, :device_missing}
    end
  end

  defp live_device?(device_uid, actor) do
    case Device.get_by_uid(device_uid, false, actor: actor) do
      {:ok, %Device{}} -> true
      _ -> false
    end
  end

  defp repoint_agent(agent, canonical_uid, actor) do
    result =
      agent
      |> Ash.Changeset.for_update(:reassign_device, %{device_uid: canonical_uid})
      |> Ash.update(actor: actor)

    case result do
      {:ok, updated} ->
        Logger.info(
          "AgentLinkRepairWorker: repointed agent #{agent.uid} device link " <>
            "#{agent.device_uid} -> #{canonical_uid} (tombstoned device)"
        )

        emit_repair_telemetry(agent.uid, :device_link, agent.device_uid, canonical_uid)
        {:ok, updated}

      {:error, _reason} = error ->
        error
    end
  end

  # Verify the agent_id device_identifier rows point at the same device the
  # agent row points at; repoint via the audited :reassign_device action.
  defp repair_identifier(agent, target_device_uid, actor, stats) do
    identifiers =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :agent_id and identifier_value == ^agent.uid)
      |> Ash.read!(actor: actor)

    case identifiers do
      [] ->
        register_identifier(agent, target_device_uid, actor, stats)

      identifiers ->
        Enum.reduce(identifiers, stats, fn identifier, stats ->
          if identifier.device_id == target_device_uid do
            stats
          else
            reassign_identifier(identifier, agent, target_device_uid, actor, stats)
          end
        end)
    end
  end

  defp reassign_identifier(identifier, agent, target_device_uid, actor, stats) do
    result =
      identifier
      |> Ash.Changeset.for_update(:reassign_device, %{device_id: target_device_uid})
      |> Ash.update(actor: actor)

    case result do
      {:ok, _} ->
        Logger.info(
          "AgentLinkRepairWorker: repointed agent_id identifier for #{agent.uid} " <>
            "#{identifier.device_id} -> #{target_device_uid}"
        )

        emit_repair_telemetry(agent.uid, :identifier, identifier.device_id, target_device_uid)
        %{stats | identifiers_repaired: stats.identifiers_repaired + 1}

      {:error, reason} ->
        Logger.warning(
          "AgentLinkRepairWorker: failed to reassign agent_id identifier for " <>
            "#{agent.uid}: #{inspect(reason)}"
        )

        %{stats | errors: stats.errors + 1}
    end
  end

  defp register_identifier(agent, target_device_uid, actor, stats) do
    result =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:upsert, %{
        device_id: target_device_uid,
        identifier_type: :agent_id,
        identifier_value: agent.uid,
        partition: "default",
        confidence: :strong,
        source: "agent_link_repair"
      })
      |> Ash.create(actor: actor)

    case result do
      {:ok, _} ->
        Logger.info(
          "AgentLinkRepairWorker: registered missing agent_id identifier for " <>
            "#{agent.uid} -> #{target_device_uid}"
        )

        emit_repair_telemetry(agent.uid, :identifier_registered, nil, target_device_uid)
        %{stats | identifiers_registered: stats.identifiers_registered + 1}

      {:error, reason} ->
        Logger.warning(
          "AgentLinkRepairWorker: failed to register agent_id identifier for " <>
            "#{agent.uid}: #{inspect(reason)}"
        )

        %{stats | errors: stats.errors + 1}
    end
  end

  defp emit_repair_telemetry(agent_uid, repair, from, to) do
    :telemetry.execute(
      [:serviceradar, :agent_link_repair, :repaired],
      %{count: 1},
      %{agent_uid: agent_uid, repair: repair, from: from, to: to}
    )
  end

  defp emit_unrepairable_telemetry(agent, reason) do
    :telemetry.execute(
      [:serviceradar, :agent_link_repair, :unrepairable],
      %{count: 1},
      %{agent_uid: agent.uid, device_uid: agent.device_uid, reason: reason}
    )
  end

  defp emit_run_telemetry(stats) do
    :telemetry.execute([:serviceradar, :agent_link_repair, :run], stats, %{})
  end

  defp reschedule(config) do
    reschedule_seconds =
      positive_int(Keyword.get(config, :reschedule_seconds), @default_reschedule_seconds)

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 60)))
    :ok
  end

  defp job_already_scheduled? do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
