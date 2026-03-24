defmodule ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager do
  @moduledoc """
  Tracks relay-scoped analysis branches attached to the shared Membrane ingest path.
  """

  use GenServer

  alias ServiceRadar.Telemetry
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  @default_max_branches_per_session 2
  @default_min_sample_interval_ms 250
  @default_max_queue_len 32

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open_branch(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:open_branch, attrs})
  end

  def close_branch(relay_session_id, branch_id) when is_binary(relay_session_id) and is_binary(branch_id) do
    GenServer.call(__MODULE__, {:close_branch, relay_session_id, branch_id})
  end

  def list_branches(relay_session_id) when is_binary(relay_session_id) do
    GenServer.call(__MODULE__, {:list_branches, relay_session_id})
  end

  @impl true
  def init(opts) do
    analysis_opts =
      Keyword.get(
        opts,
        :analysis_opts,
        Application.get_env(:serviceradar_core_elx, :camera_relay_analysis, [])
      )

    {:ok,
     %{
       branches: %{},
       pipeline_manager:
         Keyword.get(
           opts,
           :pipeline_manager,
           Application.get_env(:serviceradar_core_elx, :camera_relay_pipeline_manager, PipelineManager)
         ),
       telemetry_module:
         Keyword.get(
           opts,
           :telemetry_module,
           Application.get_env(:serviceradar_core_elx, :camera_relay_telemetry_module, Telemetry)
         ),
       max_branches_per_session:
         positive_integer(
           Keyword.get(analysis_opts, :max_branches_per_session, @default_max_branches_per_session),
           @default_max_branches_per_session
         ),
       min_sample_interval_ms:
         non_negative_integer(
           Keyword.get(analysis_opts, :min_sample_interval_ms, @default_min_sample_interval_ms),
           @default_min_sample_interval_ms
         ),
       default_max_queue_len:
         positive_integer(
           Keyword.get(analysis_opts, :default_max_queue_len, @default_max_queue_len),
           @default_max_queue_len
         )
     }}
  end

  @impl true
  def handle_call({:open_branch, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)
    branch_id = required_string!(attrs, :branch_id)
    subscriber = required_pid!(attrs, :subscriber)
    current_branch_count = relay_branch_count(state, relay_session_id)
    policy = normalize_policy(Map.get(attrs, :policy, %{}), state)

    if get_in(state.branches, [relay_session_id, branch_id]) do
      {:reply, {:error, :already_exists}, state}
    else
      if current_branch_count >= state.max_branches_per_session do
        emit_analysis_event(state, :limit_rejected, relay_session_id, branch_id,
          limit: "max_branches_per_session",
          sample_interval_ms: policy.sample_interval_ms,
          max_queue_len: policy.max_queue_len
        )

        {:reply, {:error, :limit_reached}, state}
      else
        case pipeline_manager(state).add_analysis_branch(relay_session_id, branch_id,
               subscriber: subscriber,
               policy: policy
             ) do
          :ok ->
            ref = Process.monitor(subscriber)

            branch = %{
              relay_session_id: relay_session_id,
              branch_id: branch_id,
              subscriber: subscriber,
              monitor_ref: ref,
              policy: policy
            }

            next_state =
              update_in(state.branches, fn branches ->
                Map.update(branches, relay_session_id, %{branch_id => branch}, &Map.put(&1, branch_id, branch))
              end)

            branch_count = relay_branch_count(next_state, relay_session_id)
            emit_branch_lifecycle(next_state, :branch_opened, branch, branch_count, reason: "opened")

            {:reply, {:ok, branch}, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end
    end
  end

  def handle_call({:close_branch, relay_session_id, branch_id}, _from, state) do
    case pop_branch(state, relay_session_id, branch_id) do
      {:ok, branch, next_state} ->
        Process.demonitor(branch.monitor_ref, [:flush])
        _ = pipeline_manager(state).remove_analysis_branch(relay_session_id, branch_id)

        emit_branch_lifecycle(next_state, :branch_closed, branch, relay_branch_count(next_state, relay_session_id),
          reason: "requested_close"
        )

        {:reply, :ok, next_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list_branches, relay_session_id}, _from, state) do
    branches =
      state.branches
      |> Map.get(relay_session_id, %{})
      |> Map.values()
      |> Enum.sort_by(& &1.branch_id)

    {:reply, branches, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case find_branch_by_ref(state, ref) do
      {:ok, branch} ->
        _ = pipeline_manager(state).remove_analysis_branch(branch.relay_session_id, branch.branch_id)

        next_state =
          delete_branch(
            state,
            branch.relay_session_id,
            branch.branch_id
          )

        emit_branch_lifecycle(
          next_state,
          :branch_closed,
          branch,
          relay_branch_count(next_state, branch.relay_session_id),
          reason: "subscriber_down"
        )

        {:noreply, next_state}

      :error ->
        {:noreply, state}
    end
  end

  defp find_branch_by_ref(state, ref) do
    state.branches
    |> Enum.flat_map(fn {_relay_session_id, branches} -> Map.values(branches) end)
    |> Enum.find_value(:error, fn branch ->
      if branch.monitor_ref == ref, do: {:ok, branch}, else: false
    end)
  end

  defp pop_branch(state, relay_session_id, branch_id) do
    case get_in(state.branches, [relay_session_id, branch_id]) do
      nil -> :error
      branch -> {:ok, branch, delete_branch(state, relay_session_id, branch_id)}
    end
  end

  defp delete_branch(state, relay_session_id, branch_id) do
    updated_relay_branches =
      state.branches
      |> Map.get(relay_session_id, %{})
      |> Map.delete(branch_id)

    branches =
      if map_size(updated_relay_branches) == 0 do
        Map.delete(state.branches, relay_session_id)
      else
        Map.put(state.branches, relay_session_id, updated_relay_branches)
      end

    %{state | branches: branches}
  end

  defp normalize_policy(policy, state) when is_map(policy) do
    %{
      sample_interval_ms:
        policy
        |> Map.get(:sample_interval_ms, Map.get(policy, "sample_interval_ms", 0))
        |> non_negative_integer(state.min_sample_interval_ms)
        |> max(state.min_sample_interval_ms),
      max_queue_len:
        policy
        |> Map.get(:max_queue_len, Map.get(policy, "max_queue_len", state.default_max_queue_len))
        |> positive_integer(state.default_max_queue_len)
    }
  end

  defp normalize_policy(_policy, state) do
    %{
      sample_interval_ms: state.min_sample_interval_ms,
      max_queue_len: state.default_max_queue_len
    }
  end

  defp relay_branch_count(state, relay_session_id) do
    state.branches
    |> Map.get(relay_session_id, %{})
    |> map_size()
  end

  defp emit_branch_lifecycle(state, event, branch, branch_count, extra_metadata) do
    emit_analysis_event(state, event, branch.relay_session_id, branch.branch_id,
      reason: extra_metadata[:reason],
      sample_interval_ms: branch.policy.sample_interval_ms,
      max_queue_len: branch.policy.max_queue_len
    )

    telemetry_module(state).emit_camera_relay_analysis_event(
      :branch_count_changed,
      %{
        relay_boundary: "core_elx",
        relay_session_id: branch.relay_session_id,
        branch_id: branch.branch_id
      },
      %{branch_count: branch_count}
    )
  end

  defp emit_analysis_event(state, event, relay_session_id, branch_id, metadata) do
    telemetry_module(state).emit_camera_relay_analysis_event(
      event,
      %{
        relay_boundary: "core_elx",
        relay_session_id: relay_session_id,
        branch_id: branch_id,
        reason: metadata[:reason],
        limit: metadata[:limit]
      },
      %{
        branch_count: relay_branch_count(state, relay_session_id),
        sample_interval_ms: metadata[:sample_interval_ms],
        max_queue_len: metadata[:max_queue_len]
      }
    )
  end

  defp telemetry_module(state), do: state.telemetry_module

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp non_negative_integer(_value, default), do: default

  defp required_string!(attrs, key) do
    case attrs |> Map.get(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp required_pid!(attrs, key) do
    case Map.get(attrs, key) do
      pid when is_pid(pid) -> pid
      _ -> raise ArgumentError, "#{key} is required"
    end
  end

  defp pipeline_manager(state), do: state.pipeline_manager
end
