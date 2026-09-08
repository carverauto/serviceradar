defmodule ServiceRadar.Edge.AgentReleaseManager do
  @moduledoc """
  Coordinates release publication, rollout target creation, and per-agent
  rollout reconciliation over the existing command bus.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.AgentRuntimeMetadata
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseArtifactPolicy
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Edge.ReleaseArtifactDelivery
  alias ServiceRadar.Edge.ReleaseArtifactMirror
  alias ServiceRadar.Infrastructure.Agent

  require Ash.Query

  @release_command_type "agent.update_release"
  @release_ack_timeout_seconds 60
  @inflight_statuses [:dispatched, :downloading, :verifying, :staged, :restarting]
  @terminal_statuses [:healthy, :failed, :rolled_back, :canceled]
  @retryable_target_statuses [:failed, :rolled_back]
  @max_auto_release_retries 3
  # HTTP statuses the gateway serves for a not-ready/transient artifact state and
  # transient network markers. A download failure whose reason matches is auto-
  # retried; anything else (bad signature, platform mismatch) is terminal.
  @transient_release_status_codes ~w(403 404 408 409 423 424 425 429 500 502 503 504)
  @transient_release_markers [
    "timeout",
    "timed out",
    "connection refused",
    "connection reset",
    "reset by peer",
    "no route to host",
    "temporarily unavailable",
    "i/o timeout",
    "broken pipe",
    "network is unreachable",
    "eof"
  ]
  @known_progress_statuses %{
    "downloading" => :downloading,
    "verifying" => :verifying,
    "staged" => :staged,
    "restarting" => :restarting
  }

  def publish_release(attrs, opts \\ []) do
    actor = actor_opts(opts, :agent_release_manager_publish)

    with {:ok, mirrored_attrs} <- artifact_mirror().prepare_publish_attrs(attrs) do
      AgentRelease.publish(mirrored_attrs, actor: actor)
    end
  end

  def select_artifact_for_agent(release, agent), do: select_artifact(release, agent)

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

  @doc """
  Re-dispatches a release to a single FAILED (or rolled-back) rollout target.

  Resets the target back to pending (clearing the stale command/error), reactivates
  the parent rollout when it had already completed, and lets the rollout dispatch a
  fresh command and download token. Idempotent per attempt and RBAC-gated via the
  operator actor carried in `opts`.
  """
  @spec retry_target(String.t(), keyword()) :: {:ok, AgentReleaseTarget.t()} | {:error, term()}
  def retry_target(target_id, opts \\ []) when is_binary(target_id) do
    actor = actor_opts(opts, :agent_release_manager_retry)

    case AgentReleaseTarget.get_by_id(target_id, actor: actor) do
      {:ok, %AgentReleaseTarget{} = target} -> do_retry_target(target, actor)
      {:ok, nil} -> {:error, :target_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_retry_target(target, actor) do
    with :ok <- ensure_retryable_target(target),
         {:ok, %AgentReleaseRollout{} = rollout} <-
           AgentReleaseRollout.get_by_id(target.rollout_id, actor: actor),
         {:ok, %AgentReleaseRollout{} = rollout} <- prepare_rollout_for_retry(rollout, actor),
         {:ok, reset_target} <- reset_target_for_retry(target, actor) do
      maybe_dispatch_rollout(rollout.id, actor: actor)
      {:ok, reset_target}
    end
  end

  def create_rollout(attrs, opts \\ []) do
    actor = actor_opts(opts, :agent_release_manager_rollout)

    with {:ok, release} <- load_release(attrs, actor),
         agent_ids =
           normalize_agent_ids(Map.get(attrs, :agent_ids) || Map.get(attrs, "agent_ids")),
         :ok <- validate_rollout_agent_ids(release, agent_ids, actor),
         :ok <- cancel_overlapping_active_rollouts(agent_ids, actor),
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
        reconcile_agent_targets(agent_id, AgentRuntimeMetadata.hydrate_agent(agent), actor)
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
        mark_release_result_status(target, data, actor)
        maybe_complete_rollout(target.rollout_id, actor)
        maybe_dispatch_rollout(target.rollout_id, actor: actor)
        :ok

      _ ->
        :ok
    end
  end

  def handle_command_result(_data, _opts), do: :ok

  def handle_command_expired(command, opts \\ [])

  def handle_command_expired(%AgentCommand{command_type: @release_command_type} = command, opts) do
    actor = actor_opts(opts, :agent_release_manager_expire)

    case AgentReleaseTarget.get_by_command_id(command.id, actor: actor) do
      {:ok, %AgentReleaseTarget{status: status} = target} when status in @inflight_statuses ->
        _ =
          mark_target_status(
            target,
            :failed,
            %{
              last_status_message: "release command expired before the agent reported a result",
              last_error: "command_expired"
            },
            actor
          )

        maybe_complete_rollout(target.rollout_id, actor)
        maybe_dispatch_rollout(target.rollout_id, actor: actor)
        :ok

      _ ->
        :ok
    end
  end

  def handle_command_expired(_command, _opts), do: :ok

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
      dispatch_pending_targets(rollout, release, actor, capacity)
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

  defp reconcile_agent_targets(agent_id, agent, actor) do
    targets = active_targets_for_agent(agent_id, actor)

    if targets == [] do
      reconcile_stale_terminal_release_state(agent, actor)
    else
      Enum.each(targets, &reconcile_target(&1, agent, actor))
    end
  end

  defp reconcile_target(target, agent, actor) do
    if version_matches?(agent.version, target.desired_version) do
      _ =
        mark_target_status(
          target,
          :healthy,
          %{
            current_version: agent.version,
            last_status_message: reconcile_completion_message(target),
            progress_percent: 100
          },
          actor
        )

      maybe_complete_rollout(target.rollout_id, actor)
      :ok
    else
      case retry_unacknowledged_release_command(target, actor) do
        {:retried, _target} ->
          :ok

        :no_retry ->
          maybe_dispatch_rollout(target.rollout_id, actor: actor)
      end
    end
  end

  # A heartbeat reconcile can win the race against the agent's command result and
  # complete the target itself. Only call it "already at desired version" when the
  # target was truly never rolled out (still pending with no dispatched command);
  # otherwise it was an active update that converged, so use completion wording
  # consistent with the command-result path.
  defp reconcile_completion_message(%AgentReleaseTarget{status: :pending, command_id: nil}),
    do: "agent already at desired version"

  defp reconcile_completion_message(%AgentReleaseTarget{}), do: "release activated"

  defp retry_unacknowledged_release_command(
         %AgentReleaseTarget{status: status, command_id: command_id} = target,
         actor
       )
       when status in @inflight_statuses and not is_nil(command_id) do
    if release_command_unacknowledged_timed_out?(command_id, actor) do
      case mark_target_status(
             target,
             :pending,
             %{
               command_id: nil,
               progress_percent: 0,
               last_status_message: "release command was not acknowledged; retrying dispatch",
               last_error: "command_ack_timeout"
             },
             actor
           ) do
        {:ok, updated_target} ->
          maybe_dispatch_rollout(updated_target.rollout_id, actor: actor)
          {:retried, updated_target}

        _ ->
          :no_retry
      end
    else
      :no_retry
    end
  end

  defp retry_unacknowledged_release_command(_target, _actor), do: :no_retry

  defp release_command_unacknowledged_timed_out?(command_id, actor) do
    case AgentCommand.get_by_id(command_id, actor: actor) do
      {:ok,
       %AgentCommand{
         status: :sent,
         sent_at: %DateTime{} = sent_at,
         acknowledged_at: nil
       }} ->
        DateTime.diff(DateTime.utc_now(), sent_at, :second) >= release_ack_timeout_seconds()

      _ ->
        false
    end
  end

  defp release_ack_timeout_seconds do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:release_ack_timeout_seconds, @release_ack_timeout_seconds)
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
         agent = AgentRuntimeMetadata.hydrate_agent(agent),
         false <- version_matches?(agent.version, target.desired_version),
         {:ok, artifact} <- select_artifact(release, agent),
         {:ok, command_id} <-
           dispatch_release_command(target, rollout, release, artifact, agent, actor) do
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

      {:error, {:agent_offline, agent_id}} ->
        mark_target_waiting_for_control_stream(target, actor, {:agent_offline, agent_id})

      {:error, :agent_offline} ->
        mark_target_waiting_for_control_stream(target, actor, :agent_offline)

      # The artifact mirror is not ready to serve yet. Keep the target pending so
      # dispatch retries once the mirror settles rather than terminally failing an
      # agent for a transient not-ready condition.
      {:error, :artifact_not_mirrored} ->
        _ =
          mark_target_status(
            target,
            :pending,
            %{
              last_status_message: "waiting for release artifact mirror",
              last_error: normalize_reason(:artifact_not_mirrored)
            },
            actor
          )

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

  defp mark_target_waiting_for_control_stream(target, actor, reason) do
    _ =
      mark_target_status(
        target,
        :pending,
        %{
          last_status_message: "waiting for agent control stream",
          last_error: normalize_reason(reason)
        },
        actor
      )

    :pending
  end

  defp dispatch_release_command(target, rollout, release, artifact, agent, actor) do
    with {:ok, transport} <- ReleaseArtifactDelivery.gateway_transport(target, release, agent) do
      payload =
        compact_map(%{
          "release_id" => release.id,
          "rollout_id" => rollout.id,
          "target_id" => target.id,
          "version" => release.version,
          "manifest" => release.manifest,
          "signature" => release.signature,
          "artifact" => artifact,
          "artifact_transport" => transport,
          "helper_install" => helper_install_payload(artifact)
        })

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
  end

  defp helper_install_payload(artifact) do
    if AgentReleaseArtifactPolicy.rdp_artifact?(artifact) do
      compact_map(%{
        "enabled" => true,
        "capability" => "remote_access.rdp",
        "helper_protocol_version" =>
          map_get_any(artifact, [:helper_protocol_version, "helper_protocol_version"], nil),
        "compatible_agent_versions" =>
          map_get_any(artifact, [:compatible_agent_versions, "compatible_agent_versions"], %{}),
        "deployment_requirements" =>
          map_get_any(artifact, [:deployment_requirements, "deployment_requirements"], %{})
      })
    end
  end

  defp mark_release_result_status(target, data, actor) do
    payload = Map.get(data, :payload) || %{}
    message = Map.get(data, :message)

    case release_result_status(payload, Map.get(data, :success)) do
      {:failed, reason} ->
        handle_failed_release_result(target, reason, message, actor)

      result ->
        {status, attrs} = release_result_update_attrs(result, target, message)
        _ = mark_target_status(target, status, attrs, actor)
        :ok
    end
  end

  # A transient download failure (e.g. a not-ready 403/404/409/424, a 5xx, or a
  # network blip) that an agent reports after exhausting its own in-band retries
  # is auto-retried a bounded number of times: reset the target to pending so the
  # rollout re-dispatches a fresh command/token. Hard failures (bad signature,
  # incompatible platform) stay terminal.
  defp handle_failed_release_result(target, reason, message, actor) do
    retry_count = auto_retry_count(target)
    max_retries = max_auto_release_retries()

    if transient_release_failure?(reason) and retry_count < max_retries do
      next_count = retry_count + 1

      _ =
        mark_target_status(
          target,
          :pending,
          %{
            command_id: nil,
            progress_percent: 0,
            last_status_message:
              "release download failed transiently; auto-retrying (#{next_count}/#{max_retries})",
            last_error: normalize_reason(reason),
            metadata: put_auto_retry_count(target, next_count)
          },
          actor
        )

      :ok
    else
      {status, attrs} = release_result_update_attrs({:failed, reason}, target, message)
      _ = mark_target_status(target, status, attrs, actor)
      :ok
    end
  end

  defp ensure_retryable_target(%AgentReleaseTarget{status: status})
       when status in @retryable_target_statuses, do: :ok

  defp ensure_retryable_target(%AgentReleaseTarget{}), do: {:error, :target_not_retryable}

  # An active rollout can dispatch immediately; a completed rollout is reactivated
  # so the retried target dispatches and the rollout can re-complete; a paused
  # rollout keeps the reset target pending until it resumes; a canceled rollout
  # will not revive a single target.
  defp prepare_rollout_for_retry(%AgentReleaseRollout{status: :active} = rollout, _actor),
    do: {:ok, rollout}

  defp prepare_rollout_for_retry(%AgentReleaseRollout{status: :paused} = rollout, _actor),
    do: {:ok, rollout}

  defp prepare_rollout_for_retry(%AgentReleaseRollout{status: :completed} = rollout, actor),
    do: AgentReleaseRollout.reactivate(rollout, actor: actor)

  defp prepare_rollout_for_retry(%AgentReleaseRollout{status: :canceled}, _actor),
    do: {:error, :rollout_canceled}

  defp reset_target_for_retry(target, actor) do
    attrs = %{
      status: :pending,
      command_id: nil,
      progress_percent: 0,
      last_error: nil,
      last_status_message: "manual retry requested",
      dispatched_at: nil,
      completed_at: nil,
      metadata: Map.put(target.metadata || %{}, "auto_retry_count", 0)
    }

    case AgentReleaseTarget.set_status(target, attrs, actor: actor) do
      {:ok, updated_target} ->
        sync_agent_release_state(
          updated_target.agent_id,
          updated_target.desired_version,
          :pending,
          nil,
          actor
        )

        broadcast_target_status_change(updated_target)
        {:ok, updated_target}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auto_retry_count(%AgentReleaseTarget{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "auto_retry_count") do
      count when is_integer(count) and count >= 0 ->
        count

      count when is_binary(count) ->
        case Integer.parse(count) do
          {parsed, _} when parsed >= 0 -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp auto_retry_count(_target), do: 0

  defp put_auto_retry_count(%AgentReleaseTarget{metadata: metadata}, count) when is_map(metadata),
    do: Map.put(metadata, "auto_retry_count", count)

  defp put_auto_retry_count(_target, count), do: %{"auto_retry_count" => count}

  defp max_auto_release_retries do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_auto_release_retries, @max_auto_release_retries)
  end

  defp transient_release_failure?(reason) do
    normalized = reason |> normalize_reason() |> String.downcase()

    cond do
      String.contains?(normalized, "status") and transient_status_reason?(normalized) -> true
      Enum.any?(@transient_release_markers, &String.contains?(normalized, &1)) -> true
      true -> false
    end
  end

  defp transient_status_reason?(normalized) do
    Enum.any?(@transient_release_status_codes, fn code ->
      String.contains?(normalized, "status #{code}")
    end)
  end

  defp release_result_update_attrs({:staged, staged_version}, target, message) do
    {:staged,
     %{
       current_version: staged_version || target.current_version,
       progress_percent: 100,
       last_status_message: message,
       last_error: nil
     }}
  end

  defp release_result_update_attrs({:healthy, current_version}, target, message) do
    {:healthy,
     %{
       current_version: current_version || target.current_version,
       progress_percent: 100,
       last_status_message: message,
       last_error: nil
     }}
  end

  defp release_result_update_attrs({:rolled_back, reason}, _target, message) do
    {:rolled_back,
     %{
       last_status_message: message,
       last_error: reason || "rolled_back"
     }}
  end

  defp release_result_update_attrs({:failed, reason}, _target, message) do
    {:failed,
     %{
       last_status_message: message,
       last_error: reason || "command_failed"
     }}
  end

  defp select_artifact(release, agent) do
    agent = AgentRuntimeMetadata.hydrate_agent(agent)

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

        AgentReleaseArtifactPolicy.enabled?(artifact) and
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
      |> clear_stale_last_error(status)
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

        broadcast_target_status_change(updated_target)

        {:ok, updated_target}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_target_status_change(%AgentReleaseTarget{} = target) do
    AgentCommandPubSub.broadcast_release_target_status(%{
      rollout_id: target.rollout_id,
      agent_id: target.agent_id,
      status: target.status,
      progress_percent: target.progress_percent,
      last_status_message: target.last_status_message,
      last_error: target.last_error
    })
  end

  defp clear_stale_last_error(attrs, status)
       when status in [:dispatched, :downloading, :verifying, :staged, :restarting, :healthy] do
    Map.put_new(attrs, :last_error, nil)
  end

  defp clear_stale_last_error(attrs, _status), do: attrs

  defp sync_agent_release_state(agent_id, desired_version, status, last_error, actor, opts \\ []) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} ->
        update_attrs =
          %{
            desired_version: desired_version,
            release_rollout_state: status,
            last_update_at: DateTime.utc_now(),
            version: Keyword.get(opts, :current_version)
          }
          |> compact_map()
          |> Map.put(:last_update_error, last_error)

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

  defp cancel_overlapping_active_rollouts([], _actor), do: :ok

  defp cancel_overlapping_active_rollouts(agent_ids, actor) do
    requested_agent_ids = MapSet.new(agent_ids)

    AgentReleaseRollout
    |> Ash.Query.for_read(:active)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rollouts} ->
        rollouts
        |> Enum.filter(&rollout_overlaps?(&1, requested_agent_ids))
        |> Enum.each(fn rollout ->
          _ = cancel_rollout(rollout.id, actor: actor)
        end)

        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp rollout_overlaps?(
         %AgentReleaseRollout{cohort_agent_ids: cohort_agent_ids},
         requested_agent_ids
       )
       when is_list(cohort_agent_ids) do
    cohort_agent_ids
    |> MapSet.new()
    |> MapSet.disjoint?(requested_agent_ids)
    |> Kernel.not()
  end

  defp rollout_overlaps?(_rollout, _requested_agent_ids), do: false

  defp dispatch_pending_targets(_rollout, _release, _actor, capacity) when capacity <= 0, do: :ok

  defp dispatch_pending_targets(rollout, release, actor, capacity) do
    _remaining_capacity =
      rollout.id
      |> pending_targets(actor)
      |> Enum.reduce_while(capacity, fn target, remaining ->
        dispatch_pending_target(target, rollout, release, actor, remaining)
      end)

    :ok
  end

  defp dispatch_pending_target(target, rollout, release, actor, remaining) do
    case dispatch_target(target, rollout, release, actor) do
      {:ok, _command_id} when remaining > 1 -> {:cont, remaining - 1}
      {:ok, _command_id} -> {:halt, 0}
      :pending -> {:cont, remaining}
      {:error, _reason} -> {:cont, remaining}
    end
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

  defp reconcile_stale_terminal_release_state(%Agent{} = agent, actor) do
    agent = AgentRuntimeMetadata.hydrate_agent(agent)

    with current_version when is_binary(current_version) <- agent.version,
         desired_version when is_binary(desired_version) <- agent.desired_version,
         true <- agent.release_rollout_state in @terminal_statuses,
         true <- release_version_at_least?(current_version, desired_version) do
      _ =
        agent
        |> Ash.Changeset.for_update(:update_release_status, %{
          desired_version: current_version,
          release_rollout_state: :healthy,
          last_update_at: DateTime.utc_now(),
          last_update_error: nil
        })
        |> Ash.update(actor: actor)
    end

    :ok
  end

  defp release_version_at_least?(current_version, desired_version) do
    case {parse_release_version(current_version), parse_release_version(desired_version)} do
      {{:ok, current}, {:ok, desired}} -> current >= desired
      _ -> String.trim(current_version) == String.trim(desired_version)
    end
  end

  defp parse_release_version(version) when is_binary(version) do
    normalized =
      version
      |> String.trim()
      |> String.trim_leading("v")
      |> String.split("-", parts: 2)
      |> List.first()
      |> String.split(".")

    case normalized do
      [major, minor, patch] ->
        with {major, ""} <- Integer.parse(major),
             {minor, ""} <- Integer.parse(minor),
             {patch, ""} <- Integer.parse(patch) do
          {:ok, {major, minor, patch}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_release_version(_version), do: :error

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
      {:ok, %Agent{} = agent} ->
        agent |> AgentRuntimeMetadata.hydrate_agent() |> Map.get(:version)

      _ ->
        nil
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

  defp list_agents_by_uid(agent_ids, actor) do
    Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid in ^agent_ids)
    |> Ash.read!(actor: actor)
    |> AgentRuntimeMetadata.hydrate_agents()
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

  defp normalize_reason(:artifact_not_mirrored),
    do: "release artifact is not mirrored into internal storage"

  defp normalize_reason({:agent_offline, agent_id}),
    do: "agent control stream is offline for #{agent_id}"

  defp normalize_reason(:agent_offline), do: "agent control stream is offline"

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
      {key, nil} when key in [:command_id, :last_error] -> false
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
      Map.put(acc, key, normalize_nested_value(value))
    end)
  end

  defp normalize_keys(other), do: other

  defp normalize_nested_value(value) when is_map(value), do: normalize_keys(value)

  defp normalize_nested_value(value) when is_list(value),
    do: Enum.map(value, &normalize_nested_value/1)

  defp normalize_nested_value(value), do: value

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

  defp artifact_mirror do
    Application.get_env(
      :serviceradar_core,
      :agent_release_artifact_mirror_module,
      ReleaseArtifactMirror
    )
  end
end
