defmodule ServiceRadarAgentGateway.FileTransferLimiter do
  @moduledoc """
  Counting semaphore that bounds concurrent file uploads and downloads.

  Prevents a burst of simultaneous transfers from exhausting memory
  (temp files + in-flight data) and starving other gateway operations.

  Configuration via environment variables:
  - `GATEWAY_MAX_CONCURRENT_UPLOADS` — default 4
  - `GATEWAY_MAX_CONCURRENT_DOWNLOADS` — default 4
  """

  use GenServer

  @default_max_uploads 4
  @default_max_downloads 4

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec acquire(:upload | :download) :: :ok | {:error, :too_many_transfers}
  def acquire(type) when type in [:upload, :download] do
    GenServer.call(__MODULE__, {:acquire, type})
  end

  @spec release(:upload | :download) :: :ok
  def release(type) when type in [:upload, :download] do
    GenServer.call(__MODULE__, {:release, type})
  end

  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    max_uploads = env_int("GATEWAY_MAX_CONCURRENT_UPLOADS", @default_max_uploads)
    max_downloads = env_int("GATEWAY_MAX_CONCURRENT_DOWNLOADS", @default_max_downloads)

    {:ok,
     %{
       uploads: 0,
       downloads: 0,
       max_uploads: max_uploads,
       max_downloads: max_downloads
     }}
  end

  @impl true
  def handle_call({:acquire, :upload}, _from, state) do
    if state.uploads < state.max_uploads do
      :telemetry.execute(
        [:serviceradar, :agent_gateway, :file_transfer, :acquired],
        %{count: state.uploads + 1},
        %{type: :upload}
      )

      {:reply, :ok, %{state | uploads: state.uploads + 1}}
    else
      :telemetry.execute(
        [:serviceradar, :agent_gateway, :file_transfer, :rejected],
        %{count: state.uploads},
        %{type: :upload}
      )

      {:reply, {:error, :too_many_transfers}, state}
    end
  end

  def handle_call({:acquire, :download}, _from, state) do
    if state.downloads < state.max_downloads do
      :telemetry.execute(
        [:serviceradar, :agent_gateway, :file_transfer, :acquired],
        %{count: state.downloads + 1},
        %{type: :download}
      )

      {:reply, :ok, %{state | downloads: state.downloads + 1}}
    else
      :telemetry.execute(
        [:serviceradar, :agent_gateway, :file_transfer, :rejected],
        %{count: state.downloads},
        %{type: :download}
      )

      {:reply, {:error, :too_many_transfers}, state}
    end
  end

  def handle_call({:release, :upload}, _from, state) do
    new_count = max(state.uploads - 1, 0)

    :telemetry.execute(
      [:serviceradar, :agent_gateway, :file_transfer, :released],
      %{count: new_count},
      %{type: :upload}
    )

    {:reply, :ok, %{state | uploads: new_count}}
  end

  def handle_call({:release, :download}, _from, state) do
    new_count = max(state.downloads - 1, 0)

    :telemetry.execute(
      [:serviceradar, :agent_gateway, :file_transfer, :released],
      %{count: new_count},
      %{type: :download}
    )

    {:reply, :ok, %{state | downloads: new_count}}
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  defp env_int(var, default) do
    case System.get_env(var) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end
end
