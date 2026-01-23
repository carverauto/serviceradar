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
end
