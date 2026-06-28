defmodule ServiceRadar.Observability.AnomalyDispositionReporterTest do
  # async: false — uses a named GenServer + global :telemetry handler.
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.Observability.AnomalyDispositionReporter, as: Reporter

  # Stub SRQL runner: a payload-wrapped hour-of-week PEAK profile row for device sr:ns03
  # at (dow 2, hod 9) — this hour normally peaks ~55 (p95 61) over 8 buckets. No DB.
  defmodule StubRunner do
    @moduledoc false
    def query(_query, _opts) do
      {:ok,
       [
         %{
           "payload" => %{
             "series" => "sr:ns03",
             "dow" => 2,
             "hod" => 9,
             "center" => 55,
             "p95" => 61,
             "bucket_count" => 8
           }
         }
       ]}
    end
  end

  # 2026-06-16 09:00:00Z is a Tuesday -> Postgres EXTRACT(DOW)=2, hour 9 (matches the stub).
  @peak_at DateTime.to_unix(~U[2026-06-16 09:00:00Z], :nanosecond)

  defp finding(peak_value) do
    %{
      source_identity: %{
        "device_id" => "sr:ns03",
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent"
      },
      episode_peak_value: peak_value,
      episode_peak_at_unix_nano: @peak_at
    }
  end

  # A persisted class-2004 anomaly OCSF row, shaped exactly as build_ocsf_event_row/4
  # produces it (metadata.service_radar + finding_info.dimensions with the FORWARDED peak).
  defp persisted_anomaly_row(peak_value) do
    %{
      class_uid: 2004,
      metadata: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "service_radar" => %{
          "device_id" => "sr:ns03",
          "metric_class" => "sysmon.cpu",
          "metric_name" => "cpu.usage_percent"
        },
        "finding_info" => %{
          "dimensions" => %{
            "episode_peak_value" => peak_value,
            "episode_peak_at_unix_nano" => @peak_at
          }
        }
      }
    }
  end

  setup do
    parent = self()
    handler = "disp-reporter-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:serviceradar, :anomaly, :disposition],
      fn _event, measurements, metadata, _config ->
        send(parent, {:disposition, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Per-test reporter instance with the stub runner injected (no DB), under a unique
    # name so it never collides with the application-started reporter.
    name = :"disp_reporter_#{System.unique_integer([:positive])}"
    {:ok, pid} = Reporter.start_link(name: name, report_opts: [runner: StubRunner])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{reporter: name}
  end

  describe "field mapping (persisted class-2004 row -> report_finding shape)" do
    test "forwards the canonical source_identity and the edge episode peak" do
      finding = AnalyticsSignals.anomaly_disposition_finding(persisted_anomaly_row(92.0))

      assert finding == %{
               source_identity: %{
                 "device_id" => "sr:ns03",
                 "metric_class" => "sysmon.cpu",
                 "metric_name" => "cpu.usage_percent"
               },
               episode_peak_value: 92.0,
               episode_peak_at_unix_nano: @peak_at
             }
    end

    test "returns nil when the forwarded peak is absent (nothing to dispose)" do
      row = persisted_anomaly_row(92.0)
      dimensions = Map.delete(row.metadata["finding_info"]["dimensions"], "episode_peak_value")

      row =
        put_in(row, [:metadata, "finding_info", "dimensions"], dimensions)

      assert AnalyticsSignals.anomaly_disposition_finding(row) == nil
    end
  end

  describe "report/2 drives the report-only disposition" do
    test "a novel class-2004 spike peak escalates and stays report-only", %{reporter: reporter} do
      assert :ok = Reporter.report(finding(92.0), reporter)

      assert_receive {:disposition, %{count: 1}, metadata}
      assert metadata.disposition == :escalate
      # report-only safety contract: never actionable by default, so no alert is
      # suppressed, mutated, or created by this path.
      assert metadata.actionable == false
    end

    test "an in-profile class-2004 spike peak suppresses and stays report-only", %{
      reporter: reporter
    } do
      assert :ok = Reporter.report(finding(56.0), reporter)

      assert_receive {:disposition, %{count: 1}, metadata}
      assert metadata.disposition == :suppress
      assert metadata.actionable == false
    end

    test "no peak profile match passes through (no telemetry suppression of a real alert)",
         %{reporter: reporter} do
      # device_id the stub profile does not cover -> empty profile -> pass_through.
      orphan =
        92.0
        |> finding()
        |> put_in([:source_identity, "device_id"], "sr:not-in-profile")

      assert :ok = Reporter.report(orphan, reporter)

      assert_receive {:disposition, %{count: 1}, metadata}
      assert metadata.disposition == :pass_through
      assert metadata.actionable == false
    end
  end

  describe "report/2 safety" do
    test "is a no-op when the reporter is not running (never blocks ingest)" do
      assert :ok = Reporter.report(finding(92.0), :anomaly_disposition_reporter_absent)
      refute_receive {:disposition, _measurements, _metadata}
    end

    test "ignores a finding that cannot be disposed (no forwarded peak)", %{reporter: reporter} do
      no_peak = Map.delete(finding(92.0), :episode_peak_value)

      assert :ok = Reporter.report(no_peak, reporter)
      refute_receive {:disposition, _measurements, _metadata}
    end
  end
end
