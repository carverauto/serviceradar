defmodule ServiceRadar.Credentials.CameraCredentialRuleReconcileWorker do
  @moduledoc """
  Periodic worker that materializes camera credential rules (unifi-protect, axis)
  for eligible agents.

  Sibling of `ServiceRadar.Credentials.ProxmoxCredentialRuleReconcileWorker`. A
  separate worker keeps the Proxmox worker's unique/period scheduling untouched.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_reschedule_seconds 60

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if scheduled?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:camera_credential_rule_reconcile_worker)

    case load_connected_agents(actor) do
      {:ok, agents} ->
        summary = reconcile_agents(agents, actor: actor)

        Logger.info(
          "Reconciled camera credential rules: #{format_summary(summary)}",
          summary: inspect(summary)
        )

        schedule_next()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to load agents for camera credential reconciliation",
          reason: inspect(reason)
        )

        schedule_next()
        {:error, reason}
    end
  end

  @doc false
  @spec reconcile_agents([map()], keyword()) :: map()
  def reconcile_agents(agents, opts \\ []) when is_list(agents) do
    materializer = Keyword.get(opts, :materializer, PluginAssignmentMaterializer)

    Enum.reduce(agents, empty_summary(), fn agent, acc ->
      case agent_uid(agent) do
        nil ->
          %{acc | skipped_agents: acc.skipped_agents + 1}

        uid ->
          reconcile_agent(uid, materializer, opts, acc)
      end
    end)
  end

  defp reconcile_agent(uid, materializer, opts, acc) do
    with {:ok, inventory_summary} <- materializer.reconcile_camera_inventory_for_agent(uid, opts),
         {:ok, stream_summary} <- materializer.reconcile_camera_stream_for_agent(uid, opts) do
      acc
      |> Map.update!(:agents, &(&1 + 1))
      |> merge_summary(inventory_summary)
      |> merge_summary(stream_summary)
    else
      {:error, reason} ->
        Logger.warning("Failed to reconcile camera credential rules for agent",
          agent_uid: uid,
          reason: inspect(reason)
        )

        %{acc | failed_agents: acc.failed_agents + 1}
    end
  end

  defp load_connected_agents(actor) do
    Agent
    |> Ash.Query.for_read(:connected, %{}, actor: actor)
    |> Ash.read(actor: actor)
  end

  defp scheduled? do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp schedule_next do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :camera_credential_rule_reconcile_interval_seconds,
        @default_reschedule_seconds
      )

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(seconds, 10)))
    :ok
  end

  defp agent_uid(agent) when is_map(agent) do
    case Map.get(agent, :uid) || Map.get(agent, "uid") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp agent_uid(_agent), do: nil

  defp empty_summary do
    %{
      agents: 0,
      failed_agents: 0,
      skipped_agents: 0,
      rules: 0,
      resolved_inputs: 0,
      desired_assignments: 0,
      upserted: 0,
      unchanged: 0,
      disabled: 0,
      skips: %{}
    }
  end

  defp merge_summary(acc, summary) do
    %{
      acc
      | rules: acc.rules + Map.get(summary, :rules, 0),
        resolved_inputs: acc.resolved_inputs + Map.get(summary, :resolved_inputs, 0),
        desired_assignments: acc.desired_assignments + Map.get(summary, :desired_assignments, 0),
        upserted: acc.upserted + Map.get(summary, :upserted, 0),
        unchanged: acc.unchanged + Map.get(summary, :unchanged, 0),
        disabled: acc.disabled + Map.get(summary, :disabled, 0),
        skips: merge_skips(acc.skips, Map.get(summary, :skips, %{}))
    }
  end

  defp merge_skips(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _reason, a, b -> a + b end)
  end

  defp format_summary(summary) do
    skips =
      summary
      |> Map.get(:skips, %{})
      |> Enum.sort()
      |> Enum.map_join(",", fn {reason, count} -> "#{reason}=#{count}" end)

    base =
      "agents=#{summary.agents} failed_agents=#{summary.failed_agents} " <>
        "skipped_agents=#{summary.skipped_agents} rules_matched=#{summary.rules} " <>
        "targets_resolved=#{summary.resolved_inputs} desired=#{summary.desired_assignments} " <>
        "written=#{summary.upserted} unchanged=#{summary.unchanged} disabled=#{summary.disabled}"

    if skips == "", do: base, else: base <> " skips[#{skips}]"
  end
end
