defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansMtrTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MtrJobs
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.View.ActiveScans

  @moduletag :db_free

  @policy_id "00000000-0000-0000-0000-0000000000aa"

  defp command(overrides) do
    Map.merge(
      %{
        id: "00000000-0000-0000-0000-000000000001",
        command_type: "mtr.bulk_run",
        agent_id: "agent-01",
        status: :running,
        payload: %{"targets" => ["192.0.2.1", "192.0.2.2"], "protocol" => "icmp", "protocols" => ["icmp", "tcp"]},
        context: %{"mtr_policy_id" => @policy_id},
        progress_payload: %{"total_targets" => 4, "completed_targets" => 1, "failed_targets" => 1},
        result_payload: nil,
        progress_percent: 50,
        started_at: ~U[2026-09-01 10:00:00Z],
        inserted_at: ~U[2026-09-01 09:59:58Z],
        completed_at: nil
      },
      overrides
    )
  end

  describe "MtrJobs.normalize/2" do
    test "a running job reports its profile, protocols and trace progress" do
      row = MtrJobs.normalize(command(%{}), %{@policy_id => "Edge baseline"})

      assert row.kind == :mtr
      assert row.name == "Edge baseline"
      assert row.protocols == ["icmp", "tcp"]
      assert row.total == 4
      assert row.completed == 1
      assert row.failed == 1
      assert row.reached == nil
      assert MtrJobs.protocol_label(row) == "ICMP + TCP"
    end

    test "a finished job reads its result counters, including targets reached" do
      row =
        %{
          status: :completed,
          result_payload: %{
            "total_targets" => 4,
            "completed_targets" => 4,
            "failed_targets" => 0,
            "reached_targets" => 3,
            "duration_ms" => 12_500
          },
          completed_at: ~U[2026-09-01 10:01:00Z]
        }
        |> command()
        |> MtrJobs.normalize(%{})

      assert row.reached == 3
      assert row.duration_ms == 12_500
      assert row.name == "MTR profile"
      assert MtrJobs.status_variant(row) == "success"
    end

    test "a job dispatched outside a profile is Manual and falls back to the single protocol" do
      row =
        %{context: %{}, payload: %{"targets" => ["192.0.2.1"], "protocol" => "udp"}, progress_payload: %{}}
        |> command()
        |> MtrJobs.normalize(%{})

      assert row.name == "Manual"
      assert row.protocols == ["udp"]
      assert row.total == 1
    end

    test "status variants distinguish degraded, failed and canceled jobs" do
      assert MtrJobs.status_variant(%{status: :completed, failed: 2}) == "warning"
      assert MtrJobs.status_variant(%{status: :expired, failed: 0}) == "error"
      assert MtrJobs.status_variant(%{status: :canceled, failed: 0}) == "ghost"
      assert MtrJobs.status_label(%{status: :acknowledged}) == "Acknowledged"
    end
  end

  describe "Active Scans rendering" do
    defp render_tab(overrides) do
      assigns =
        Map.merge(
          %{
            running: [],
            recent: [],
            groups: [],
            execution_progress: %{},
            mtr_running: [MtrJobs.normalize(command(%{}), %{@policy_id => "Edge baseline"})],
            mtr_recent: [
              MtrJobs.normalize(
                command(%{
                  id: "00000000-0000-0000-0000-000000000002",
                  status: :completed,
                  result_payload: %{"total_targets" => 4, "completed_targets" => 4, "reached_targets" => 3}
                }),
                %{}
              )
            ],
            can_view_mtr_jobs: true,
            filter: :all,
            timezone: "Etc/UTC"
          },
          overrides
        )

      render_component(&ActiveScans.render/1, assigns)
    end

    test "lists running and recent MTR jobs next to sweeps" do
      html = render_tab(%{})

      assert html =~ ~s(id="mtr-running-job-00000000-0000-0000-0000-000000000001")
      assert html =~ "Edge baseline"
      assert html =~ "ICMP + TCP"
      assert html =~ ~s(id="mtr-recent-job-00000000-0000-0000-0000-000000000002")
      assert html =~ "Recent Completions"
      assert html =~ ~s(id="active-scans-filter")
    end

    test "the MTR filter hides sweep sections and the Sweeps filter hides MTR" do
      mtr_only = render_tab(%{filter: :mtr})
      refute mtr_only =~ "Recent Completions"
      assert mtr_only =~ "Recent MTR Jobs"

      sweeps_only = render_tab(%{filter: :sweeps})
      refute sweeps_only =~ "mtr-running-job-"
      refute sweeps_only =~ "Recent MTR Jobs"
      assert sweeps_only =~ "Recent Completions"
    end

    test "without the sweep view permission no MTR rows, counts or filter are shown" do
      html = render_tab(%{can_view_mtr_jobs: false, filter: :mtr})

      refute html =~ "mtr-running-job-"
      refute html =~ "Recent MTR Jobs"
      refute html =~ ~s(id="active-scans-filter")
      assert html =~ "Recent Completions"
    end
  end
end
