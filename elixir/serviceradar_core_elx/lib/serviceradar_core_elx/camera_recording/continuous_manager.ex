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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.RecordingControlState
  alias ServiceRadarCoreElx.CameraRecording.ContinuousRecorder
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor

  require Ash.Query
  require Logger

  @default_interval_ms 5_000
  @system_actor SystemActor.system(:camera_continuous_manager)

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
      enabled_fn: Keyword.get(opts, :enabled_fn, &default_enabled?/0),
      control_stopped_fn: Keyword.get(opts, :control_stopped_fn, &default_control_stopped?/0),
      list_policies_fn: Keyword.get(opts, :list_policies_fn, &default_list_continuous_policies/0),
      start_recorder_fn: Keyword.get(opts, :start_recorder_fn, &default_start_recorder/1),
      stop_recorder_fn: Keyword.get(opts, :stop_recorder_fn, &ContinuousRecorder.stop/2),
      update_policy_fn: Keyword.get(opts, :update_policy_fn, &ContinuousRecorder.update_policy/2),
      running: %{},
      monitors: %{},
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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {key, monitors} ->
        {:noreply, %{state | monitors: monitors, running: Map.delete(state.running, key)}}
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
    Enum.each(state.running, fn {_key, %{pid: pid}} ->
      state.stop_recorder_fn.(pid, reason)
    end)

    state
  end

  defp stop_removed_policies(state, desired) do
    Enum.each(state.running, fn {key, %{pid: pid}} ->
      if not Map.has_key?(desired, key) do
        state.stop_recorder_fn.(pid, :policy_disabled)
      end
    end)

    state
  end

  defp sync_desired_policies(state, desired) do
    Enum.reduce(desired, state, fn {key, policy}, acc ->
      case Map.get(acc.running, key) do
        nil ->
          start_for_policy(acc, key, policy)

        %{pid: pid, policy_revision: rev, nvr_member: member} ->
          sync_existing_recorder(acc, key, pid, rev, member, policy)
      end
    end)
  end

  defp sync_existing_recorder(state, _key, pid, _rev, member, %{nvr_member: new_member}) when member != new_member do
    # Assignment transition: stop, seal, release; next tick starts on new member.
    state.stop_recorder_fn.(pid, :member_changed)
    state
  end

  defp sync_existing_recorder(state, key, pid, rev, _member, %{policy_revision: new_rev} = policy) when rev != new_rev do
    state.update_policy_fn.(pid, policy)
    put_in(state.running[key].policy_revision, new_rev)
  end

  defp sync_existing_recorder(state, _key, _pid, _rev, _member, _policy), do: state

  defp start_for_policy(state, key, policy) do
    case state.start_recorder_fn.(policy) do
      {:ok, pid} when is_pid(pid) ->
        ref = Process.monitor(pid)

        entry = %{
          pid: pid,
          nvr_member: policy.nvr_member,
          policy_revision: Map.get(policy, :policy_revision, 1)
        }

        %{
          state
          | running: Map.put(state.running, key, entry),
            monitors: Map.put(state.monitors, ref, key)
        }

      {:error, {:already_started, pid}} when is_pid(pid) ->
        ref = Process.monitor(pid)

        entry = %{
          pid: pid,
          nvr_member: policy.nvr_member,
          policy_revision: Map.get(policy, :policy_revision, 1)
        }

        %{
          state
          | running: Map.put(state.running, key, entry),
            monitors: Map.put(state.monitors, ref, key)
        }

      {:error, reason} ->
        Logger.warning(
          "ContinuousManager failed to start recorder for #{policy.camera_source_id}/#{policy.stream_profile_id}: #{inspect(reason, limit: 8)}"
        )

        state
    end
  end

  defp schedule_tick(%{interval_ms: ms} = state) when is_integer(ms) and ms > 0 do
    %{state | timer: Process.send_after(self(), :reconcile, ms)}
  end

  defp schedule_tick(state), do: state

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

  defp default_start_recorder(policy) do
    RecordingSupervisor.start_continuous_recorder(policy: policy)
  end
end
