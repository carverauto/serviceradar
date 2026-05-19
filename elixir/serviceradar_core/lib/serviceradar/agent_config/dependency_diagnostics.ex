defmodule ServiceRadar.AgentConfig.DependencyDiagnostics do
  @moduledoc """
  In-memory diagnostics for recent catalog-driven agent config changes.

  This intentionally stores only redacted catalog diagnostics. Secret values are
  never accepted from callers; `DependencyCatalog.diagnostics/2` reduces
  sensitive fields to presence booleans before recording.
  """

  use GenServer

  @default_limit 100

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Records a redacted dependency diagnostic entry when the recorder is running."
  @spec record(map()) :: :ok
  def record(diagnostic) when is_map(diagnostic) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.call(pid, {:record, diagnostic})
    end

    :ok
  end

  @doc "Returns recent dependency diagnostics, newest first."
  @spec recent(pos_integer()) :: [map()]
  def recent(limit \\ @default_limit) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.call(pid, {:recent, limit})
    else
      []
    end
  end

  @doc "Clears recorded diagnostics. Intended for tests and operator reset flows."
  @spec clear() :: :ok
  def clear do
    if pid = Process.whereis(__MODULE__) do
      GenServer.call(pid, :clear)
    end

    :ok
  end

  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    {:ok, %{entries: [], limit: limit}}
  end

  @impl true
  def handle_call({:record, diagnostic}, _from, state) do
    entry =
      diagnostic
      |> Map.put_new_lazy(:recorded_at, &utc_now_second/0)
      |> normalize_recorded_at()

    entries = Enum.take([entry | state.entries], state.limit)
    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:recent, limit}, _from, state) do
    {:reply, Enum.take(state.entries, limit), state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: []}}
  end

  defp utc_now_second do
    DateTime.truncate(DateTime.utc_now(), :second)
  end

  defp normalize_recorded_at(%{recorded_at: %DateTime{} = recorded_at} = diagnostic) do
    %{diagnostic | recorded_at: DateTime.truncate(recorded_at, :second)}
  end

  defp normalize_recorded_at(diagnostic), do: diagnostic
end
