defmodule ServiceRadar.Observability.SeasonalBaselineFreshnessWorker do
  @moduledoc """
  Tripwire for seasonal baseline delivery going stale (design D7).

  `SeasonalDisposition.EdgeBaselineProducer` records a
  `seasonal-baseline-producer` health-event heartbeat on every successful
  delivery run. If no healthy heartbeat landed within
  `:seasonal_baseline_freshness_hours` (default #{26} — a daily seasonal
  cycle plus margin over the hourly producer cron), baseline delivery is
  dead or silently failing (crashed cron, params rejected on write) and an
  unhealthy `:core` health event (`seasonal-baseline-freshness`) is recorded
  via `TripwireHealth`.

  No enabled anomaly profiles means there is nothing to deliver — skip, no
  signal. The producer's env gates are honored at schedule time:
  `ProductionSchedule` only schedules this worker while the edge-baseline
  cron itself is enabled, so disabling the producer silences the tripwire
  instead of tripping it forever. Profile/heartbeat load failures fail open
  (log, skip the run).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.HealthTracker
  alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer
  alias ServiceRadar.Observability.TripwireHealth
  alias ServiceRadar.Plugins.AddonProfile

  require Ash.Query
  require Logger

  @check_name "seasonal-baseline-freshness"
  @addon_id "anomaly"
  @default_freshness_hours 26

  @impl Oban.Worker
  def perform(_job), do: run()

  @doc """
  Evaluate the tripwire once.

  Injectables for tests: `:profiles_loader` (arity 1, receives the actor),
  `:heartbeat_loader` (arity 1, receives the freshness window in hours),
  `:health_recorder` (arity 3), and `:actor`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    health = Keyword.get(opts, :health_recorder, &TripwireHealth.record/3)
    actor = Keyword.get(opts, :actor, SystemActor.system(:seasonal_baseline_freshness))
    hours = freshness_hours()

    case load_profiles(opts, actor) do
      {:ok, []} ->
        :ok

      {:ok, _profiles} ->
        record_verdict(opts, hours, health)

      {:error, reason} ->
        skip_run(reason)
    end
  rescue
    error -> skip_run(error)
  end

  defp record_verdict(opts, hours, health) do
    case load_heartbeats(opts, hours) do
      {:ok, events} ->
        if Enum.any?(events, &healthy_heartbeat?/1) do
          health.(@check_name, true, %{})
        else
          Logger.error(
            "Seasonal baseline producer has not recorded a successful delivery " <>
              "heartbeat within #{hours}h"
          )

          health.(@check_name, false, %{"freshness_hours" => hours})
        end

        :ok

      {:error, reason} ->
        skip_run(reason)
    end
  end

  defp skip_run(reason) do
    Logger.warning(
      "Seasonal baseline freshness tripwire could not evaluate; " <>
        "skipping this run: " <> inspect(reason)
    )

    :ok
  end

  # The producer writes one `seasonal-baseline-producer` health event per
  # successful run, so "any healthy event inside the window" == "delivery ran
  # recently".
  defp load_heartbeats(opts, hours) do
    case Keyword.get(opts, :heartbeat_loader) do
      loader when is_function(loader, 1) ->
        loader.(hours)

      _ ->
        HealthTracker.timeline(:core, EdgeBaselineProducer.heartbeat_check_id(), hours: hours)
    end
  end

  @doc false
  @spec healthy_heartbeat?(map()) :: boolean()
  def healthy_heartbeat?(%{new_state: :healthy}), do: true
  def healthy_heartbeat?(_event), do: false

  defp load_profiles(opts, actor) do
    case Keyword.get(opts, :profiles_loader) do
      loader when is_function(loader, 1) ->
        loader.(actor)

      _ ->
        AddonProfile
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(addon_id == ^@addon_id and enabled == true)
        |> Ash.read(actor: actor)
    end
  end

  @doc "How fresh (hours) the newest producer delivery heartbeat must be."
  @spec freshness_hours() :: pos_integer()
  def freshness_hours do
    case Application.get_env(:serviceradar_core, :seasonal_baseline_freshness_hours) do
      hours when is_integer(hours) and hours > 0 -> hours
      _ -> @default_freshness_hours
    end
  end
end
