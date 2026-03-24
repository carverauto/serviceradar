defmodule ServiceRadar.ObanEnsureScheduled do
  @moduledoc false

  defmacro __using__(opts) do
    workers = Keyword.fetch!(opts, :workers)
    label = Keyword.fetch!(opts, :label)
    tick = Keyword.get(opts, :tick, :ensure_jobs)
    interval_ms = Keyword.get(opts, :interval_ms, 60_000)
    named_start? = Keyword.get(opts, :named_start?, false)
    include_worker? = Keyword.get(opts, :include_worker?, length(workers) > 1)

    quote bind_quoted: [
            workers: workers,
            label: label,
            tick: tick,
            interval_ms: interval_ms,
            named_start?: named_start?,
            include_worker?: include_worker?
          ] do
      use GenServer

      alias ServiceRadar.Repo
      alias ServiceRadar.SweepJobs.ObanSupport

      require Logger

      @scheduled_workers workers
      @schedule_label label
      @schedule_tick tick
      @schedule_interval_ms interval_ms
      @schedule_named_start named_start?
      @include_worker_metadata include_worker?

      if @schedule_named_start do
        def start_link(opts \\ []) do
          GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
        end
      else
        def start_link(opts \\ []) do
          GenServer.start_link(__MODULE__, %{}, opts)
        end
      end

      @impl GenServer
      def init(state) do
        send(self(), @schedule_tick)
        {:ok, state}
      end

      @impl GenServer
      def handle_info(@schedule_tick, state) do
        Enum.each(@scheduled_workers, &ensure_scheduled/1)

        Process.send_after(self(), @schedule_tick, @schedule_interval_ms)
        {:noreply, state}
      end

      defp ensure_scheduled(worker) do
        if oban_jobs_ready?() do
          case worker.ensure_scheduled() do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.debug(
                @schedule_label <> " skipped",
                log_metadata(worker, reason: inspect(reason))
              )
          end
        else
          Logger.debug(
            @schedule_label <> " skipped; Oban tables not ready",
            log_metadata(worker, [])
          )

          :ok
        end
      end

      if @include_worker_metadata do
        defp log_metadata(worker, metadata) do
          Keyword.put(metadata, :worker, inspect(worker))
        end
      else
        defp log_metadata(_worker, metadata) do
          metadata
        end
      end

      defp oban_jobs_ready? do
        if ObanSupport.available?() do
          prefix = ObanSupport.prefix()

          case Ecto.Adapters.SQL.query(Repo, "SELECT to_regclass($1)", ["#{prefix}.oban_jobs"]) do
            {:ok, %{rows: [[nil]]}} -> false
            {:ok, _} -> true
            {:error, _} -> false
          end
        else
          false
        end
      rescue
        _ -> false
      end
    end
  end
end
