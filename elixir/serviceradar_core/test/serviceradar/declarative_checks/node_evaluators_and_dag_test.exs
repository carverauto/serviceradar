defmodule ServiceRadar.DeclarativeChecks.NodeEvaluatorsAndDagTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.DeclarativeChecks.DAGEngine
  alias ServiceRadar.DeclarativeChecks.Evaluation
  alias ServiceRadar.DeclarativeChecks.NodeEvaluators
  alias ServiceRadar.DeclarativeChecks.SRQLQueryNode
  alias ServiceRadar.DeclarativeChecks.TestRunner

  describe "NodeEvaluators pure transforms and verdict logic (2.1)" do
    test "interpolate preserves scalar types on exact placeholders and blocks URL/host injection" do
      inputs = %{"warn_ms" => 250, "path_suffix" => "healthz"}

      target = %{
        "ip" => "192.0.2.10",
        "hostname" => "edge-gw.example.com",
        "tags" => %{"site" => "lab"}
      }

      assert {:ok, 250} = NodeEvaluators.interpolate("{{inputs.warn_ms}}", inputs, target)

      assert {:ok, %{"url" => "https://edge-gw.example.com/healthz"}} =
               NodeEvaluators.interpolate(
                 %{"url" => "https://{{target.hostname}}/{{inputs.path_suffix}}"},
                 inputs,
                 target
               )

      assert {:error, _} =
               NodeEvaluators.interpolate(
                 %{"url" => "https://{{target.hostname}}/ok"},
                 inputs,
                 %{"hostname" => "bad.example.com\r\nX-Injected: 1"}
               )

      assert {:error, _} =
               NodeEvaluators.interpolate(
                 %{"url" => "file:///etc/passwd"},
                 inputs,
                 target
               )
    end

    test "extract_field supports bounded JSONPath, headers, linear-time regex, and field casts" do
      upstream_http = %{
        payload: %{
          "body" => Jason.encode!(%{"checks" => [%{"latency_ms" => 42.5}]}),
          "headers" => %{"X-Backend-Status" => "ready"}
        }
      }

      assert {:ok, %{status: :healthy, value: 42.5, payload: %{"db_ms" => 42.5}}} =
               NodeEvaluators.evaluate_extract_field(
                 %{
                   "source_type" => "jsonpath",
                   "expression" => "$.checks[0].latency_ms",
                   "output_key" => "db_ms"
                 },
                 upstream_http
               )

      assert {:ok, %{status: :healthy, value: "ready"}} =
               NodeEvaluators.evaluate_extract_field(
                 %{"source_type" => "header", "expression" => "x-backend-status"},
                 upstream_http
               )

      assert {:ok, %{status: :healthy, value: 18}} =
               NodeEvaluators.evaluate_extract_field(
                 %{
                   "source_type" => "regex",
                   "expression" => "queue_depth=([0-9]+)",
                   "cast" => "integer"
                 },
                 %{payload: %{"body" => "ok queue_depth=18 active=true"}}
               )

      assert {:error, msg} =
               NodeEvaluators.evaluate_extract_field(
                 %{"source_type" => "regex", "expression" => "(a+)\\1"},
                 %{payload: %{"body" => "aaaa"}}
               )

      assert msg =~ "unsafe regex"
    end

    test "threshold_assert evaluates warn, crit, and fail_closed_field deterministically" do
      cfg = %{
        "field" => "utilization_percent",
        "warn" => %{"op" => ">=", "value" => 85},
        "crit" => %{"op" => ">=", "value" => 95},
        "fail_closed_field" => "hard_cap_active"
      }

      assert {:ok, %{status: :healthy}} =
               NodeEvaluators.evaluate_threshold_assert(cfg, %{
                 payload: %{"utilization_percent" => 62.0, "hard_cap_active" => false}
               })

      assert {:ok, %{status: :degraded}} =
               NodeEvaluators.evaluate_threshold_assert(cfg, %{
                 payload: %{"utilization_percent" => 89.0, "hard_cap_active" => false}
               })

      assert {:ok, %{status: :down}} =
               NodeEvaluators.evaluate_threshold_assert(cfg, %{
                 payload: %{"utilization_percent" => 70.0, "hard_cap_active" => true}
               })
    end

    test "decision_table enforces max_age_seconds staleness -> unknown and trailing catch-all" do
      now = ~U[2026-11-18 05:00:00Z]
      fresh_at = ~U[2026-11-18 04:59:30Z]
      stale_at = ~U[2026-11-18 04:40:00Z]

      dt_cfg = %{
        "inputs" => [
          %{"key" => "edge_http", "source_node_id" => "http_1", "max_age_seconds" => 120},
          %{"key" => "core_srql", "source_node_id" => "srql_1", "max_age_seconds" => 120}
        ],
        "rules" => [
          %{
            "match" => %{"edge_http" => "healthy", "core_srql" => "healthy"},
            "status" => "healthy",
            "verdict" => "verified_healthy"
          },
          %{
            "match" => %{"edge_http" => "down", "core_srql" => "healthy"},
            "status" => "degraded",
            "verdict" => "edge_path_blocked"
          },
          %{
            "match" => %{"edge_http" => "*", "core_srql" => "*"},
            "status" => "unknown",
            "verdict" => "stale_or_indeterminate"
          }
        ]
      }

      fresh_map = %{
        "http_1" => %{status: :down, observed_at: fresh_at},
        "srql_1" => %{status: :healthy, observed_at: fresh_at}
      }

      assert {:ok, %{status: :degraded, verdict: "edge_path_blocked"}} =
               NodeEvaluators.evaluate_decision_table(dt_cfg, fresh_map, now: now)

      stale_map = %{
        "http_1" => %{status: :healthy, observed_at: stale_at},
        "srql_1" => %{status: :healthy, observed_at: fresh_at}
      }

      assert {:ok,
              %{
                status: :unknown,
                verdict: "stale_or_indeterminate",
                resolved_inputs: resolved_inputs
              }} = NodeEvaluators.evaluate_decision_table(dt_cfg, stale_map, now: now)

      assert resolved_inputs["edge_http"]["stale"] == true
      assert resolved_inputs["edge_http"]["value"] == "unknown"
    end
  end

  describe "SRQLQueryNode read-only and bound enforcement (2.2)" do
    test "rejects limit > 1_000, timeout_ms > 10_000, and raw SQL, and maps valid query rows" do
      assert {:error, {:srql_limit_exceeded, 5_000, 1_000}} =
               SRQLQueryNode.evaluate(%{"query" => "in:devices", "limit" => 5_000})

      assert {:error, {:srql_timeout_exceeded, 99_000, 10_000}} =
               SRQLQueryNode.evaluate(%{"query" => "in:devices", "timeout_ms" => 99_000})

      assert {:error, :forbidden_raw_sql} =
               SRQLQueryNode.evaluate(%{"query" => "SELECT * FROM ocsf_devices"})

      runner = fn query, opts ->
        send(self(), {:srql_executed, query, opts})
        {:ok, %{rows: [%{"uid" => "sr:dev-1", "error_count" => 7}]}}
      end

      assert {:ok, out} =
               SRQLQueryNode.evaluate(
                 %{
                   "query" => "in:devices",
                   "limit" => 25,
                   "timeout_ms" => 3_000,
                   "result_mode" => "first_row"
                 },
                 srql_runner: runner
               )

      assert_received {:srql_executed, "in:devices", [limit: 25, timeout: 3_000]}
      assert out.value == %{"uid" => "sr:dev-1", "error_count" => 7}
      assert out.payload["row_count"] == 1
    end
  end

  describe "TestRunner ephemeral execution & secret redaction (3.5)" do
    test "enforces declarative_checks.evaluate and scrubs secret values from traces without side effects" do
      synthetic_marker = "example-ephemeral-token-marker"

      doc = %{
        "schema_version" => 1,
        "slug" => "ephemeral-redaction-check",
        "name" => "Ephemeral Redaction Check",
        "state" => "draft",
        "nodes" => [
          %{
            "id" => "http_1",
            "kind" => "http_request",
            "config" => %{"url" => "https://example.com/api"}
          },
          %{
            "id" => "assert_1",
            "kind" => "threshold_assert",
            "config" => %{
              "field" => "status_code",
              "crit" => %{"op" => "!=", "value" => 200}
            }
          },
          %{"id" => "out_1", "kind" => "alert_output", "config" => %{}}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "http_1", "target" => "assert_1"},
          %{"id" => "e2", "source" => "assert_1", "target" => "out_1"}
        ]
      }

      viewer_scope = %{
        user: %{id: "viewer-1", role: :viewer},
        permissions: MapSet.new(["declarative_checks.view"])
      }

      eval_scope = %{
        user: %{id: "op-1", role: :operator},
        permissions: MapSet.new(["declarative_checks.view", "declarative_checks.evaluate"])
      }

      assert {:error, %Forbidden{}} = TestRunner.run_ephemeral(doc, %{}, scope: viewer_scope)

      assert {:ok, res} =
               TestRunner.run_ephemeral(
                 doc,
                 %{
                   "edge_observations" => %{
                     "http_1" => %{
                       "status" => "down",
                       "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
                       "payload" => %{
                         "status_code" => 500,
                         "debug_echo" => "Authorization echoed #{synthetic_marker}"
                       }
                     }
                   }
                 },
                 scope: eval_scope,
                 skip_srql_nif?: true,
                 secret_values_to_scrub: [synthetic_marker]
               )

      assert res["ephemeral"] == true
      assert res["status"] == "down"
      encoded = Jason.encode!(res)
      refute encoded =~ synthetic_marker
      assert encoded =~ "[REDACTED]"
    end

    test "DAGEngine bounds persisted node_snapshots to <= 16 KB" do
      huge_text = String.duplicate("x", 40_000)

      doc = %{
        "schema_version" => 1,
        "slug" => "snapshot-bound-check",
        "name" => "Snapshot Bound Check",
        "state" => "enabled",
        "nodes" => [
          %{
            "id" => "http_1",
            "kind" => "http_request",
            "config" => %{"url" => "https://example.com/large"}
          },
          %{"id" => "out_1", "kind" => "alert_output", "config" => %{}}
        ],
        "edges" => [%{"id" => "e1", "source" => "http_1", "target" => "out_1"}]
      }

      assert {:ok, eval_res} =
               DAGEngine.evaluate_target(
                 doc,
                 %{"target_key" => "singleton"},
                 edge_observations: %{
                   "singleton" => %{
                     "http_1" => %{
                       status: :healthy,
                       observed_at: DateTime.utc_now(),
                       payload: %{"body" => huge_text}
                     }
                   }
                 }
               )

      assert byte_size(Jason.encode!(eval_res.node_snapshots)) <= 16_384
    end
  end

  describe "Evaluation paged fan-out, departure pruning, and transition events (2.4)" do
    test "pages srql_devices, prunes departed instances, and emits OCSF transition events only on change" do
      check = %{
        id: "00000000-0000-0000-0000-000000000101",
        slug: "paged-device-srql-check",
        name: "Paged Device SRQL Check",
        state: :enabled,
        target_binding: %{"mode" => "srql_devices", "scope_query" => "in:devices"},
        alert_policy: %{"emit_ocsf_transition" => true, "open_on_statuses" => ["down"]},
        nodes: [
          %{
            "id" => "q_1",
            "kind" => "srql_query",
            "config" => %{"query" => "in:devices", "limit" => 10}
          },
          %{
            "id" => "assert_1",
            "kind" => "threshold_assert",
            "config" => %{"field" => "row_count", "crit" => %{"op" => "==", "value" => 0}}
          },
          %{"id" => "out_1", "kind" => "alert_output", "config" => %{}}
        ],
        edges: [
          %{"id" => "e1", "source" => "q_1", "target" => "assert_1"},
          %{"id" => "e2", "source" => "assert_1", "target" => "out_1"}
        ]
      }

      {:ok, store} =
        Agent.start_link(fn ->
          %{
            "device:sr:departed" => %{
              check_id: check.id,
              target_key: "device:sr:departed",
              device_uid: "sr:departed",
              verdict: "healthy",
              status: :healthy,
              evaluated_at: ~U[2026-11-18 04:00:00Z],
              changed_at: ~U[2026-11-18 04:00:00Z]
            },
            "device:sr:staying" => %{
              check_id: check.id,
              target_key: "device:sr:staying",
              device_uid: "sr:staying",
              verdict: "healthy",
              status: :healthy,
              evaluated_at: ~U[2026-11-18 04:00:00Z],
              changed_at: ~U[2026-11-18 04:00:00Z]
            }
          }
        end)

      check_with_target =
        put_in(
          check,
          [:nodes, Access.at(0), "config", "query"],
          "in:devices uid:\"{{target.uid}}\""
        )

      smart_runner = fn q, _opts ->
        if String.contains?(q, "sr:new-down") do
          {:ok, %{rows: []}}
        else
          {:ok, %{rows: [%{"uid" => "sr:staying"}]}}
        end
      end

      test_pid = self()

      persister = fn _chk, eval_rows, _kind, evaluated_at ->
        transitions =
          Enum.flat_map(eval_rows, fn row ->
            prior = Agent.get(store, &Map.get(&1, row.target_key))
            changed? = is_nil(prior) or prior.status != row.status or prior.verdict != row.verdict

            Agent.update(store, fn m ->
              Map.put(m, row.target_key, Map.put(row, :evaluated_at, evaluated_at))
            end)

            if changed? do
              [
                %{
                  target_key: row.target_key,
                  device_uid: row.device_uid,
                  from_verdict: prior && prior.verdict,
                  to_verdict: row.verdict,
                  from_status: prior && prior.status,
                  to_status: row.status,
                  summary: row.summary,
                  evaluated_at: evaluated_at
                }
              ]
            else
              []
            end
          end)

        {:ok, transitions}
      end

      pruner = fn _chk, started_at ->
        departed =
          Agent.get(store, fn m ->
            for {tk, v} <- m, DateTime.before?(v.evaluated_at, started_at), do: tk
          end)

        Agent.update(store, &Map.drop(&1, departed))
        {length(departed), departed}
      end

      deactivator = fn service_names ->
        send(test_pid, {:deactivated_services, service_names})
      end

      publish_fn = fn attrs, pub_opts ->
        send(test_pid, {:ocsf_published, pub_opts[:family], attrs})
        {:ok, "evt-1"}
      end

      assert {:ok, summary} =
               Evaluation.run(
                 check_with_target,
                 now: ~U[2026-11-18 05:00:00Z],
                 device_pages_loader: fn _q -> [["sr:staying"], ["sr:new-down"]] end,
                 live_devices_loader: fn _uids ->
                   %{
                     "sr:staying" => %{uid: "sr:staying", hostname: "staying.example.com"},
                     "sr:new-down" => %{uid: "sr:new-down", hostname: "down.example.com"}
                   }
                 end,
                 srql_runner: smart_runner,
                 instance_persister: persister,
                 instance_pruner: pruner,
                 service_state_deactivator: deactivator,
                 event_publisher: publish_fn
               )

      assert summary.evaluated == 2
      assert summary.removed == 1

      assert_received {:deactivated_services, ["paged-device-srql-check/device:sr:departed"]}

      # Only sr:new-down transitioned (nil -> down); sr:staying stayed healthy -> healthy so no OCSF spam!
      assert length(summary.transitions) == 1
      assert_received {:ocsf_published, :declarative_check, ocsf_attrs}
      assert ocsf_attrs.log_name == "declarative_check.health.state_change"
      assert ocsf_attrs.unmapped["target_key"] == "device:sr:new-down"
      assert ocsf_attrs.unmapped["to_status"] == "down"
      refute_received {:ocsf_published, _, _}
    end
  end
end
