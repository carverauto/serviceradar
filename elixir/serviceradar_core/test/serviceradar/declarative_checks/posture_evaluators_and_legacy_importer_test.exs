defmodule ServiceRadar.DeclarativeChecks.PostureEvaluatorsAndLegacyImporterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DAGEngine
  alias ServiceRadar.DeclarativeChecks.LegacyImporter
  alias ServiceRadar.DeclarativeChecks.PostureEvaluators
  alias ServiceRadar.DeclarativeChecks.SchemaValidator

  # The shipped pack files, with pack parameters resolved to their defaults.
  defp built_in_doc!(slug) do
    {:ok, pack} = BuiltinPacks.get_pack("storage-and-nvr-health")

    case Enum.find(pack.checks, &(&1.normalized["slug"] == slug)) do
      nil -> raise "missing built-in check #{slug}"
      check -> check.normalized
    end
  end

  describe "Built-in Pack #1 (io.serviceradar.storage-and-nvr-health, PR #6760, 2.3)" do
    test "1. storage.entitlement_utilization evaluates healthy, warn (85%), crit (95%), hard cap, and parameter_overrides" do
      doc = built_in_doc!("storage-entitlement-utilization")
      fp_before = CanonicalJSON.compute_template_fingerprint(doc)
      plan_bytes = 100_000_000_000

      eval_with_used = fn used_bytes, hard_cap?, overrides ->
        loaders = %{
          entitlement_state_loader: fn ->
            %{
              hosted?: true,
              applied?: true,
              recordings: %{
                included_bytes: plan_bytes,
                hard_limit_bytes: plan_bytes,
                hard_cap_active: hard_cap?
              }
            }
          end,
          gauges_loader: fn -> {:ok, %{used_bytes: used_bytes, hard_limit_bytes: plan_bytes}} end
        }

        DAGEngine.evaluate_target(
          Map.put(doc, "parameter_overrides", overrides),
          %{"target_key" => "singleton"},
          loaders: loaders
        )
      end

      assert {:ok, %{status: :healthy, verdict: "within_entitlement"}} =
               eval_with_used.(50_000_000_000, false, %{})

      assert {:ok, %{status: :degraded, verdict: "approaching_entitlement_cap"}} =
               eval_with_used.(88_000_000_000, false, %{})

      assert {:ok, %{status: :down, verdict: "entitlement_cap_exceeded"}} =
               eval_with_used.(96_000_000_000, false, %{})

      assert {:ok, %{status: :down, verdict: "entitlement_cap_exceeded"}} =
               eval_with_used.(70_000_000_000, true, %{})

      # Tuning warn_percent to 92 via parameter_overrides keeps 88% healthy without changing template_fingerprint!
      tuned = Map.put(doc, "parameter_overrides", %{"utilization_warn_pct" => 92})
      assert CanonicalJSON.compute_template_fingerprint(tuned) == fp_before

      assert {:ok, %{status: :healthy}} =
               eval_with_used.(88_000_000_000, false, %{"utilization_warn_pct" => 92})
    end

    test "2. storage.hold_pin_pressure warns on elevated held share and fails closed when PD5 holds starve retention" do
      doc = built_in_doc!("storage-hold-pin-pressure")
      budget = 100_000_000_000

      eval_holds = fn held_bytes, raw_cutoff_days ->
        loaders = %{
          entitlement_state_loader: fn ->
            %{hosted?: true, applied?: true, recordings: %{hard_limit_bytes: budget}}
          end,
          gauges_loader: fn ->
            {:ok,
             %{
               held_bytes: held_bytes,
               hard_limit_bytes: budget,
               raw_cutoff_days: raw_cutoff_days
             }}
          end,
          holds_loader: fn -> {:ok, [%{state: :accepted}]} end
        }

        DAGEngine.evaluate_target(doc, %{"target_key" => "singleton"}, loaders: loaders)
      end

      assert {:ok, %{status: :healthy, verdict: "hold_pressure_nominal"}} =
               eval_holds.(20_000_000_000, 14.0)

      assert {:ok, %{status: :degraded, verdict: "hold_pressure_elevated"}} =
               eval_holds.(65_000_000_000, 5.0)

      assert {:ok, %{status: :down, verdict: "hold_pins_starving_retention"}} =
               eval_holds.(45_000_000_000, 0.0)
    end

    test "3. storage.archive_credential_and_usage_health catches missing/failing archive secrets and stale >36h usage reports" do
      doc = built_in_doc!("storage-archive-credential-health")
      now = ~U[2026-11-18 05:00:00Z]

      s_up = "00000000-0000-0000-0000-000000000301"
      s_rd = "00000000-0000-0000-0000-000000000302"
      s_rt = "00000000-0000-0000-0000-000000000303"

      eval_cred = fn secrets, report_computed_at ->
        loaders = %{
          entitlement_state_loader: fn -> %{hosted?: true, applied?: true, recordings: %{}} end,
          settings_loader: fn ->
            {:ok,
             %{
               archive_enabled: true,
               writer_credential_secret_id: s_up,
               reader_credential_secret_id: s_rd,
               retention_credential_secret_id: s_rt
             }}
          end,
          policies_loader: fn -> {:ok, [%{mode: :continuous, storage: :local_and_archive}]} end,
          secrets_loader: fn _ids -> {:ok, secrets} end,
          latest_usage_report_loader: fn ->
            {:ok, report_computed_at && %{computed_at: report_computed_at}}
          end
        }

        DAGEngine.evaluate_target(doc, %{"target_key" => "singleton"}, now: now, loaders: loaders)
      end

      healthy_secrets = [
        %{id: s_up, rotation_state: :active, last_resolution_status: :ok, metadata: %{}},
        %{id: s_rd, rotation_state: :active, last_resolution_status: :ok, metadata: %{}},
        %{id: s_rt, rotation_state: :active, last_resolution_status: :ok, metadata: %{}}
      ]

      assert {:ok, %{status: :healthy, verdict: "archive_and_usage_healthy"}} =
               eval_cred.(healthy_secrets, ~U[2026-11-18 01:00:00Z])

      # Stale usage report (> 36h) -> degraded
      assert {:ok, %{status: :degraded, verdict: "usage_report_stale"}} =
               eval_cred.(healthy_secrets, ~U[2026-11-16 08:00:00Z])

      # Failing uploader credential -> down
      broken_secrets = [
        %{
          id: s_up,
          rotation_state: :rotation_failed,
          last_resolution_status: :failed,
          metadata: %{}
        },
        %{id: s_rd, rotation_state: :active, last_resolution_status: :ok, metadata: %{}},
        %{id: s_rt, rotation_state: :active, last_resolution_status: :ok, metadata: %{}}
      ]

      assert {:ok, %{status: :down, verdict: "archive_credentials_unhealthy"}} =
               eval_cred.(broken_secrets, ~U[2026-11-18 01:00:00Z])
    end

    test "4. camera.continuous_recording_silence flags silent continuous policies and suppresses during emergency stop" do
      doc = built_in_doc!("camera-continuous-recording-silence")
      now = ~U[2026-11-18 05:00:00Z]

      cam_id = "00000000-0000-0000-0000-000000000401"
      prof_id = "00000000-0000-0000-0000-000000000402"

      eval_silence = fn stopped?, sealed_at ->
        loaders = %{
          control_state_loader: fn -> {:ok, %{stopped: stopped?}} end,
          policies_loader: fn ->
            {:ok,
             [
               %{
                 id: "00000000-0000-0000-0000-000000000499",
                 mode: :continuous,
                 storage: :local_and_archive,
                 camera_source_id: cam_id,
                 stream_profile_id: prof_id
               }
             ]}
          end,
          catalog_loader: fn ->
            entries =
              if sealed_at do
                [
                  %{
                    recording_block_id: "00000000-0000-0000-0000-000000000501",
                    camera_source_id: cam_id,
                    stream_profile_id: prof_id,
                    local_state: :retained,
                    sealed_at: sealed_at
                  }
                ]
              else
                []
              end

            {:ok, entries}
          end
        }

        DAGEngine.evaluate_target(doc, %{"target_key" => "singleton"}, now: now, loaders: loaders)
      end

      assert {:ok, %{status: :healthy, verdict: "recording_active"}} =
               eval_silence.(false, ~U[2026-11-18 04:55:00Z])

      assert {:ok, %{status: :down, verdict: "continuous_recording_silent"}} =
               eval_silence.(false, nil)

      assert {:ok, %{status: :healthy, verdict: "recording_active"}} =
               eval_silence.(true, nil)
    end
  end

  describe "LegacyImporter conversions (2.5)" do
    test "from_service_check/2 converts HTTP and TCP ServiceChecks into valid draft v1 DAGs" do
      legacy_sc = %{
        name: "Portal HTTPS Monitor",
        description: "Legacy service check",
        check_type: :http,
        target: "https://example.com/status",
        interval_seconds: 60,
        timeout_seconds: 10,
        warning_threshold_ms: 350,
        critical_threshold_ms: 1_500
      }

      assert {:ok, doc} = LegacyImporter.from_service_check(legacy_sc, skip_srql_nif?: true)
      assert doc["schema_version"] == 1
      assert doc["state"] == "draft"
      assert {:ok, _} = SchemaValidator.validate_document(doc, skip_srql_nif?: true)

      assert {:ok, %{status: :degraded}} =
               DAGEngine.evaluate_target(
                 doc,
                 %{"target_key" => "singleton"},
                 edge_observations: %{
                   "singleton" => %{
                     "probe_1" => %{
                       status: :healthy,
                       observed_at: DateTime.utc_now(),
                       payload: %{"latency_ms" => 500, "probe_failed" => false}
                     }
                   }
                 }
               )
    end

    test "from_composite_check/2 converts multi-input CompositeCheck with ordered rules into valid draft v1 DAG" do
      legacy_cc = %{
        name: "Containment Verification",
        description: "Multi-vantage isolation check",
        scope_query: "in:devices tags.containment:quarantined",
        interval_seconds: 120,
        emit_events: true,
        inputs: [
          %{
            key: "wan_reachability",
            kind: :vantage_point,
            max_age_seconds: 180,
            config: %{"check_type" => "icmp", "agent_uid" => "agent-wan-example"}
          },
          %{
            key: "edr_flag",
            kind: :device_metadata,
            max_age_seconds: 300,
            config: %{"path" => "edr.isolated", "true_when" => true}
          }
        ],
        rules: [
          %{
            position: 0,
            conditions: %{"wan_reachability" => "false", "edr_flag" => "true"},
            verdict: "isolated_verified",
            status: :healthy
          },
          %{
            position: 1,
            conditions: %{"wan_reachability" => "true", "edr_flag" => "*"},
            verdict: "isolation_breached",
            status: :down
          }
        ]
      }

      assert {:ok, doc} = LegacyImporter.from_composite_check(legacy_cc, skip_srql_nif?: true)
      assert doc["schema_version"] == 1
      assert doc["state"] == "draft"
      assert doc["target_binding"]["mode"] == "srql_devices"
      assert {:ok, _} = SchemaValidator.validate_document(doc, skip_srql_nif?: true)
    end
  end
end
