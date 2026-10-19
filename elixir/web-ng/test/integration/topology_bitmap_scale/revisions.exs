defmodule ServiceRadarWebNG.Topology.Scale.Revisions do
  @moduledoc false
  # Records, on the driver's clock, when one replica published each index
  # revision. A viewer is then judged against what its replica had actually
  # published: an unhinted replica legitimately publishes nothing between
  # reconciliation passes, and a current viewer is not stalled. Currency is
  # only as recent as the last successful read; failed reads are counted.
  use GenServer

  @interval 250

  def start_link(read) when is_function(read, 0), do: GenServer.start_link(__MODULE__, read)
  def table(pid), do: GenServer.call(pid, :table)

  @impl true
  def init(read) do
    table = :ets.new(__MODULE__, [:ordered_set, :public, read_concurrency: true])
    send(self(), :sample)
    {:ok, %{read: read, table: table}}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  @impl true
  def handle_info(:sample, state) do
    started = now()

    case read(state.read) do
      {:ok, {epoch, revision}} -> observe(state.table, epoch, revision, started)
      _ -> :ets.update_counter(state.table, :failures, 1, {:failures, 0})
    end

    Process.send_after(self(), :sample, @interval)
    {:noreply, state}
  end

  @doc """
  Records one successful read that started at `started`. A new revision is
  dated from the start of the previous successful read, the earliest moment it
  could have appeared, so sampling never shortens a measured lag.
  """
  def observe(table, epoch, revision, started) do
    order =
      case :ets.lookup(table, {:epoch, epoch}) do
        [{_, order}] ->
          order

        [] ->
          order = :ets.update_counter(table, :epochs, 1, {:epochs, 0})
          :ets.insert(table, {{:epoch, epoch}, order})
          order
      end

    since =
      case :ets.lookup(table, :last_read) do
        [{_, previous}] -> previous
        [] -> started
      end

    :ets.insert_new(table, {{:revision, order, revision}, since})
    :ets.insert(table, {:last_read, started})
    :ok
  end

  @doc """
  What the observations establish about a viewer holding `{epoch, revision}`:
  `{:behind, since}` once the replica published anything newer (later epochs
  are newer), `{:current, read_at}` when the latest successful read, started at
  `read_at`, found nothing newer, or `:unobserved` when no successful read has
  seen that epoch.
  """
  def freshness(table, epoch, revision) do
    case :ets.lookup(table, {:epoch, epoch}) do
      [] ->
        :unobserved

      [{_, order}] ->
        case :ets.next(table, {:revision, order, revision}) do
          {:revision, _, _} = next -> {:behind, :ets.lookup_element(table, next, 2)}
          _ -> {:current, :ets.lookup_element(table, :last_read, 2)}
        end
    end
  end

  @doc "Bounded numeric sampler health for a failure report."
  def coverage(table) do
    read_at =
      case :ets.lookup(table, :last_read) do
        [{_, started}] -> started
        [] -> nil
      end

    failures =
      case :ets.lookup(table, :failures) do
        [{_, count}] -> count
        [] -> 0
      end

    %{failures: failures, last_read_age_ms: read_at && now() - read_at}
  end

  defp read(read) do
    read.()
  catch
    _kind, _reason -> :error
  end

  defp now, do: System.monotonic_time(:millisecond)
end
