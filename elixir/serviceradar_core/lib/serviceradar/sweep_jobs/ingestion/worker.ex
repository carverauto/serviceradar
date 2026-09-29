defmodule ServiceRadar.SweepJobs.Ingestion.Worker do
  @moduledoc """
  Ingests sweep result chunks handed to it by the
  `ServiceRadar.SweepJobs.Ingestion.Dispatcher`.

  Each worker joins the sweep ingestion `:pg` group on start, processes its
  mailbox one chunk at a time, and acknowledges every chunk back to the
  dispatcher once it is finished, whatever the outcome. The dispatcher relies
  on that acknowledgement to know when a partition has nothing in flight and
  may move to another worker, so a chunk is always acknowledged, including
  when the processor raises.
  """

  use GenServer

  require Logger

  @done_event [:serviceradar, :sweep_ingestion, :chunk, :done]

  @type ingest_message ::
          {:sweep_ingest, dispatcher :: pid(), key :: term(), status :: map()}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :index, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)
    group = Keyword.fetch!(opts, :group)

    processor =
      Keyword.get(opts, :processor, {ServiceRadar.ResultsRouter, :process_sweep_status, []})

    :ok = :pg.join(scope, group, self())

    {:ok, %{processor: processor}}
  end

  @impl true
  def handle_info({:sweep_ingest, dispatcher, key, status}, state) do
    started_at = System.monotonic_time()
    outcome = run(state.processor, status)
    duration = System.monotonic_time() - started_at

    send(dispatcher, {:sweep_ingested, key, self()})

    :telemetry.execute(@done_event, %{duration: duration}, %{outcome: outcome, node: node()})

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run({module, function, args}, status) do
    case apply(module, function, [status | args]) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
      _other -> :ok
    end
  rescue
    exception ->
      Logger.warning("Sweep ingestion failed: #{Exception.message(exception)}",
        exception: inspect(exception.__struct__)
      )

      :exception
  catch
    kind, reason ->
      Logger.warning("Sweep ingestion failed: #{inspect({kind, reason})}")
      :exception
  end
end
