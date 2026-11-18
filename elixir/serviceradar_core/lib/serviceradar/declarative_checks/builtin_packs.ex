defmodule ServiceRadar.DeclarativeChecks.BuiltinPacks do
  @moduledoc """
  Canonical `schema_version: 1` check templates for Built-in Pack #1
  (`io.serviceradar.storage-and-nvr-health`) covering PR #6760 SaaS Storage
  Entitlements and NVR Recording Health (`2.3`, Decision 5).
  """

  alias ServiceRadar.DeclarativeChecks.CanonicalJSON

  @pack_id "io.serviceradar.storage-and-nvr-health"
  @pack_version "1.0.0"

  @doc "Pack identifier for Built-in Pack #1."
  @spec storage_and_nvr_pack_id() :: String.t()
  def storage_and_nvr_pack_id, do: @pack_id

  @doc "Pack version for Built-in Pack #1."
  @spec storage_and_nvr_pack_version() :: String.t()
  def storage_and_nvr_pack_version, do: @pack_version

  @doc """
  Returns the four canonical `managed: true` check documents in
  `io.serviceradar.storage-and-nvr-health`, stamped with deterministic
  `template_fingerprint` digests.
  """
  @spec storage_and_nvr_checks() :: [map()]
  def storage_and_nvr_checks do
    Enum.map(
      [
        entitlement_utilization_doc(),
        hold_pin_pressure_doc(),
        archive_credential_and_usage_health_doc(),
        continuous_recording_silence_doc()
      ],
      fn doc ->
        Map.put(doc, "template_fingerprint", CanonicalJSON.template_fingerprint(doc))
      end
    )
  end

  defp entitlement_utilization_doc do
    %{
      "schema_version" => 1,
      "slug" => "storage-entitlement-utilization",
      "name" => "Storage Entitlement Utilization",
      "description" =>
        "Monitors SaaS recordings storage entitlement utilization (85% warn, 95% crit) and hard-cap enforcement.",
      "state" => "enabled",
      "pack_id" => @pack_id,
      "pack_version" => @pack_version,
      "managed" => true,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => 300,
        "timeout_seconds" => 30,
        "jitter_seconds" => 15
      },
      "target_binding" => %{
        "mode" => "singleton"
      },
      "inputs" => [
        %{
          "key" => "warn_percent",
          "type" => "number",
          "default" => 85.0,
          "min" => 1.0,
          "max" => 100.0,
          "description" => "Warning utilization percentage"
        },
        %{
          "key" => "crit_percent",
          "type" => "number",
          "default" => 95.0,
          "min" => 1.0,
          "max" => 100.0,
          "description" => "Critical utilization percentage"
        }
      ],
      "credential_slots" => [],
      "nodes" => [
        %{
          "id" => "posture_1",
          "kind" => "platform_posture",
          "label" => "Entitlement Utilization",
          "config" => %{
            "evaluator" => "storage.entitlement_utilization",
            "consumer" => "recordings"
          }
        },
        %{
          "id" => "assert_util",
          "kind" => "threshold_assert",
          "label" => "Utilization Thresholds",
          "config" => %{
            "field" => "utilization_percent",
            "warn" => %{"op" => ">=", "value" => "{{inputs.warn_percent}}"},
            "crit" => %{"op" => ">=", "value" => "{{inputs.crit_percent}}"},
            "fail_closed_field" => "hard_cap_active"
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "Storage Entitlement Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "within_entitlement",
              "degraded" => "approaching_entitlement_cap",
              "down" => "entitlement_cap_exceeded",
              "unknown" => "entitlement_unconfigured"
            }
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "posture_1",
          "source_handle" => "signal",
          "target" => "assert_util",
          "target_handle" => "in"
        },
        %{
          "id" => "e2",
          "source" => "assert_util",
          "source_handle" => "verdict",
          "target" => "out_1",
          "target_handle" => "in"
        }
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down"],
        "priority" => 2,
        "threshold" => 1,
        "window_seconds" => 300,
        "cooldown_seconds" => 300,
        "renotify_seconds" => 21_600
      },
      "ui_layout" => %{
        "nodes" => %{
          "posture_1" => %{"x" => 80, "y" => 120},
          "assert_util" => %{"x" => 380, "y" => 120},
          "out_1" => %{"x" => 680, "y" => 120}
        }
      }
    }
  end

  defp hold_pin_pressure_doc do
    %{
      "schema_version" => 1,
      "slug" => "storage-hold-pin-pressure",
      "name" => "Storage Hold Pin Pressure",
      "description" =>
        "Warns when PD5 RecordingHold pinned bytes consume archive budget and starve normal object retention.",
      "state" => "enabled",
      "pack_id" => @pack_id,
      "pack_version" => @pack_version,
      "managed" => true,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => 300,
        "timeout_seconds" => 30,
        "jitter_seconds" => 15
      },
      "target_binding" => %{
        "mode" => "singleton"
      },
      "inputs" => [
        %{
          "key" => "warn_share_percent",
          "type" => "number",
          "default" => 50.0,
          "min" => 1.0,
          "max" => 100.0,
          "description" => "Warning percentage of archive budget pinned by active holds"
        },
        %{
          "key" => "crit_share_percent",
          "type" => "number",
          "default" => 80.0,
          "min" => 1.0,
          "max" => 100.0,
          "description" => "Critical percentage of archive budget pinned by active holds"
        }
      ],
      "credential_slots" => [],
      "nodes" => [
        %{
          "id" => "posture_1",
          "kind" => "platform_posture",
          "label" => "Hold Pin Pressure",
          "config" => %{
            "evaluator" => "storage.hold_pin_pressure"
          }
        },
        %{
          "id" => "assert_holds",
          "kind" => "threshold_assert",
          "label" => "Hold Budget Share",
          "config" => %{
            "field" => "held_share_percent",
            "warn" => %{"op" => ">=", "value" => "{{inputs.warn_share_percent}}"},
            "crit" => %{"op" => ">=", "value" => "{{inputs.crit_share_percent}}"},
            "fail_closed_field" => "retention_starved"
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "Hold Pin Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "hold_pressure_nominal",
              "degraded" => "hold_pressure_elevated",
              "down" => "hold_pins_starving_retention",
              "unknown" => "hold_pressure_unknown"
            }
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "posture_1",
          "source_handle" => "signal",
          "target" => "assert_holds",
          "target_handle" => "in"
        },
        %{
          "id" => "e2",
          "source" => "assert_holds",
          "source_handle" => "verdict",
          "target" => "out_1",
          "target_handle" => "in"
        }
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down"],
        "priority" => 3,
        "threshold" => 1,
        "window_seconds" => 300,
        "cooldown_seconds" => 300,
        "renotify_seconds" => 21_600
      },
      "ui_layout" => %{
        "nodes" => %{
          "posture_1" => %{"x" => 80, "y" => 120},
          "assert_holds" => %{"x" => 380, "y" => 120},
          "out_1" => %{"x" => 680, "y" => 120}
        }
      }
    }
  end

  defp archive_credential_and_usage_health_doc do
    %{
      "schema_version" => 1,
      "slug" => "storage-archive-credential-and-usage-health",
      "name" => "Archive Credential and Usage Report Health",
      "description" =>
        "Detects missing or failing uploader/reader/retention S3 archive secrets and stale daily usage reports (> 36h).",
      "state" => "enabled",
      "pack_id" => @pack_id,
      "pack_version" => @pack_version,
      "managed" => true,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => 300,
        "timeout_seconds" => 30,
        "jitter_seconds" => 15
      },
      "target_binding" => %{
        "mode" => "singleton"
      },
      "inputs" => [
        %{
          "key" => "max_report_age_hours",
          "type" => "number",
          "default" => 36.0,
          "min" => 1.0,
          "max" => 720.0,
          "description" => "Maximum permitted age in hours for StorageUsageDailyReport"
        }
      ],
      "credential_slots" => [],
      "nodes" => [
        %{
          "id" => "posture_1",
          "kind" => "platform_posture",
          "label" => "Archive Credential & Usage Health",
          "config" => %{
            "evaluator" => "storage.archive_credential_and_usage_health",
            "max_report_age_hours" => "{{inputs.max_report_age_hours}}"
          }
        },
        %{
          "id" => "assert_archive",
          "kind" => "threshold_assert",
          "label" => "Credential & Report Freshness",
          "config" => %{
            "field" => "report_age_hours",
            "warn" => %{"op" => ">", "value" => "{{inputs.max_report_age_hours}}"},
            "fail_closed_field" => "credential_failure"
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "Archive Health Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "archive_and_usage_healthy",
              "degraded" => "usage_report_stale",
              "down" => "archive_credentials_unhealthy",
              "unknown" => "archive_health_unknown"
            }
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "posture_1",
          "source_handle" => "signal",
          "target" => "assert_archive",
          "target_handle" => "in"
        },
        %{
          "id" => "e2",
          "source" => "assert_archive",
          "source_handle" => "verdict",
          "target" => "out_1",
          "target_handle" => "in"
        }
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["degraded", "down"],
        "priority" => 2,
        "threshold" => 1,
        "window_seconds" => 300,
        "cooldown_seconds" => 300,
        "renotify_seconds" => 21_600
      },
      "ui_layout" => %{
        "nodes" => %{
          "posture_1" => %{"x" => 80, "y" => 120},
          "assert_archive" => %{"x" => 380, "y" => 120},
          "out_1" => %{"x" => 680, "y" => 120}
        }
      }
    }
  end

  defp continuous_recording_silence_doc do
    %{
      "schema_version" => 1,
      "slug" => "camera-continuous-recording-silence",
      "name" => "Camera Continuous Recording Silence",
      "description" =>
        "Detects enabled continuous CameraRecordingPolicy streams sealing 0 non-quarantined blocks across silence_window_minutes.",
      "state" => "enabled",
      "pack_id" => @pack_id,
      "pack_version" => @pack_version,
      "managed" => true,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => 180,
        "timeout_seconds" => 30,
        "jitter_seconds" => 10
      },
      "target_binding" => %{
        "mode" => "singleton"
      },
      "inputs" => [
        %{
          "key" => "silence_window_minutes",
          "type" => "integer",
          "default" => 15,
          "min" => 1,
          "max" => 1_440,
          "description" => "Rolling window in minutes over which at least 1 block must seal"
        }
      ],
      "credential_slots" => [],
      "nodes" => [
        %{
          "id" => "posture_1",
          "kind" => "platform_posture",
          "label" => "Continuous Recording Silence",
          "config" => %{
            "evaluator" => "camera.continuous_recording_silence",
            "silence_window_minutes" => "{{inputs.silence_window_minutes}}"
          }
        },
        %{
          "id" => "assert_silence",
          "kind" => "threshold_assert",
          "label" => "Silent Policy Count",
          "config" => %{
            "field" => "silent_policy_count",
            "crit" => %{"op" => ">=", "value" => 1}
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "Recording Silence Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "recording_active",
              "degraded" => "recording_degraded",
              "down" => "continuous_recording_silent",
              "unknown" => "recording_status_unknown"
            }
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "posture_1",
          "source_handle" => "signal",
          "target" => "assert_silence",
          "target_handle" => "in"
        },
        %{
          "id" => "e2",
          "source" => "assert_silence",
          "source_handle" => "verdict",
          "target" => "out_1",
          "target_handle" => "in"
        }
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down"],
        "priority" => 2,
        "threshold" => 1,
        "window_seconds" => 300,
        "cooldown_seconds" => 300,
        "renotify_seconds" => 21_600
      },
      "ui_layout" => %{
        "nodes" => %{
          "posture_1" => %{"x" => 80, "y" => 120},
          "assert_silence" => %{"x" => 380, "y" => 120},
          "out_1" => %{"x" => 680, "y" => 120}
        }
      }
    }
  end
end
