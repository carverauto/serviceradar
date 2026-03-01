defmodule ServiceRadar.Observability.LogPromotionTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL, as: SQL
  alias Postgrex.Result
  alias ServiceRadar.Observability.{EventRule, LogPromotion}
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    :ok
  end

  test "promotes log to event and creates alert" do
    actor = %{id: "system", role: :admin}

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "syslog-errors",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => "logs.syslog", "severity_text" => "ERROR"},
          event: %{"log_name" => "syslog.promoted"}
        },
        actor: actor
      )
      |> Ash.create()

    log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "ERROR",
      severity_number: 17,
      body: "Disk failure detected",
      service_name: "syslog",
      attributes: %{"serviceradar.ingest" => %{"subject" => "logs.syslog.processed"}},
      resource_attributes: %{},
      created_at: DateTime.utc_now()
    }

    assert {:ok, 1} = LogPromotion.promote([log])

    assert %Result{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM ocsf_events WHERE log_name = $1",
               ["syslog.promoted"]
             )

    assert %Result{rows: [[alert_count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM alerts WHERE event_id IS NOT NULL",
               []
             )

    assert alert_count > 0
  end

  test "matches event_type filter before promoting logs" do
    actor = %{id: "system", role: :admin}
    message = "event_type-match-#{Ash.UUID.generate()}"

    {:ok, _rule} =
      EventRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "event-type-match-#{Ash.UUID.generate()}",
          source_type: :log,
          source: %{},
          match: %{"subject_prefix" => "logs.test", "event_type" => "sweep.missed"},
          event: %{"message" => message, "log_name" => "test.event_type"}
        },
        actor: actor
      )
      |> Ash.create()

    baseline =
      SQL.query!(Repo, "SELECT COUNT(*) FROM ocsf_events WHERE message = $1", [message])
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    matching_log = %{
      id: Ash.UUID.generate(),
      timestamp: DateTime.utc_now(),
      severity_text: "INFO",
      severity_number: 11,
      body: "Sweep missed",
      service_name: "test",
      attributes: %{
        "event_type" => "sweep.missed",
        "serviceradar" => %{"ingest" => %{"subject" => "logs.test.processed"}}
      },
      resource_attributes: %{},
      created_at: DateTime.utc_now()
    }

    non_matching_log = %{
      matching_log
      | id: Ash.UUID.generate(),
        attributes: %{
          "event_type" => "sweep.ok",
          "serviceradar" => %{"ingest" => %{"subject" => "logs.test.processed"}}
        }
    }

    assert {:ok, 1} = LogPromotion.promote([matching_log])
    assert {:ok, 0} = LogPromotion.promote([non_matching_log])

    assert %Result{rows: [[count]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM ocsf_events WHERE message = $1",
               [message]
             )

    assert count == baseline + 1
  end
end
