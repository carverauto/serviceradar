defmodule ServiceRadarCoreElx.CameraRecording.ContinuousManager do
  @moduledoc """
  Policy-driven reconciler that starts and stops `ContinuousRecorder` workers
  under `ServiceRadarCoreElx.CameraRecording.Supervisor` (`A.3.1`, design `A3`).

  Active only when `SERVICERADAR_CAMERA_RECORDING_ENABLED=true` (and the repo is
  enabled). Periodically reads `CameraRecordingPolicy` rows with `mode == :continuous`,
  starts a recorder for each enabled `(camera_source_id, stream_profile_id)` pair,
  forwards storage-only policy updates in place, and cleanly stops recorders when
  policies are disabled, reassigned to another NVR member, or when durable
  `RecordingControl` stop is enforced.
  """

  use GenServer

  import Bitwise

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.RecordingControlState
  alias ServiceRadarCoreElx.CameraRecording.ContinuousRecorder
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor

  require Ash.Query
  require Logger

  @default_interval_ms 5_000
  @default_initial_backoff_ms 5_000
  @default_max_backoff_ms 300_000
  @system_actor SystemActor.system(:camera_continuous_manager)
  @intentional_stop_reasons [:policy_disabled, :recording_disabled, :recording_stopped, :member_changed]

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Triggers an immediate synchronous policy reconciliation pass."
  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @doc "Returns the currently tracked continuous recorder map keyed by `{camera_source_id, stream_profile_id}`."
  @spec running(GenServer.server()) :: map()
  def running(server \\ __MODULE__), do: GenServer.call(server, :running)

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    state = %{
      interval_ms: interval_ms,
      initial_backoff_ms: Keyword.get(opts, :initial_backoff_ms, @default_initial_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
      now_ms_fn: Keyword.get(opts, :now_ms_fn, &default_now_ms/0),
      enabled_fn: Keyword.get(opts, :enabled_fn, &default_enabled?/0),
      control_stopped_fn: Keyword.get(opts, :control_stopped_fn, &default_control_stopped?/0),
      list_policies_fn: Keyword.get(opts, :list_policies_fn, &default_list_continuous_policies/0),
      start_recorder_fn: Keyword.get(opts, :start_recorder_fn, &default_start_recorder/2),
      stop_recorder_fn: Keyword.get(opts, :stop_recorder_fn, &ContinuousRecorder.stop/2),
      update_policy_fn: Keyword.get(opts, :update_policy_fn, &ContinuousRecorder.update_policy/2),
      running: %{},
      monitors: %{},
      pid_keys: %{},
      failures: %{},
      timer: nil
    }

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    {:reply, :ok, do_reconcile(state)}
  end

  def handle_call(:running, _from, state) do
    {:reply, state.running, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    next =
      state
      |> Map.put(:timer, nil)
      |> do_reconcile()
      |> schedule_tick()

    {:noreply, next}
  end

  def handle_info({:continuous_recorder, pid, {:run_started, _info}}, state) do
    case Map.get(state.pid_keys, pid) do
      nil ->
        {:noreply, state}

      key ->
        running =
          case Map.get(state.running, key) do
            %{pid: ^pid} = entry -> Map.put(state.running, key, %{entry | started?: true})
            _ -> state.running
          end

        {:noreply, %{state | running: running, failures: Map.delete(state.failures, key)}}
    end
  end

  def handle_info({:continuous_recorder, pid, {:run_stopped, info}}, state) when is_map(info) do
    case Map.get(state.pid_keys, pid) do
      nil ->
        {:noreply, state}

      key ->
        running =
          case Map.get(state.running, key) do
            %{pid: ^pid} = entry -> Map.put(state.running, key, %{entry | stop_info: info})
            _ -> state.running
          end

        {:noreply, %{state | running: running}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {key, monitors} ->
        {entry, running} = Map.pop(state.running, key)
        pid_keys = Map.delete(state.pid_keys, pid)

        next = %{state | monitors: monitors, running: running, pid_keys: pid_keys}
        {:noreply, update_failure_on_exit(next, key, entry, reason)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_reconcile(state) do
    cond do
      not state.enabled_fn.() ->
        stop_all_running(state, :recording_disabled)

      state.control_stopped_fn.() ->
        stop_all_running(state, :recording_stopped)

      true ->
        reconcile_policies(state)
    end
  end

  defp reconcile_policies(state) do
    case state.list_policies_fn.() do
      {:ok, policies} when is_list(policies) ->
        desired =
          Map.new(policies, fn policy ->
            {{policy.camera_source_id, policy.stream_profile_id}, policy}
          end)

        state
        |> stop_removed_policies(desired)
        |> sync_desired_policies(desired)

      {:error, reason} ->
        Logger.warning("ContinuousManager policy query failed: #{inspect(reason, limit: 8)}")
        state
    end
  end

  defp stop_all_running(state, reason) do
    running =
      Map.new(state.running, fn {key, %{pid: pid} = entry} ->
        state.stop_recorder_fn.(pid, reason)
        {key, %{entry | stopping_reason: reason}}
      end)

    %{state | running: running, failures: %{}}
  end

  defp stop_removed_policies(state, desired) do
    running =
      Map.new(state.running, fn {key, %{pid: pid} = entry} ->
        if Map.has_key?(desired, key) do
          {key, entry}
        else
          state.stop_recorder_fn.(pid, :policy_disabled)
          {key, %{entry | stopping_reason: :policy_disabled}}
        end
      end)

    failures = Map.take(state.failures, Map.keys(desired))
    %{state | running: running, failures: failures}
  end

  defp sync_desired_policies(state, desired) do
    Enum.reduce(desired, state, fn {key, policy}, acc ->
      case Map.get(acc.running, key) do
        nil ->
          maybe_start_for_policy(acc, key, policy)

        %{pid: pid, policy_revision: rev, nvr_member: member} ->
          sync_existing_recorder(acc, key, pid, rev, member, policy)
      end
    end)
  end

  defp sync_existing_recorder(state, key, pid, _rev, member, %{nvr_member: new_member}) when member != new_member do
    # Assignment transition: stop, seal, release; next tick starts on new member.
    state.stop_recorder_fn.(pid, :member_changed)
    put_in(state.running[key].stopping_reason, :member_changed)
  end

  defp sync_existing_recorder(state, key, pid, rev, _member, %{policy_revision: new_rev} = policy) when rev != new_rev do
    state.update_policy_fn.(pid, policy)
    put_in(state.running[key].policy_revision, new_rev)
  end

  defp sync_existing_recorder(state, _key, _pid, _rev, _member, _policy), do: state

  defp maybe_start_for_policy(state, key, policy) do
    failure =
      case Map.get(state.failures, key) do
        %{nvr_member: prev_member} when prev_member != policy.nvr_member -> nil
        existing -> existing
      end

    state = if failure == nil, do: %{state | failures: Map.delete(state.failures, key)}, else: state

    if failure != nil and state.now_ms_fn.() < failure.next_retry_at_ms do
      state
    else
      start_for_policy(state, key, policy, failure)
    end
  end

  defp start_for_policy(state, key, policy, failure) do
    record_startup_gap? = not (failure != nil and failure.startup_gap_recorded?)
    start_opts = [notify: self(), record_startup_gap?: record_startup_gap?]

    case invoke_start_recorder(state.start_recorder_fn, policy, start_opts) do
      {:ok, pid} when is_pid(pid) ->
        track_started_recorder(state, key, policy, pid)

      {:error, {:already_started, pid}} when is_pid(pid) ->
        track_started_recorder(state, key, policy, pid)

      {:error, reason} ->
        Logger.warning(
          "ContinuousManager failed to start recorder for #{policy.camera_source_id}/#{policy.stream_profile_id}: #{inspect(reason, limit: 8)}"
        )

        record_failure_backoff(state, key, policy.nvr_member, reason, false)
    end
  end

  defp invoke_start_recorder(fun, policy, start_opts) when is_function(fun, 2), do: fun.(policy, start_opts)
  defp invoke_start_recorder(fun, policy, _start_opts) when is_function(fun, 1), do: fun.(policy)

  defp track_started_recorder(state, key, policy, pid) do
    ref = Process.monitor(pid)

    entry = %{
      pid: pid,
      nvr_member: policy.nvr_member,
      policy_revision: Map.get(policy, :policy_revision, 1),
      started?: false,
      stopping_reason: nil,
      stop_info: nil
    }

    %{
      state
      | running: Map.put(state.running, key, entry),
        monitors: Map.put(state.monitors, ref, key),
        pid_keys: Map.put(state.pid_keys, pid, key)
    }
  end

  defp update_failure_on_exit(state, _key, nil, _exit_reason), do: state

  defp update_failure_on_exit(state, key, entry, exit_reason) do
    stop_info = entry.stop_info || %{}
    stop_reason = Map.get(stop_info, :reason)
    intentional? = entry.stopping_reason != nil or stop_reason in @intentional_stop_reasons

    if intentional? do
      %{state | failures: Map.delete(state.failures, key)}
    else
      gap_recorded? = Map.get(stop_info, :startup_gap_recorded?, false) == true
      failure_reason = stop_reason || exit_reason
      record_failure_backoff(state, key, entry.nvr_member, failure_reason, gap_recorded?)
    end
  end

  defp record_failure_backoff(state, key, nvr_member, reason, gap_recorded?) do
    prev = Map.get(state.failures, key, %{attempts: 0, startup_gap_recorded?: false})
    attempts = prev.attempts + 1
    delay_ms = backoff_delay_ms(state, attempts)

    failure = %{
      attempts: attempts,
      nvr_member: nvr_member,
      next_retry_at_ms: state.now_ms_fn.() + delay_ms,
      startup_gap_recorded?: prev.startup_gap_recorded? or gap_recorded?,
      last_reason: reason
    }

    %{state | failures: Map.put(state.failures, key, failure)}
  end

  defp backoff_delay_ms(%{initial_backoff_ms: initial, max_backoff_ms: max_ms}, attempts) do
    min(max_ms, initial * bsl(1, min(attempts - 1, 16)))
  end

  defp schedule_tick(%{interval_ms: ms} = state) when is_integer(ms) and ms > 0 do
    %{state | timer: Process.send_after(self(), :reconcile, ms)}
  end

  defp schedule_tick(state), do: state

  defp default_now_ms, do: System.monotonic_time(:millisecond)

  defp default_enabled? do
    RecordingSupervisor.enabled?() and
      Application.get_env(:serviceradar_core, :repo_enabled, true) == true
  end

  defp default_control_stopped? do
    case Ash.get(RecordingControlState, "deployment", actor: @system_actor, not_found_error?: false) do
      {:ok, %{stopped: true}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp default_list_continuous_policies do
    CameraRecordingPolicy
    |> Ash.Query.filter(mode == :continuous)
    |> Ash.read(actor: @system_actor)
  end

  defp default_start_recorder(policy, opts) do
    RecordingSupervisor.start_continuous_recorder(Keyword.put(opts, :policy, policy))
  end
end
