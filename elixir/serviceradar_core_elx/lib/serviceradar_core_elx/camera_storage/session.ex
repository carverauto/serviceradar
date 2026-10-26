defmodule ServiceRadarCoreElx.CameraStorage.Session do
  @moduledoc false
  use GenServer

  alias ServiceRadarCoreElx.CameraStorage.CoreClient
  alias ServiceRadarCoreElx.CameraStorage.Tasks
  alias ServiceRadarCoreElx.CameraStorage.Upload

  @challenge_fields ~w(schema_version binding_id revision desired_sha256 state storage_boot_id nonce issued_at_ms expires_at_ms remaining_ms applied_revision recording_readiness archive_readiness reason)

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def upload(lease, bytes, deadline), do: call({:upload, lease, bytes, deadline}, 12_000)

  def reserve_media(lease, length, deadline), do: call({:reserve_media, lease, length, deadline}, 32_000)

  def finish_media(token, sha), do: call({:finish_media, token, sha}, 33_000)
  def release_media(token), do: call({:release_media, token}, 5_000)

  defp call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ -> {:error, :storage_operation_failed}
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    case staging_root(Map.get(config, :kind, :init)) do
      {:ok, scratch_root} ->
        state = %{
          config: config,
          boot: Ecto.UUID.generate(),
          nonce: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
          deadline: nil,
          task: nil,
          stage: nil,
          socket: nil,
          scratch_root: scratch_root
        }

        {:ok, state, {:continue, :challenge}}

      _ ->
        {:stop, :storage_scratch_reconciliation_required}
    end
  end

  @impl true
  def handle_continue(:challenge, state) do
    desired = state.config.desired

    request = %{
      "schema_version" => 1,
      "revision" => Integer.to_string(desired.revision),
      "binding_id" => desired.binding_id,
      "desired_sha256" => desired.desired_sha256,
      "storage_boot_id" => state.boot,
      "nonce" => state.nonce
    }

    started = System.monotonic_time(:millisecond)

    deadline =
      with {:ok, result} <- CoreClient.request(state.config.runtime, :challenge, request, 5_000),
           true <- Enum.sort(Map.keys(result)) == Enum.sort(@challenge_fields),
           true <- Enum.all?(request, fn {key, value} -> result[key] === value end),
           true <- result["state"] in ["pending", "applied"],
           remaining when is_integer(remaining) and remaining in 1..30_000 <- result["remaining_ms"] do
        started + remaining
      else
        _ -> nil
      end

    {:noreply, %{state | deadline: deadline}}
  end

  @impl true
  def handle_call({:upload, _, _, _}, _from, %{stage: stage} = state) when not is_nil(stage),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:upload, _lease, _bytes, _deadline}, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:upload, lease, bytes, deadline}, from, state) do
    if Map.get(state.config, :kind, :init) == :init && state.deadline &&
         System.monotonic_time(:millisecond) < state.deadline do
      config = owned_config(state.config)

      task =
        Task.Supervisor.async_nolink(Tasks, fn ->
          Upload.run(config, state.boot, state.deadline, lease, bytes, deadline)
        end)

      {:noreply, %{state | task: {task, from, :upload}}}
    else
      {:reply, {:error, :storage_authority_unavailable}, state}
    end
  end

  def handle_call({:reserve_media, _, _, _}, _from, %{stage: %{cleanup_failed: true}} = state),
    do: {:reply, {:error, :storage_scratch_reconciliation_required}, state}

  def handle_call({:reserve_media, _, _, _}, _from, %{stage: stage} = state) when not is_nil(stage),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:reserve_media, _, _, _}, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:reserve_media, lease, length, ingress_deadline}, {owner, _} = from, state) do
    with %{kind: :media} <- state.config,
         true <- is_integer(length) and length in 1..state.config.desired.limits["max_media_bytes"],
         true <- is_integer(state.deadline),
         deadline = min(ingress_deadline, state.deadline),
         true <- remaining(deadline) > 0,
         {:ok, directory} <- scratch_directory(state.scratch_root) do
      token = make_ref()

      stage = %{
        owner: owner,
        monitor: Process.monitor(owner),
        token: token,
        directory: directory,
        path: Path.join(directory, "media.m4s"),
        deadline: deadline,
        timer: Process.send_after(self(), {:stage_timeout, token, :ingress}, remaining(deadline)),
        phase: :ingress,
        lease: lease,
        prepared: nil
      }

      config = owned_config(state.config)

      task =
        Task.Supervisor.async_nolink(Tasks, fn ->
          prepare_media(config.runtime, lease, length, deadline)
        end)

      {:noreply, %{state | stage: stage, task: {task, from, :prepare}}}
    else
      _ -> {:reply, {:error, :storage_preparation_refused}, state}
    end
  end

  def handle_call(
        {:finish_media, token, sha},
        {owner, _} = from,
        %{stage: %{token: token, owner: owner} = stage, task: nil} = state
      ) do
    if stage.prepared && sha == stage.prepared["object_sha256"] && remaining(stage.deadline) > 0 do
      Process.cancel_timer(stage.timer)
      # Provider I/O still uses the original deadline. Only the two bounded
      # evidence callbacks may finish afterward, including a late receipt.
      stage = %{
        stage
        | phase: :evidence,
          timer: Process.send_after(self(), {:stage_timeout, token, :evidence}, remaining(stage.deadline) + 2100)
      }

      config = owned_config(state.config)

      task =
        Task.Supervisor.async_nolink(Tasks, fn ->
          Upload.run_media(config, state.boot, stage.lease, stage.prepared, stage.path, stage.deadline)
        end)

      {:noreply, %{state | stage: stage, task: {task, from, :upload}}}
    else
      {:reply, {:error, :storage_staging_refused}, clear_stage(state)}
    end
  end

  def handle_call({:finish_media, _, _}, _from, state), do: {:reply, {:error, :storage_staging_refused}, state}

  def handle_call({:release_media, token}, {owner, _}, %{stage: %{token: token, owner: owner}} = state),
    do: {:reply, :ok, cancel_operation(state)}

  def handle_call({:release_media, _}, _from, state), do: {:reply, :ok, state}

  def handle_call(
        {:http_socket_owner, task_pid, socket_pid},
        {task_pid, _},
        %{task: {%Task{pid: task_pid}, _, _}} = state
      ) do
    state = clear_dead_socket(state)

    if state.socket == nil do
      {:reply, :ok, %{state | socket: %{pid: socket_pid, monitor: Process.monitor(socket_pid)}}}
    else
      {:reply, {:error, :socket_owner_busy}, state}
    end
  end

  def handle_call({:http_socket_owner, _, _}, _from, state), do: {:reply, {:error, :request_cancelled}, state}

  @impl true
  def handle_info({ref, {:ok, prepared}}, %{task: {%Task{ref: ref}, from, :prepare}} = state) do
    Process.demonitor(ref, [:flush])
    stage = %{state.stage | prepared: prepared}

    GenServer.reply(
      from,
      {:ok, stage |> Map.take([:path, :token, :deadline]) |> Map.put(:length, prepared["byte_length"])}
    )

    {:noreply, %{state | stage: stage, task: nil}}
  end

  def handle_info({ref, result}, %{task: {%Task{ref: ref}, from, _phase}} = state) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, result)
    {:noreply, state |> Map.put(:task, nil) |> stop_socket() |> clear_stage()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: {%Task{ref: ref}, from, _phase}} = state) do
    GenServer.reply(from, {:error, :storage_operation_failed})
    {:noreply, state |> Map.put(:task, nil) |> stop_socket() |> clear_stage()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stage: %{monitor: ref}} = state),
    do: {:noreply, cancel_operation(state)}

  def handle_info({:stage_timeout, token, phase}, %{stage: %{token: token, phase: phase}} = state) do
    stop_ingress(state)
    {:noreply, cancel_operation(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{socket: %{monitor: ref}} = state),
    do: {:noreply, %{state | socket: nil}}

  def handle_info(_, state), do: {:noreply, state}

  defp cancel_operation(%{task: {task, from, _phase}} = state) do
    Task.shutdown(task, :brutal_kill)
    GenServer.reply(from, {:error, :storage_operation_failed})
    state |> Map.put(:task, nil) |> stop_socket() |> clear_stage()
  end

  defp cancel_operation(state), do: state |> stop_socket() |> clear_stage()

  defp stop_ingress(%{stage: nil}), do: :ok

  defp stop_ingress(%{stage: %{owner: owner}}) do
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^owner, _} -> :ok)
  end

  defp clear_stage(%{stage: nil} = state), do: state

  defp clear_stage(%{stage: stage} = state) do
    Process.cancel_timer(stage.timer)
    Process.demonitor(stage.monitor, [:flush])

    with :ok <- removed(File.rm(stage.path)), :ok <- removed(File.rmdir(stage.directory)) do
      %{state | stage: nil}
    else
      _ -> %{state | stage: Map.put(stage, :cleanup_failed, true)}
    end
  end

  defp removed(:ok), do: :ok
  defp removed({:error, :enoent}), do: :ok
  defp removed(error), do: error

  defp owned_config(config) do
    %{
      config
      | runtime: Map.put(config.runtime, :socket_owner, self()),
        provider: Map.put(config.provider, :socket_owner, self())
    }
  end

  defp clear_dead_socket(%{socket: nil} = state), do: state

  defp clear_dead_socket(%{socket: %{pid: pid, monitor: ref}} = state) do
    if Process.alive?(pid) do
      state
    else
      Process.demonitor(ref, [:flush])
      %{state | socket: nil}
    end
  end

  defp stop_socket(%{socket: nil} = state), do: state

  defp stop_socket(%{socket: %{pid: pid, monitor: ref}} = state) do
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    %{state | socket: nil}
  end

  defp staging_root(:init), do: {:ok, nil}
  defp staging_root(:media), do: create_private_directory(Path.join(System.tmp_dir!(), "vms-media-staging"))

  defp scratch_directory(root), do: create_private_directory(Path.join(root, Ecto.UUID.generate()))

  defp create_private_directory(directory) do
    with :ok <- File.mkdir(directory) do
      case File.chmod(directory, 0o700) do
        :ok ->
          {:ok, directory}

        error ->
          File.rmdir(directory)
          error
      end
    end
  end

  defp prepare_media(runtime, lease, length, deadline) do
    with {:ok, %{"schema_version" => 1, "dispatch_id" => id, "byte_length" => ^length, "object_sha256" => sha} = prepared}
         when map_size(prepared) == 4 <-
           CoreClient.request(runtime, :prepare, %{"schema_version" => 1, "lease" => lease}, remaining(deadline)),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
         true <- remaining(deadline) > 0 do
      {:ok, prepared}
    else
      _ -> {:error, :storage_preparation_refused}
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  @impl true
  def terminate(_reason, state) do
    stop_ingress(state)
    state = cancel_operation(state)
    if state.scratch_root && state.stage == nil, do: File.rmdir(state.scratch_root)
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted_storage_session)
end
