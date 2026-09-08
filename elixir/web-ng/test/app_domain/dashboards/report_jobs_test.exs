defmodule ServiceRadarWebNG.Dashboards.ReportJobsTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Swoosh.TestAssertions

  alias ServiceRadar.Dashboards.DashboardReportDelivery
  alias ServiceRadar.Dashboards.DashboardReportSchedule
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Dashboards.ReportDeliveryWorker
  alias ServiceRadarWebNG.Dashboards.ReportScannerWorker

  require Ash.Query

  defmodule ReportSRQLStub do
    @moduledoc false

    def query("services" <> _rest, _opts) do
      {:ok,
       %{
         "results" => [
           %{
             "service" => "core",
             "status" => "ok",
             "value" => 1,
             "observed_at" => ~U[2026-08-30 18:00:00Z]
           },
           %{
             "service" => "web-ng",
             "status" => "ok",
             "value" => 1,
             "observed_at" => ~U[2026-08-30 18:01:00Z]
           }
         ]
       }}
    end

    def query(_query, _opts), do: {:ok, %{"results" => []}}
  end

  setup do
    old_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, ReportSRQLStub)

    on_exit(fn ->
      if old_srql_module do
        Application.put_env(:serviceradar_web_ng, :srql_module, old_srql_module)
      else
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      end
    end)

    ensure_oban_started!()

    user = admin_user_fixture()

    user =
      Ash.update!(user, %{timezone: "America/Chicago"},
        action: :update_timezone_preference,
        actor: user
      )

    scope = Scope.for_user(user)

    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(scope, %{
        title: "Report Jobs #{System.unique_integer([:positive])}",
        status: :active
      })

    {:ok, _panel} =
      Dashboards.create_authored_panel(scope, %{
        dashboard_id: dashboard.id,
        title: "Service health",
        srql_query: "services status",
        visual_type: :table
      })

    {:ok, scope: scope, dashboard: dashboard}
  end

  test "scanner enqueues one delivery for each due enabled schedule", %{scope: scope, dashboard: dashboard} do
    due_at = DateTime.add(DateTime.utc_now(), -60, :second)
    schedule = schedule_fixture(scope, dashboard, next_due_at: due_at)

    assert :ok = ReportScannerWorker.perform(%Oban.Job{args: %{"enabled" => true, "limit" => 10}})

    assert [delivery] = deliveries_for_schedule(schedule.id)
    assert delivery.status == :pending
    assert DateTime.compare(delivery.due_at, due_at) == :eq
    assert delivery.recipients == ["noc@example.com"]

    schedule = get_schedule!(schedule.id)
    assert schedule.last_status == :queued
    assert DateTime.compare(schedule.last_due_at, due_at) == :eq
    assert DateTime.after?(schedule.next_due_at, due_at)
  end

  test "scanner ignores disabled due schedules", %{scope: scope, dashboard: dashboard} do
    schedule =
      schedule_fixture(scope, dashboard,
        enabled: false,
        next_due_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

    assert :ok = ReportScannerWorker.perform(%Oban.Job{args: %{"enabled" => true, "limit" => 10}})

    assert deliveries_for_schedule(schedule.id) == []
  end

  test "delivery creation is idempotent for a schedule due time", %{scope: scope, dashboard: dashboard} do
    due_at = DateTime.add(DateTime.utc_now(), -120, :second)
    schedule = schedule_fixture(scope, dashboard, next_due_at: due_at)

    attrs = %{
      schedule_id: schedule.id,
      dashboard_id: dashboard.id,
      due_at: due_at,
      status: :pending,
      recipients: ["noc@example.com"],
      recipient_count: 1,
      rendered_metadata: %{}
    }

    assert {:ok, first} =
             DashboardReportDelivery
             |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
             |> Ash.create(actor: system_actor())

    assert {:ok, second} =
             DashboardReportDelivery
             |> Ash.Changeset.for_create(:create, Map.put(attrs, :recipient_count, 2), actor: system_actor())
             |> Ash.create(actor: system_actor())

    assert first.id == second.id
    assert [delivery] = deliveries_for_schedule(schedule.id)
    assert delivery.recipient_count == 1
  end

  @tag :web_ng_shared_fixture_db
  test "delivery worker sends email and records success", %{scope: scope, dashboard: dashboard} do
    schedule = schedule_fixture(scope, dashboard, next_due_at: DateTime.add(DateTime.utc_now(), 3600, :second))
    delivery = delivery_fixture(schedule, dashboard, recipients: ["noc@example.com"])

    assert :ok = ReportDeliveryWorker.perform(%Oban.Job{args: %{"delivery_id" => delivery.id}})

    assert_email_sent(fn email ->
      assert email.to == [{"", "noc@example.com"}]
      assert email.subject == "ServiceRadar dashboard report: #{dashboard.title}"
      assert email.text_body =~ "2026-08-30T18:00:00Z"
      assert email.html_body =~ "2026-08-30T18:00:00Z"
    end)

    delivery = get_delivery!(delivery.id)
    assert delivery.status == :sent
    assert delivery.sent_at
    assert delivery.finished_at
    assert delivery.error == nil
    assert delivery.rendered_metadata["panel_count"] == 1
    assert delivery.rendered_metadata["row_count"] == 2

    schedule = get_schedule!(schedule.id)
    assert schedule.last_status == :sent
    assert schedule.last_delivered_at
    assert schedule.last_error == nil
  end

  test "delivery worker sanitizes email subject and caps rendered panels", %{scope: scope, dashboard: dashboard} do
    {:ok, dashboard} =
      Dashboards.update_authored_dashboard(scope, dashboard, %{
        title: "Report Jobs\r\nBcc: attacker@example.com"
      })

    Enum.each(1..24, fn index ->
      assert {:ok, _panel} =
               Dashboards.create_authored_panel(scope, %{
                 dashboard_id: dashboard.id,
                 title: "Extra panel #{index}",
                 srql_query: "services status",
                 visual_type: :table,
                 position: index
               })
    end)

    schedule = schedule_fixture(scope, dashboard, next_due_at: DateTime.add(DateTime.utc_now(), 3600, :second))
    delivery = delivery_fixture(schedule, dashboard, recipients: ["noc@example.com"])

    assert :ok = ReportDeliveryWorker.perform(%Oban.Job{args: %{"delivery_id" => delivery.id}})

    assert_email_sent(
      to: [{"", "noc@example.com"}],
      subject: "ServiceRadar dashboard report: Report Jobs Bcc: attacker@example.com"
    )

    delivery = get_delivery!(delivery.id)
    assert delivery.status == :sent
    assert delivery.rendered_metadata["panel_count"] == 20
    assert delivery.rendered_metadata["total_panel_count"] == 25
  end

  test "delivery worker records failures on delivery errors", %{scope: scope, dashboard: dashboard} do
    schedule = schedule_fixture(scope, dashboard, next_due_at: DateTime.add(DateTime.utc_now(), 3600, :second))
    delivery = delivery_fixture(schedule, dashboard, recipients: [])

    assert {:error, :no_recipients} = ReportDeliveryWorker.perform(%Oban.Job{args: %{"delivery_id" => delivery.id}})

    delivery = get_delivery!(delivery.id)
    assert delivery.status == :failed
    assert delivery.error == ":no_recipients"
    assert delivery.finished_at

    schedule = get_schedule!(schedule.id)
    assert schedule.last_status == :failed
    assert schedule.last_error == ":no_recipients"
  end

  defp schedule_fixture(scope, dashboard, attrs) do
    defaults = %{
      dashboard_id: dashboard.id,
      name: "Daily NOC #{System.unique_integer([:positive])}",
      recipients: ["noc@example.com"],
      cron: "* * * * *",
      timezone: "UTC",
      enabled: true,
      next_due_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    {:ok, schedule} = Dashboards.create_authored_report_schedule(scope, Map.merge(defaults, Map.new(attrs)))
    schedule
  end

  defp delivery_fixture(schedule, dashboard, attrs) do
    recipients = Keyword.get(attrs, :recipients, ["noc@example.com"])

    attrs = %{
      schedule_id: schedule.id,
      dashboard_id: dashboard.id,
      due_at: schedule.next_due_at || DateTime.utc_now(),
      status: :pending,
      recipients: recipients,
      recipient_count: length(recipients),
      rendered_metadata: %{}
    }

    {:ok, delivery} =
      DashboardReportDelivery
      |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
      |> Ash.create(actor: system_actor())

    delivery
  end

  defp deliveries_for_schedule(schedule_id) do
    DashboardReportDelivery
    |> Ash.Query.for_read(:for_schedule, %{schedule_id: schedule_id})
    |> Ash.read!(actor: system_actor())
  end

  defp get_delivery!(delivery_id) do
    DashboardReportDelivery
    |> Ash.Query.for_read(:by_id, %{id: delivery_id})
    |> Ash.read_one!(actor: system_actor())
  end

  defp get_schedule!(schedule_id) do
    DashboardReportSchedule
    |> Ash.Query.for_read(:by_id, %{id: schedule_id})
    |> Ash.read_one!(actor: system_actor())
  end

  defp ensure_oban_started! do
    if ServiceRadar.SweepJobs.ObanSupport.available?() do
      :ok
    else
      oban_config = Application.fetch_env!(:serviceradar_core, Oban)
      start_supervised!({Oban, oban_config})
      :ok
    end
  end
end
