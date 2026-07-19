defmodule ServiceRadar.PrefixTags.MaterializeWorker do
  @moduledoc """
  Shared Oban scaffolding for high-cadence prefix-tag trie materializers
  (`ti`, `dns-policy`, …).

  Use:

      use ServiceRadar.PrefixTags.MaterializeWorker,
        source: "ti",
        reload: ServiceRadar.PrefixTags.ThreatIntelSource,
        reschedule_seconds: 300,
        failure_reschedule_seconds: 600
  """

  defmacro __using__(opts) do
    source = Keyword.fetch!(opts, :source)
    reload_mod = Keyword.fetch!(opts, :reload)
    reschedule = Keyword.get(opts, :reschedule_seconds, 5 * 60)
    failure_reschedule = Keyword.get(opts, :failure_reschedule_seconds, 10 * 60)

    quote do
      use Oban.Worker,
        queue: :maintenance,
        max_attempts: 3,
        unique: [period: :infinity, states: :incomplete]

      import Ecto.Query, only: [from: 2]

      alias ServiceRadar.Repo
      alias ServiceRadar.SweepJobs.ObanSupport

      require Logger

      @source_name unquote(source)
      @reload_mod unquote(reload_mod)
      @default_reschedule_seconds unquote(reschedule)
      @default_failure_reschedule_seconds unquote(failure_reschedule)
      @successor_unique [period: :infinity, states: [:available, :scheduled, :retryable]]

      @spec ensure_scheduled() ::
              {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
      def ensure_scheduled do
        if ObanSupport.available?() do
          if check_existing_job() do
            {:ok, :already_scheduled}
          else
            %{} |> new() |> ObanSupport.safe_insert()
          end
        else
          {:error, :oban_unavailable}
        end
      end

      defp check_existing_job do
        query =
          from(j in Oban.Job,
            where: j.worker == ^to_string(__MODULE__),
            where: j.state in ["available", "scheduled", "executing", "retryable"],
            limit: 1
          )

        Repo.exists?(query, prefix: ObanSupport.prefix())
      end

      @impl Oban.Worker
      def perform(_job) do
        if scheduler_node?() do
          do_perform()
        else
          :ok
        end
      end

      defp do_perform do
        config = Application.get_env(:serviceradar_core, __MODULE__, [])
        started = System.monotonic_time(:microsecond)

        case @reload_mod.reload() do
          {:ok, count} ->
            duration_us = System.monotonic_time(:microsecond) - started
            emit(:ok, count, duration_us)
            schedule_next(Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds))

          {:error, reason} ->
            duration_us = System.monotonic_time(:microsecond) - started
            emit(:error, 0, duration_us)

            Logger.warning("Prefix-tag materialize failed",
              source: @source_name,
              reason: inspect(reason)
            )

            schedule_next(
              Keyword.get(
                config,
                :failure_reschedule_seconds,
                @default_failure_reschedule_seconds
              )
            )
        end
      end

      defp schedule_next(seconds) when is_integer(seconds) do
        _ =
          %{}
          |> new(schedule_in: max(seconds, 60), unique: @successor_unique)
          |> ObanSupport.safe_insert()

        :ok
      end

      defp scheduler_node? do
        cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, false)

        cluster_coordinator =
          Application.get_env(:serviceradar_core, :cluster_coordinator, cluster_enabled)

        if cluster_enabled, do: cluster_coordinator == true, else: true
      end

      defp emit(outcome, count, duration_us) do
        :telemetry.execute(
          [:serviceradar, :prefix_tags, :import],
          %{duration_us: duration_us, record_count: count},
          %{outcome: outcome, source: @source_name}
        )
      end
    end
  end
end
