defmodule ServiceRadarCoreElx.CameraRelay.BoomboxBranchManager do
  @moduledoc """
  Tracks relay-scoped Boombox output branches attached to the shared relay pipeline.
  """

  use GenServer

  alias ServiceRadar.Telemetry
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  @default_max_branches_per_session 1

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
           Keyword.get(analysis_opts, :max_boombox_branches_per_session, @default_max_branches_per_session),
           @default_max_branches_per_session
         )
     }}
  end

  @impl true
  def handle_call({:open_branch, attrs}, _from, state) do
    relay_session_id = required_string!(attrs, :relay_session_id)
    branch_id = required_string!(attrs, :branch_id)
    output = Map.fetch!(attrs, :output)

    if get_in(state.branches, [relay_session_id, branch_id]) do
      {:reply, {:error, :already_exists}, state}
    else
      if relay_branch_count(state, relay_session_id) >= state.max_branches_per_session do
        emit_event(state, :limit_rejected, relay_session_id, branch_id,
          limit: "max_boombox_branches_per_session",
          output: output
        )

        {:reply, {:error, :limit_reached}, state}
      else
        case pipeline_manager(state).add_boombox_branch(relay_session_id, branch_id, output: output) do
          :ok ->
            branch = %{
              relay_session_id: relay_session_id,
              branch_id: branch_id,
              output: output
            }

            next_state =
              update_in(state.branches, fn branches ->
                Map.update(branches, relay_session_id, %{branch_id => branch}, &Map.put(&1, branch_id, branch))
              end)

            emit_event(next_state, :branch_opened, relay_session_id, branch_id, output: output)
            emit_branch_count(next_state, relay_session_id, branch_id)

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
        _ = pipeline_manager(state).remove_boombox_branch(relay_session_id, branch_id)

        emit_event(next_state, :branch_closed, relay_session_id, branch_id,
          output: branch.output,
          reason: "requested_close"
        )

        emit_branch_count(next_state, relay_session_id, branch_id)
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

  defp relay_branch_count(state, relay_session_id) do
    state.branches
    |> Map.get(relay_session_id, %{})
    |> map_size()
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

  defp emit_event(state, event, relay_session_id, branch_id, attrs) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      event,
      %{
        relay_boundary: "core_elx",
        relay_session_id: relay_session_id,
        branch_id: branch_id,
        reason: attrs[:reason],
        limit: attrs[:limit],
        adapter: "boombox"
      },
      %{
        branch_count: relay_branch_count(state, relay_session_id),
        output_size: output_size(attrs[:output])
      }
    )
  end

  defp emit_branch_count(state, relay_session_id, branch_id) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      :branch_count_changed,
      %{
        relay_boundary: "core_elx",
        relay_session_id: relay_session_id,
        branch_id: branch_id,
        adapter: "boombox"
      },
      %{branch_count: relay_branch_count(state, relay_session_id)}
    )
  end

  defp output_size(output) when is_binary(output), do: byte_size(output)
  defp output_size(_output), do: 0

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp required_string!(attrs, key) do
    case attrs |> Map.get(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp pipeline_manager(state), do: state.pipeline_manager
end
