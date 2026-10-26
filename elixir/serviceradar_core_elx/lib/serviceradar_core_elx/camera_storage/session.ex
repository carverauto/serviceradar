defmodule ServiceRadarCoreElx.CameraStorage.Session do
  @moduledoc false
  use GenServer

  alias ServiceRadar.Camera.ArchiveAuthorityConfig
  alias ServiceRadarCoreElx.CameraStorage.CoreClient
  alias ServiceRadarCoreElx.CameraStorage.Tasks
  alias ServiceRadarCoreElx.CameraStorage.Upload

  @challenge_fields ~w(schema_version binding_id revision desired_sha256 state storage_boot_id nonce issued_at_ms expires_at_ms remaining_ms applied_revision recording_readiness archive_readiness reason)

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def reserve(:init, deadline), do: call({:reserve, :init, nil, nil, deadline}, 20_000)

  def reserve(kind, lease, length, deadline) when kind in [:media, :manifest],
    do: call({:reserve, kind, lease, length, deadline}, 32_000)

  def upload_init(token, lease, bytes), do: call({:upload_init, token, lease, bytes}, 12_000)
  def finish(token, sha), do: call({:finish, token, sha}, 33_000)
  def release(token), do: call({:release, token}, 5_000)

  defp call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ -> {:error, :storage_operation_failed}
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    case staging_root(config.purposes) do
      {:ok, scratch_root} ->
        state = %{
          config: config,
          boot: Ecto.UUID.generate(),
          windows: %{},
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
    windows =
      Map.new(state.config.purposes, fn {kind, desired} ->
        {kind, challenge(kind, desired, state.config.runtime, state.boot)}
      end)

    {:noreply, %{state | windows: windows}}
  end

  defp challenge(kind, desired, runtime, boot) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    request = %{
      "schema_version" => 1,
      "revision" => Integer.to_string(desired.revision),
      "binding_id" => desired.binding_id,
      "desired_sha256" => desired.desired_sha256,
      "storage_boot_id" => boot,
      "nonce" => nonce
    }

    started = System.monotonic_time(:millisecond)

    deadline =
      with {:ok, result} <- CoreClient.request(runtime, kind, :challenge, request, 5_000),
           true <- Enum.sort(Map.keys(result)) == Enum.sort(@challenge_fields),
           true <- Enum.all?(request, fn {key, value} -> result[key] === value end),
           true <- result["state"] in ["pending", "applied"],
           remaining when is_integer(remaining) and remaining in 1..30_000 <- result["remaining_ms"] do
        started + remaining
      else
        _ -> nil
      end

    %{nonce: nonce, deadline: deadline}
  end

  @impl true
  def handle_call({:reserve, _, _, _, _}, _from, %{stage: %{cleanup_failed: true}} = state),
    do: {:reply, {:error, :storage_scratch_reconciliation_required}, state}

  def handle_call({:reserve, _, _, _, _}, _from, %{stage: stage} = state) when not is_nil(stage),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:reserve, _, _, _, _}, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:reserve, kind, lease, length, ingress_deadline}, {owner, _} = from, state) do
    case admit(state, kind, lease, length, ingress_deadline, owner) do
      {:ok, stage} when kind == :init ->
        {:reply, {:ok, Map.take(stage, [:token, :deadline])}, %{state | stage: stage}}

      {:ok, stage} ->
        config = owned_config(state.config, kind)

        task =
          Task.Supervisor.async_nolink(Tasks, fn ->
            prepare(kind, config.runtime, lease, length, stage.deadline)
          end)

        {:noreply, %{state | stage: stage, task: {task, from, :prepare}}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:upload_init, token, lease, bytes},
        {owner, _} = from,
        %{stage: %{kind: :init, token: token, owner: owner, phase: :ingress} = stage, task: nil} = state
      ) do
    if remaining(stage.deadline) > 0 do
      stage = phase(stage, :evidence)
      config = owned_config(state.config, :init)

      task =
        Task.Supervisor.async_nolink(Tasks, fn ->
          Upload.run_init(config, state.boot, lease, bytes, stage.deadline)
        end)

      {:noreply, %{state | stage: stage, task: {task, from, :upload}}}
    else
      {:reply, {:error, :storage_authority_unavailable}, clear_stage(state)}
    end
  end

  def handle_call({:upload_init, _, _, _}, _from, state), do: {:reply, {:error, :storage_authority_unavailable}, state}

  def handle_call(
        {:finish, token, sha},
        {owner, _} = from,
        %{stage: %{kind: kind, token: token, owner: owner, phase: :ingress} = stage, task: nil} = state
      )
      when kind in [:media, :manifest] do
    if stage.prepared && sha == stage.prepared["object_sha256"] && remaining(stage.deadline) > 0 do
      # Provider I/O still uses the original deadline. Only the two bounded
      # evidence callbacks may finish afterward, including a late receipt.
      stage = phase(stage, :evidence)
      config = owned_config(state.config, kind)

      task =
        Task.Supervisor.async_nolink(Tasks, fn ->
          Upload.run_staged(kind, config, state.boot, stage.lease, stage.prepared, stage.path, stage.deadline)
        end)

      {:noreply, %{state | stage: stage, task: {task, from, :upload}}}
    else
      {:reply, {:error, :storage_staging_refused}, clear_stage(state)}
    end
  end

  def handle_call({:finish, _, _}, _from, state), do: {:reply, {:error, :storage_staging_refused}, state}

  def handle_call({:release, token}, {owner, _}, %{stage: %{token: token, owner: owner}} = state),
    do: {:reply, :ok, cancel_operation(state)}

  def handle_call({:release, _}, _from, state), do: {:reply, :ok, state}

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
  defp clear_stage(%{stage: %{cleanup_failed: true}} = state), do: state

  defp clear_stage(%{stage: stage} = state) do
    case remove_scratch(stage) do
      :ok ->
        if Process.alive?(stage.owner) do
          # Returning a result does not end the one-shot ingress process. Keep its
          # slot until DOWN, including a suspended owner holding its response.
          %{state | stage: phase(stage, :closing)}
        else
          Process.cancel_timer(stage.timer)
          Process.demonitor(stage.monitor, [:flush])
          %{state | stage: nil}
        end

      _ ->
        %{state | stage: Map.put(stage, :cleanup_failed, true)}
    end
  end

  defp remove_scratch(%{path: nil}), do: :ok

  defp remove_scratch(stage) do
    with :ok <- removed(File.rm(stage.path)), do: removed(File.rmdir(stage.directory))
  end

  defp removed(:ok), do: :ok
  defp removed({:error, :enoent}), do: :ok
  defp removed(error), do: error

  defp owned_config(config, kind) do
    %{
      desired: Map.fetch!(config.purposes, kind),
      runtime: Map.put(config.runtime, :socket_owner, self()),
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

  defp staging_root(purposes) do
    if Map.has_key?(purposes, :media) or Map.has_key?(purposes, :manifest) do
      # Retain the existing exclusive root so changing installed purposes cannot
      # bypass a previous media operation's abandoned staging budget.
      create_private_directory(Path.join(System.tmp_dir!(), "vms-media-staging"))
    else
      {:ok, nil}
    end
  end

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

  defp prepare(kind, runtime, lease, length, deadline) do
    with {:ok, %{"schema_version" => 1, "dispatch_id" => id, "byte_length" => ^length, "object_sha256" => sha} = prepared}
         when map_size(prepared) == 4 <-
           CoreClient.request(runtime, kind, :prepare, %{"schema_version" => 1, "lease" => lease}, remaining(deadline)),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
         true <- remaining(deadline) > 0 do
      {:ok, prepared}
    else
      _ -> {:error, :storage_preparation_refused}
    end
  end

  defp admit(state, kind, lease, length, ingress_deadline, owner) do
    with {:ok, desired} <- Map.fetch(state.config.purposes, kind),
         %{deadline: authority_deadline} when is_integer(authority_deadline) <- Map.get(state.windows, kind),
         true <- valid_length?(kind, length, desired),
         deadline =
           Enum.min([
             ingress_deadline,
             authority_deadline,
             System.monotonic_time(:millisecond) + desired.limits["max_operation_ms"]
           ]),
         true <- remaining(deadline) > 0,
         {:ok, directory, path} <- scratch(state.scratch_root, kind) do
      stage = %{
        kind: kind,
        owner: owner,
        monitor: Process.monitor(owner),
        token: make_ref(),
        directory: directory,
        path: path,
        deadline: deadline,
        timer: nil,
        phase: :ingress,
        lease: lease,
        prepared: nil
      }

      {:ok, phase(stage, :ingress)}
    else
      _ -> {:error, if(kind == :init, do: :storage_authority_unavailable, else: :storage_preparation_refused)}
    end
  end

  defp valid_length?(:init, nil, _desired), do: true

  defp valid_length?(kind, length, desired),
    do: is_integer(length) and length in 1..ArchiveAuthorityConfig.byte_limit(kind, desired.limits)

  defp scratch(_root, :init), do: {:ok, nil, nil}

  defp scratch(root, kind) do
    with {:ok, directory} <- scratch_directory(root) do
      filename = if kind == :media, do: "media.m4s", else: "manifest.json"
      {:ok, directory, Path.join(directory, filename)}
    end
  end

  defp phase(stage, phase) do
    if stage.timer, do: Process.cancel_timer(stage.timer)
    deadline = stage.deadline + if(phase == :ingress, do: 0, else: 2100)
    timer = Process.send_after(self(), {:stage_timeout, stage.token, phase}, remaining(deadline))
    %{stage | timer: timer, phase: phase}
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
