defmodule ServiceRadar.Edge.AgentReleaseManager do
  @moduledoc """
  Coordinates release publication, rollout target creation, and per-agent
  rollout reconciliation over the existing command bus.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent

  require Ash.Query

  @release_command_type "agent.update_release"
  @inflight_statuses [:dispatched, :downloading, :verifying, :staged, :restarting]
  @terminal_statuses [:healthy, :failed, :rolled_back, :canceled]
  @known_progress_statuses %{
    "downloading" => :downloading,
    "verifying" => :verifying,
    "staged" => :staged,
    "restarting" => :restarting
  }

  def publish_release(attrs, opts \\ []) do
    actor = actor_opts(opts, :agent_release_manager_publish)
    AgentRelease.publish(attrs, actor: actor)
  end

  def pause_rollout(rollout_id, opts \\ []) do
    actor = actor_opts(opts, :agent_release_manager_pause)

    with {:ok, %AgentReleaseRollout{} = rollout} <-
           AgentReleaseRollout.get_by_id(rollout_id, actor: actor) do
      AgentReleaseRollout.pause(rollout, actor: actor)
    end
  end

  def resume_rollout(rollout_id, opts \\ []) do
    actor = actor_opts(opts, :agent_release_manager_resume)

    with {:ok, %AgentReleaseRollout{} = rollout} <-
           AgentReleaseRollout.get_by_id(rollout_id, actor: actor),
         {:ok, updated_rollout} <- AgentReleaseRollout.resume(rollout, actor: actor) do
      maybe_dispatch_rollout(updated_rollout.id, actor: actor)
      {:ok, updated_rollout}
    end
  end

  def cancel_rollout(rollout_id, opts \\ []) do
    actor = actor_opts(opts, :agent_release_manager_cancel)

    with {:ok, %AgentReleaseRollout{} = rollout} <-
           AgentReleaseRollout.get_by_id(rollout_id, actor: actor),
         {:ok, updated_rollout} <- AgentReleaseRollout.cancel(rollout, actor: actor) do
      cancel_pending_targets(updated_rollout.id, actor)
      {:ok, updated_rollout}
    end
  end

  def create_rollout(attrs, opts \\ []) do
    actor = actor_opts(opts, :agent_release_manager_rollout)

    with {:ok, release} <- load_release(attrs, actor),
         agent_ids =
           normalize_agent_ids(Map.get(attrs, :agent_ids) || Map.get(attrs, "agent_ids")),
         :ok <- validate_rollout_agent_ids(release, agent_ids, actor),
         {:ok, rollout} <- create_rollout_record(release, attrs, agent_ids, actor),
         {:ok, _targets} <- create_targets(rollout, release, agent_ids, actor) do
      maybe_dispatch_rollout(rollout.id, actor: actor)
      {:ok, rollout}
    end
  end

  def reconcile_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    actor = actor_opts(opts, :agent_release_manager_reconcile)

    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} ->
        agent_id
        |> active_targets_for_agent(actor)
        |> Enum.each(fn target ->
          if version_matches?(agent.version, target.desired_version) do
            _ =
              mark_target_status(
                target,
                :healthy,
                %{
                  current_version: agent.version,
                  last_status_message: "agent already at desired version",
                  progress_percent: 100
                },
                actor
              )
          else
            maybe_dispatch_rollout(target.rollout_id, actor: actor)
          end
        end)

        :ok

      _ ->
        :ok
    end
  end

  def handle_command_ack(data, opts \\ [])

  def handle_command_ack(
        %{command_type: @release_command_type, command_id: command_id} = data,
        opts
      ) do
    actor = actor_opts(opts, :agent_release_manager_ack)

    case AgentReleaseTarget.get_by_command_id(command_id, actor: actor) do
      {:ok, %AgentReleaseTarget{} = target} ->
        _ =
          mark_target_status(
            target,
            :dispatched,
            %{last_status_message: Map.get(data, :message)},
            actor
          )

        :ok

      _ ->
        :ok
    end
  end

  def handle_command_ack(_data, _opts), do: :ok

  def handle_command_progress(data, opts \\ [])

  def handle_command_progress(
        %{command_type: @release_command_type, command_id: command_id} = data,
        opts
      ) do
    actor = actor_opts(opts, :agent_release_manager_progress)

    case AgentReleaseTarget.get_by_command_id(command_id, actor: actor) do
      {:ok, %AgentReleaseTarget{} = target} ->
        _ =
          mark_target_status(
            target,
            progress_status(Map.get(data, :message)),
            %{
              progress_percent: Map.get(data, :progress_percent),
              last_status_message: Map.get(data, :message)
            },
            actor
          )

        :ok

      _ ->
        :ok
    end
  end

  def handle_command_progress(_data, _opts), do: :ok

  def handle_command_result(data, opts \\ [])

  def handle_command_result(
        %{command_type: @release_command_type, command_id: command_id} = data,
        opts
      ) do
    actor = actor_opts(opts, :agent_release_manager_result)

    case AgentReleaseTarget.get_by_command_id(command_id, actor: actor) do
      {:ok, %AgentReleaseTarget{} = target} ->
        payload = Map.get(data, :payload) || %{}

        case release_result_status(payload, Map.get(data, :success)) do
          {:staged, staged_version} ->
            _ =
              mark_target_status(
                target,
                :staged,
                %{
                  current_version: staged_version || target.current_version,
                  progress_percent: 100,
                  last_status_message: Map.get(data, :message),
                  last_error: nil
                },
                actor
              )

          {:healthy, current_version} ->
            _ =
              mark_target_status(
                target,
                :healthy,
                %{
                  current_version: current_version || target.current_version,
                  progress_percent: 100,
                  last_status_message: Map.get(data, :message),
                  last_error: nil
                },
                actor
              )

          {:rolled_back, reason} ->
            _ =
              mark_target_status(
                target,
                :rolled_back,
                %{
                  last_status_message: Map.get(data, :message),
                  last_error: reason || "rolled_back"
                },
                actor
              )

          {:failed, reason} ->
            _ =
              mark_target_status(
                target,
                :failed,
                %{
                  last_status_message: Map.get(data, :message),
                  last_error: reason || "command_failed"
                },
                actor
              )
        end

        maybe_dispatch_rollout(target.rollout_id, actor: actor)
        :ok

      _ ->
        :ok
    end
  end

  def handle_command_result(_data, _opts), do: :ok

  def maybe_dispatch_rollout(rollout_id, opts \\ []) do
    actor = actor_from_opts(opts, :agent_release_manager_dispatch)

    with {:ok, %AgentReleaseRollout{} = rollout} <-
           AgentReleaseRollout.get_by_id(rollout_id, actor: actor),
         true <- rollout.status == :active,
         true <- dispatch_window_open?(rollout),
         {:ok, %AgentRelease{} = release} <-
           AgentRelease.get_by_id(rollout.release_id, actor: actor) do
      inflight_count =
        rollout.id
        |> rollout_targets(actor)
        |> Enum.count(&(&1.status in @inflight_statuses))

      capacity = max((rollout.batch_size || 1) - inflight_count, 0)

      if capacity > 0 do
        rollout.id
        |> pending_targets(actor)
        |> Enum.reduce_while(capacity, fn target, remaining ->
          case dispatch_target(target, rollout, release, actor) do
            {:ok, _command_id} when remaining > 1 -> {:cont, remaining - 1}
            {:ok, _command_id} -> {:halt, 0}
            :pending -> {:cont, remaining}
            {:error, _reason} -> {:cont, remaining}
          end
        end)
      end

      maybe_complete_rollout(rollout.id, actor)
      :ok
    else
      _ -> :ok
    end
  end

  defp create_rollout_record(release, attrs, agent_ids, actor) do
    created_by =
      Map.get(attrs, :created_by) ||
        Map.get(attrs, "created_by") ||
        actor_requester(actor) ||
        "system"

    rollout_attrs = %{
      release_id: release.id,
      desired_version: release.version,
      cohort_agent_ids: agent_ids,
      batch_size:
        normalize_batch_size(
          Map.get(attrs, :batch_size) || Map.get(attrs, "batch_size"),
          agent_ids
        ),
      batch_delay_seconds:
        normalize_non_negative_integer(
          Map.get(attrs, :batch_delay_seconds) || Map.get(attrs, "batch_delay_seconds")
        ),
      status: :active,
      created_by: created_by,
      notes: Map.get(attrs, :notes) || Map.get(attrs, "notes"),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    }

    AgentReleaseRollout.create_rollout(rollout_attrs, actor: actor)
  end

  defp create_targets(rollout, release, agent_ids, actor) do
    targets =
      agent_ids
      |> Enum.with_index()
      |> Enum.map(fn {agent_id, cohort_index} ->
        attrs = %{
          rollout_id: rollout.id,
          release_id: release.id,
          agent_id: agent_id,
          cohort_index: cohort_index,
          desired_version: release.version,
          current_version: agent_current_version(agent_id, actor),
          status: :pending
        }

        case AgentReleaseTarget.create_target(attrs, actor: actor) do
          {:ok, target} ->
            sync_agent_release_state(agent_id, release.version, :pending, nil, actor)
            target

          {:error, reason} ->
            raise "failed to create rollout target for #{agent_id}: #{inspect(reason)}"
        end
      end)

    {:ok, targets}
  end

  defp dispatch_target(target, rollout, release, actor) do
    with {:ok, %Agent{} = agent} <- Agent.get_by_uid(target.agent_id, actor: actor),
         false <- version_matches?(agent.version, target.desired_version),
         {:ok, artifact} <- select_artifact(release, agent),
         {:ok, command_id} <- dispatch_release_command(target, rollout, release, artifact, actor) do
      mark_target_status(
        target,
        :dispatched,
        %{
          command_id: command_id,
          current_version: agent.version,
          last_status_message: "release command dispatched",
          progress_percent: 0
        },
        actor
      )
    else
      true ->
        mark_target_status(
          target,
          :healthy,
          %{
            current_version: target.desired_version,
            last_status_message: "agent already compliant",
            progress_percent: 100
          },
          actor
        )

      {:error, {:agent_offline, _agent_id}} ->
        :pending

      {:error, :agent_offline} ->
        :pending

      {:error, reason} ->
        mark_target_status(
          target,
          :failed,
          %{last_status_message: "release dispatch failed", last_error: normalize_reason(reason)},
          actor
        )
    end
  end

  defp dispatch_release_command(target, rollout, release, artifact, actor) do
    payload = %{
      "release_id" => release.id,
      "rollout_id" => rollout.id,
      "target_id" => target.id,
      "version" => release.version,
      "manifest" => release.manifest,
      "signature" => release.signature,
      "artifact" => artifact
    }

    context = %{
      rollout_id: rollout.id,
      target_id: target.id,
      release_id: release.id,
      desired_version: release.version
    }

    case AgentCommandBus.dispatch(
           target.agent_id,
           @release_command_type,
           payload,
           ttl_seconds: 900,
           context: context,
           actor: actor
         ) do
      {:ok, command_id} ->
        _ = AgentReleaseRollout.touch_dispatch(rollout, actor: actor)
        {:ok, command_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_artifact(release, agent) do
    artifacts =
      release.manifest
      |> map_get_any([:artifacts, "artifacts"], [])
      |> List.wrap()

    metadata = agent.metadata || %{}
    os = map_get_any(metadata, [:os, "os"], nil)
    arch = map_get_any(metadata, [:arch, "arch"], nil)

    selected =
      Enum.find(artifacts, fn artifact ->
        artifact_os = map_get_any(artifact, [:os, "os"], nil)
        artifact_arch = map_get_any(artifact, [:arch, "arch"], nil)

        (is_nil(artifact_os) or artifact_os == os) and
          (is_nil(artifact_arch) or artifact_arch == arch)
      end)

    case selected do
      nil -> {:error, {:no_matching_release_artifact, os, arch}}
      artifact -> {:ok, normalize_keys(artifact)}
    end
  end

  defp mark_target_status(target, status, attrs, actor) do
    attrs =
      attrs
      |> Map.merge(status_transition_attrs(target, status))
      |> Map.put(:status, status)
      |> compact_map()

    case AgentReleaseTarget.set_status(target, attrs, actor: actor) do
      {:ok, updated_target} ->
        sync_agent_release_state(
          updated_target.agent_id,
          updated_target.desired_version,
          status,
          Map.get(attrs, :last_error),
          actor,
          current_version: Map.get(attrs, :current_version)
        )

        {:ok, updated_target}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_agent_release_state(agent_id, desired_version, status, last_error, actor, opts \\ []) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} ->
        update_attrs =
          compact_map(%{
            desired_version: desired_version,
            release_rollout_state: status,
            last_update_at: DateTime.utc_now(),
            last_update_error: last_error,
            version: Keyword.get(opts, :current_version)
          })

        _ =
          agent
          |> Ash.Changeset.for_update(:update_release_status, update_attrs)
          |> Ash.update(actor: actor)

        :ok

      _ ->
        :ok
    end
  end

  defp status_transition_attrs(target, status) do
    now = DateTime.utc_now()

    %{}
    |> maybe_put(
      :dispatched_at,
      now,
      status in @inflight_statuses and is_nil(target.dispatched_at)
    )
    |> maybe_put(:completed_at, now, status in @terminal_statuses and is_nil(target.completed_at))
  end

  defp maybe_complete_rollout(rollout_id, actor) do
    with {:ok, rollout} <- AgentReleaseRollout.get_by_id(rollout_id, actor: actor) do
      targets = rollout_targets(rollout_id, actor)

      if rollout.status == :active and targets != [] and
           Enum.all?(targets, &(&1.status in @terminal_statuses)) do
        _ = AgentReleaseRollout.complete(rollout, actor: actor)
      end
    end
  end

  defp cancel_pending_targets(rollout_id, actor) do
    rollout_id
    |> pending_targets(actor)
    |> Enum.each(fn target ->
      _ =
        mark_target_status(
          target,
          :canceled,
          %{
            last_status_message: "rollout canceled before dispatch",
            last_error: "rollout_canceled"
          },
          actor
        )
    end)
  end

  defp dispatch_window_open?(%AgentReleaseRollout{batch_delay_seconds: delay_seconds})
       when not is_integer(delay_seconds) or delay_seconds <= 0, do: true

  defp dispatch_window_open?(%AgentReleaseRollout{last_dispatch_at: nil}), do: true

  defp dispatch_window_open?(%AgentReleaseRollout{
         batch_delay_seconds: delay_seconds,
         last_dispatch_at: %DateTime{} = last_dispatch_at
       }) do
    DateTime.diff(DateTime.utc_now(), last_dispatch_at, :second) >= delay_seconds
  end

  defp active_targets_for_agent(agent_id, actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:by_agent, %{agent_id: agent_id}, actor: actor)
    |> Ash.Query.filter(expr(status not in ^@terminal_statuses))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(actor: actor)
  end

  defp rollout_targets(rollout_id, actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(expr(rollout_id == ^rollout_id))
    |> Ash.Query.sort(cohort_index: :asc)
    |> Ash.read!(actor: actor)
  end

  defp pending_targets(rollout_id, actor) do
    AgentReleaseTarget
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(expr(rollout_id == ^rollout_id and status == :pending))
    |> Ash.Query.sort(cohort_index: :asc)
    |> Ash.read!(actor: actor)
  end

  defp load_release(%{release_id: release_id}, actor),
    do: AgentRelease.get_by_id(release_id, actor: actor)

  defp load_release(%{"release_id" => release_id}, actor),
    do: AgentRelease.get_by_id(release_id, actor: actor)

  defp load_release(%{version: version}, actor),
    do: AgentRelease.get_by_version(version, actor: actor)

  defp load_release(%{"version" => version}, actor),
    do: AgentRelease.get_by_version(version, actor: actor)

  defp load_release(_attrs, _actor), do: {:error, :release_not_specified}

  defp agent_current_version(agent_id, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{version: version}} -> version
      _ -> nil
    end
  end

  defp validate_rollout_agent_ids(_release, [], _actor),
    do: {:error, %{message: "no agents selected for rollout"}}

  defp validate_rollout_agent_ids(release, agent_ids, actor) do
    agents_by_uid =
      agent_ids
      |> list_agents_by_uid(actor)
      |> Map.new(&{&1.uid, &1})

    unknown_agent_ids =
      Enum.reject(agent_ids, fn agent_id ->
        Map.has_key?(agents_by_uid, agent_id)
      end)

    unsupported_agents =
      agents_by_uid
      |> Map.values()
      |> Enum.reduce([], fn agent, acc ->
        case select_artifact(release, agent) do
          {:ok, _artifact} ->
            acc

          {:error, {:no_matching_release_artifact, os, arch}} ->
            [%{agent_id: agent.uid, platform: platform_label(os, arch)} | acc]
        end
      end)
      |> Enum.reverse()

    case rollout_validation_errors(unknown_agent_ids, unsupported_agents) do
      [] -> :ok
      errors -> {:error, %{errors: errors}}
    end
  end

  defp list_agents_by_uid([], _actor), do: []

  defp list_agents_by_uid(agent_ids, actor) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid in ^agent_ids)
    |> Ash.read!(actor: actor)
  end

  defp rollout_validation_errors(unknown_agent_ids, unsupported_agents) do
    []
    |> maybe_append_rollout_validation_error(
      unknown_agent_ids != [],
      unresolved_agent_ids_message(unknown_agent_ids)
    )
    |> maybe_append_rollout_validation_error(
      unsupported_agents != [],
      unsupported_agent_platforms_message(unsupported_agents)
    )
  end

  defp maybe_append_rollout_validation_error(errors, false, _message), do: errors

  defp maybe_append_rollout_validation_error(errors, true, message),
    do: errors ++ [%{message: message}]

  defp unresolved_agent_ids_message(agent_ids) do
    "unresolved agent ids: #{Enum.join(agent_ids, ", ")}"
  end

  defp unsupported_agent_platforms_message(agents) do
    labels =
      Enum.map_join(agents, ", ", fn %{agent_id: agent_id, platform: platform} ->
        "#{agent_id} (#{platform})"
      end)

    "unsupported agent platforms for release cohort: #{labels}"
  end

  defp version_matches?(current_version, desired_version)
       when is_binary(current_version) and is_binary(desired_version) do
    String.trim(current_version) != "" and
      String.trim(current_version) == String.trim(desired_version)
  end

  defp version_matches?(_, _), do: false

  defp progress_status(message) do
    message
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@known_progress_statuses, &1, :dispatched))
  end

  defp release_result_status(payload, true) do
    payload = normalize_keys(payload)

    case map_get_any(payload, [:status, "status"], nil) do
      "staged" ->
        {:staged,
         map_get_any(payload, [:current_version, "current_version", :version, "version"], nil)}

      :staged ->
        {:staged,
         map_get_any(payload, [:current_version, "current_version", :version, "version"], nil)}

      "rolled_back" ->
        {:rolled_back, map_get_any(payload, [:reason, "reason"], nil)}

      :rolled_back ->
        {:rolled_back, map_get_any(payload, [:reason, "reason"], nil)}

      _ ->
        {:healthy,
         map_get_any(payload, [:current_version, "current_version", :version, "version"], nil)}
    end
  end

  defp release_result_status(payload, _falsey) do
    payload = normalize_keys(payload)
    status = map_get_any(payload, [:status, "status"], nil)
    reason = map_get_any(payload, [:reason, "reason", :error, "error"], nil)

    if status in ["rolled_back", :rolled_back] do
      {:rolled_back, reason}
    else
      {:failed, reason}
    end
  end

  defp normalize_agent_ids(agent_ids) do
    agent_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_batch_size(nil, agent_ids), do: max(length(agent_ids), 1)
  defp normalize_batch_size(value, _agent_ids) when is_integer(value) and value > 0, do: value

  defp normalize_batch_size(value, agent_ids) do
    case Integer.parse(to_string(value)) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> max(length(agent_ids), 1)
    end
  end

  defp normalize_non_negative_integer(nil), do: 0
  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_non_negative_integer(value) do
    case Integer.parse(to_string(value)) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp normalize_reason({:no_matching_release_artifact, os, arch}) do
    "no matching release artifact for agent platform #{platform_label(os, arch)}"
  end

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  defp platform_label(os, arch) do
    "#{present_platform_value(os, "unknown-os")}/#{present_platform_value(arch, "unknown-arch")}"
  end

  defp present_platform_value(value, fallback) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: fallback, else: value
  end

  defp present_platform_value(nil, fallback), do: fallback
  defp present_platform_value(value, _fallback), do: to_string(value)

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, %{} = value} -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp map_get_any(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  defp normalize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_value =
        cond do
          is_map(value) -> normalize_keys(value)
          is_list(value) -> Enum.map(value, &if(is_map(&1), do: normalize_keys(&1), else: &1))
          true -> value
        end

      Map.put(acc, key, normalized_value)
    end)
  end

  defp normalize_keys(other), do: other

  defp actor_opts(opts, label) when is_list(opts) do
    case scope_actor(Keyword.get(opts, :scope)) do
      nil -> Keyword.get(opts, :actor, SystemActor.system(label))
      actor -> actor
    end
  end

  defp actor_opts(_opts, label), do: SystemActor.system(label)

  defp actor_from_opts(opts, label) do
    case scope_actor(Keyword.get(opts, :scope)) || Keyword.get(opts, :actor) do
      nil ->
        SystemActor.system(label)

      actor ->
        actor
    end
  end

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp actor_requester(%{id: id}) when is_binary(id), do: id
  defp actor_requester(%{email: email}) when is_binary(email), do: email
  defp actor_requester(_actor), do: nil
end
