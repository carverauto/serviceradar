defmodule ServiceRadarCoreElx.CameraStorage.Session do
  @moduledoc false
  use GenServer

  alias ServiceRadarCoreElx.CameraStorage.CoreClient
  alias ServiceRadarCoreElx.CameraStorage.Upload

  @challenge_fields ~w(schema_version binding_id revision desired_sha256 state storage_boot_id nonce issued_at_ms expires_at_ms remaining_ms applied_revision recording_readiness archive_readiness reason)

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def upload(lease, bytes, deadline), do: GenServer.call(__MODULE__, {:upload, lease, bytes, deadline}, 12_000)

  @impl true
  def init(config) do
    state = %{
      config: config,
      boot: Ecto.UUID.generate(),
      nonce: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      deadline: nil,
      task: nil
    }

    {:ok, state, {:continue, :challenge}}
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
  def handle_call({:upload, _lease, _bytes, _deadline}, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:upload, lease, bytes, deadline}, from, state) do
    if state.deadline && System.monotonic_time(:millisecond) < state.deadline do
      task =
        Task.Supervisor.async_nolink(ServiceRadarCoreElx.CameraStorage.Tasks, fn ->
          Upload.run(state.config, state.boot, state.deadline, lease, bytes, deadline)
        end)

      {:noreply, %{state | task: {task, from}}}
    else
      {:reply, {:error, :storage_authority_unavailable}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: {%Task{ref: ref}, from}} = state) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, result)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: {%Task{ref: ref}, from}} = state) do
    GenServer.reply(from, {:error, :storage_operation_failed})
    {:noreply, %{state | task: nil}}
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted_storage_session)
end
