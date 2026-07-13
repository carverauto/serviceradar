defmodule ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistryDbTest do
  # Regression coverage for the real-Postgres upsert path: the registry's
  # $n::jsonb placeholder makes Postgrex encode the bound value, so passing a
  # pre-encoded binary stored `last_payload` as a JSONB string scalar that Ash
  # could not load as :map (crashing every AnomalyEpisode read). The pure
  # registry test stubs the repo and cannot catch parameter-encoding bugs.
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry
  alias ServiceRadar.Observability.AnomalyEpisode
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "upsert stores last_payload as a jsonb object that Ash can read back" do
    series = "sysmon:cpu:sr:episode-db-#{System.unique_integer([:positive])}"
    row = anomaly_row(series, "anomaly_open")

    assert [_emitted] = AnomalyEpisodeRegistry.transition_rows([row], Repo)

    %{rows: [[typeof]]} =
      Repo.query!(
        "SELECT jsonb_typeof(last_payload) FROM platform.anomaly_episodes WHERE series_key = $1",
        [series]
      )

    assert typeof == "object"

    episode =
      AnomalyEpisode
      |> Ash.Query.filter(series_key == ^series)
      |> Ash.read_one!(actor: SystemActor.system(:anomaly_episode_registry_db_test))

    assert is_map(episode.last_payload)
    assert episode.last_payload["anomaly"]["series_key"] == series
    assert episode.status == "open"

    # Re-delivery updates in place without corrupting the payload shape.
    assert AnomalyEpisodeRegistry.transition_rows([anomaly_row(series, "anomaly_open")], Repo)

    %{rows: [[typeof_after]]} =
      Repo.query!(
        "SELECT jsonb_typeof(last_payload) FROM platform.anomaly_episodes WHERE series_key = $1",
        [series]
      )

    assert typeof_after == "object"
  end

  defp anomaly_row(series, state) do
    payload = %{
      "event_id" => "episode-db-#{state}-#{System.unique_integer([:positive])}",
      "signal_type" => "prediction",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "timestamp" => "2026-07-13T05:00:00Z",
      "severity_id" => 4,
      "device_uid" => "sr:episode-db-device",
      "verdict_source" => "edge-spike",
      "producer_version" => "0.2.0",
      "anomaly" => %{
        "series_key" => series,
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "state" => state,
        "score" => 4.5,
        "episode_started_at_unix_nano" => 1_812_456_000_000_000_000
      }
    }

    AnalyticsSignals.parse_message(%{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.predictions.#{series}",
        received_at: ~U[2026-07-13 05:00:00Z]
      }
    })
  end
end
