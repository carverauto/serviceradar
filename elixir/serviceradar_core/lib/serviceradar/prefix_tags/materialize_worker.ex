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

      alias ServiceRadar.PrefixTags.ObanSchedule

      require Logger

      @source_name unquote(source)
      @reload_mod unquote(reload_mod)
      @default_reschedule_seconds unquote(reschedule)
      @default_failure_reschedule_seconds unquote(failure_reschedule)

      @spec ensure_scheduled() ::
              {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
      def ensure_scheduled, do: ObanSchedule.ensure_scheduled(__MODULE__)

      @impl Oban.Worker
      def perform(_job) do
        if ObanSchedule.scheduler_node?() do
          do_perform()
        else
          :ok
        end
      end

      defp do_perform do
        config = Application.get_env(:serviceradar_core, __MODULE__, [])
        started = System.monotonic_time(:microsecond)

        case @reload_mod.reload() do
          {:ok, %{row_count: count}} when is_integer(count) and count >= 0 ->
            duration_us = System.monotonic_time(:microsecond) - started
            emit(:ok, count, duration_us)

            ObanSchedule.schedule_next(
              __MODULE__,
              Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
            )

          {:error, reason} ->
            duration_us = System.monotonic_time(:microsecond) - started
            emit(:error, 0, duration_us)

            Logger.warning("Prefix-tag materialize failed",
              source: @source_name,
              reason: inspect(reason)
            )

            ObanSchedule.schedule_next(
              __MODULE__,
              Keyword.get(
                config,
                :failure_reschedule_seconds,
                @default_failure_reschedule_seconds
              )
            )
        end
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
