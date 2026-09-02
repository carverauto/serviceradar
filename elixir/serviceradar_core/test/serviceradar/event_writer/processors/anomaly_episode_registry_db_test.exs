defmodule ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistryDbTest do
  # Regression coverage for the real-Postgres upsert path: the registry's
  # $n::jsonb placeholder makes Postgrex encode the bound value, so passing a
  # pre-encoded binary stored `last_payload` as a JSONB string scalar that Ash
  # could not load as :map (crashing every AnomalyEpisode read). The pure
  # registry test stubs the repo and cannot catch parameter-encoding bugs.
  # Serial: the registry owns VM-wide named ETS tables
  # (`:serviceradar_anomaly_episode_rate_guard` and
  # `:serviceradar_anomaly_episode_tripwire`) and `setup_all` starts core.
  # Under `integration_tests_async` that collides with other cases and the
  # sandbox owner disappears (`DBConnection.OwnershipError` on `Repo.query!`).
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry
  alias ServiceRadar.Observability.AnomalyEpisode
  alias ServiceRadar.Repo

  require Ash.Query

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
    assert is_map(episode.last_payload["episode_registry"]["producer_states"])
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

  test "a folded producer clear preserves another producer's open episode state" do
    series = "sysmon:cpu:sr:episode-fold-#{System.unique_integer([:positive])}"

    assert AnomalyEpisodeRegistry.transition_rows(
             [anomaly_row(series, "anomaly_open", agent_id: "agent-a", severity_id: 4)],
             Repo
           )

    assert AnomalyEpisodeRegistry.transition_rows(
             [anomaly_row(series, "anomaly_open", agent_id: "agent-b", severity_id: 3)],
             Repo
           )

    assert AnomalyEpisodeRegistry.transition_rows(
             [
               anomaly_row(series, "anomaly_clear",
                 agent_id: "agent-a",
                 severity_id: 2,
                 verdict_source: "edge-spike"
               )
             ],
             Repo
           )

    %{rows: [[status, severity_id, detector, payload]]} =
      Repo.query!(
        """
        SELECT status, severity_id, detector, last_payload
        FROM platform.anomaly_episodes
        WHERE series_key = $1
        """,
        [series]
      )

    assert status == "open"
    assert severity_id == 3
    assert detector == "drift"

    assert get_in(payload, ["episode_registry", "producer_states", "agent-a", "status"]) ==
             "cleared"

    assert get_in(payload, ["episode_registry", "producer_states", "agent-b", "status"]) == "open"
  end

  test "an exact flap reopen folds into an already-open producer episode" do
    series = "sysmon:cpu:sr:episode-flap-#{System.unique_integer([:positive])}"
    finding_uid = "finding-flap-#{System.unique_integer([:positive])}"
    started_at = ~U[2026-07-13 05:00:00Z]
    episode_a = Ecto.UUID.generate()
    episode_b = Ecto.UUID.generate()

    assert AnomalyEpisodeRegistry.transition_rows(
             [
               anomaly_row(series, "anomaly_open",
                 agent_id: "agent-a",
                 finding_uid: finding_uid,
                 episode_uid: episode_a,
                 at: started_at
               )
             ],
             Repo
           )

    assert AnomalyEpisodeRegistry.transition_rows(
             [
               anomaly_row(series, "anomaly_clear",
                 agent_id: "agent-a",
                 finding_uid: finding_uid,
                 episode_uid: episode_a,
                 at: DateTime.add(started_at, 1, :second)
               )
             ],
             Repo
           )

    # The registry's 300s fold window has elapsed, so a second producer opens
    # a separate canonical row. The edge's 600s reopen window still reuses A's
    # episode uid for its flap update.
    assert AnomalyEpisodeRegistry.transition_rows(
             [
               anomaly_row(series, "anomaly_open",
                 agent_id: "agent-b",
                 finding_uid: finding_uid,
                 episode_uid: episode_b,
                 at: DateTime.add(started_at, 302, :second)
               )
             ],
             Repo
           )

    assert AnomalyEpisodeRegistry.transition_rows(
             [
               anomaly_row(series, "anomaly_update",
                 agent_id: "agent-a",
                 finding_uid: finding_uid,
                 episode_uid: episode_a,
                 at: DateTime.add(started_at, 500, :second)
               )
             ],
             Repo
           )

    %{rows: [[open_count, episode_states]]} =
      Repo.query!(
        """
        SELECT
          count(*) FILTER (WHERE status = 'open'),
          array_agg(episode_uid || ':' || status ORDER BY episode_uid)
        FROM platform.anomaly_episodes
        WHERE series_key = $1
        """,
        [series]
      )

    assert open_count == 1, "expected one open canonical episode, got #{inspect(episode_states)}"

    %{rows: [[open_episode_uid]]} =
      Repo.query!(
        "SELECT episode_uid FROM platform.anomaly_episodes WHERE series_key = $1 AND status = 'open'",
        [series]
      )

    assert open_episode_uid == episode_b
  end

  test "stale producer states are pruned even when the canonical episode remains open" do
    series = "sysmon:cpu:sr:episode-prune-#{System.unique_integer([:positive])}"
    started_at = ~U[2026-07-13 05:00:00Z]

    assert AnomalyEpisodeRegistry.transition_rows(
             [anomaly_row(series, "anomaly_open", agent_id: "agent-a", at: started_at)],
             Repo
           )

    # An open canonical row is intentionally reused, but its stale producer
    # contributor must not keep the aggregate artificially open forever.
    assert AnomalyEpisodeRegistry.transition_rows(
             [
               anomaly_row(series, "anomaly_open",
                 agent_id: "agent-b",
                 at: DateTime.add(started_at, 901, :second)
               )
             ],
             Repo
           )

    %{rows: [[payload]]} =
      Repo.query!(
        "SELECT last_payload FROM platform.anomaly_episodes WHERE series_key = $1",
        [series]
      )

    producer_states = get_in(payload, ["episode_registry", "producer_states"])
    assert Map.keys(producer_states) == ["agent-b"]
    assert get_in(producer_states, ["agent-b", "status"]) == "open"
  end

  test "a legacy scalar payload is repaired before the producer-state merge" do
    series = "sysmon:cpu:sr:episode-scalar-#{System.unique_integer([:positive])}"

    assert AnomalyEpisodeRegistry.transition_rows([anomaly_row(series, "anomaly_open")], Repo)

    Repo.query!(
      "UPDATE platform.anomaly_episodes SET last_payload = '\"legacy scalar\"'::jsonb WHERE series_key = $1",
      [series]
    )

    assert AnomalyEpisodeRegistry.transition_rows([anomaly_row(series, "anomaly_update")], Repo)

    %{rows: [[typeof]]} =
      Repo.query!(
        "SELECT jsonb_typeof(last_payload) FROM platform.anomaly_episodes WHERE series_key = $1",
        [series]
      )

    assert typeof == "object"
  end

  defp anomaly_row(series, state, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    severity_id = Keyword.get(opts, :severity_id, 4)
    verdict_source = Keyword.get(opts, :verdict_source, "edge-drift")
    finding_uid = Keyword.get(opts, :finding_uid, "finding:#{series}")
    episode_uid = Keyword.get(opts, :episode_uid)
    at = Keyword.get(opts, :at, ~U[2026-07-13 05:00:00Z])

    payload = %{
      "event_id" => "episode-db-#{state}-#{System.unique_integer([:positive])}",
      "signal_type" => "prediction",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "timestamp" => DateTime.to_iso8601(at),
      "finding_uid" => finding_uid,
      "severity_id" => severity_id,
      "device_uid" => "sr:episode-db-device",
      "verdict_source" => verdict_source,
      "producer_version" => "0.2.0",
      "anomaly" => %{
        "series_key" => series,
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "state" => state,
        "score" => 4.5,
        "episode_started_at_unix_nano" => DateTime.to_unix(at, :nanosecond)
      }
    }

    payload =
      if is_binary(episode_uid), do: Map.put(payload, "episode_uid", episode_uid), else: payload

    payload =
      if is_binary(agent_id) do
        Map.put(payload, "source_identity", %{"agent_id" => agent_id})
      else
        payload
      end

    AnalyticsSignals.parse_message(%{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.predictions.#{series}",
        received_at: ~U[2026-07-13 05:00:00Z]
      }
    })
  end
end
