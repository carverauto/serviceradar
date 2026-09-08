defmodule ServiceRadar.Observability.ObanFailureEventReporterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ObanFailureEventReporter

  describe "build_event_attrs/5" do
    test "builds retryable job failure events with redacted args" do
      job = %Oban.Job{
        id: 123,
        queue: "maintenance",
        worker: "ServiceRadar.Observability.GeoLiteMmdbDownloadWorker",
        state: "retryable",
        attempt: 2,
        max_attempts: 3,
        args: %{
          "path" => "/var/lib/serviceradar/geoip",
          "api_token" => "secret-token"
        },
        meta: %{"source" => "test"}
      }

      attrs =
        ObanFailureEventReporter.build_event_attrs(
          job,
          :error,
          %RuntimeError{message: "permission denied"},
          [],
          %{duration: 10}
        )

      raw_data = Jason.decode!(attrs.raw_data)

      assert attrs.status_code == "oban_job_retryable"
      assert attrs.severity == "Medium"
      assert attrs.log_name == "serviceradar.oban"
      assert attrs.message =~ "GeoLiteMmdbDownloadWorker failed"
      assert raw_data["job_id"] == 123
      assert raw_data["queue"] == "maintenance"
      assert raw_data["args"]["path"] == "/var/lib/serviceradar/geoip"
      assert raw_data["args"]["api_token"] == "[REDACTED]"
      assert raw_data["measurements"]["duration"] == 10
    end

    test "marks final attempts as discarded high-severity failures" do
      job = %Oban.Job{
        id: 456,
        queue: "integrations",
        worker: "ServiceRadar.Integrations.ArmisNorthboundRunWorker",
        state: "discarded",
        attempt: 3,
        max_attempts: 3,
        args: %{},
        meta: %{}
      }

      attrs =
        ObanFailureEventReporter.build_event_attrs(
          job,
          :error,
          %RuntimeError{message: "northbound failed"},
          [],
          %{}
        )

      assert attrs.status_code == "oban_job_discarded"
      assert attrs.severity == "High"
      assert attrs.log_level == "error"
    end
  end
end
