defmodule ServiceRadar.DeclarativeChecks.AssignmentCompilerAndEdgeIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.DeclarativeChecks.AssignmentCompiler
  alias ServiceRadar.DeclarativeChecks.EdgeResultIngestor
  alias ServiceRadar.DeclarativeChecks.Evaluation
  alias ServiceRadar.Observability.PluginResultIngestor

  @fixed_now ~U[2026-11-18 12:00:00.000000Z]
  @check_id_1 "00000000-0000-4000-8000-000000000301"
  @check_id_2 "00000000-0000-4000-8000-000000000302"
  @check_id_3 "00000000-0000-4000-8000-000000000303"
  @secret_id "00000000-0000-4000-8000-000000000399"
  @grant_id "00000000-0000-4000-8000-000000000388"

  describe "AssignmentCompiler" do
    test "compiles singleton Edge-only HTTP journey with allowlists and secret-free CredentialBrokerGrant" do
      raw_secret_value = "NEVER_EMBED_THIS_PLAINTEXT_SECRET"

      check = %{
        id: @check_id_1,
        slug: "checkout-journey",
        name: "Checkout Journey",
        state: :enabled,
        schedule: %{"interval_seconds" => 60, "timeout_seconds" => 15},
        target_binding: %{
          "mode" => "singleton",
          "url" => "https://checkout.example.com"
        },
        inputs: [
          %{"key" => "api_prefix", "type" => "string", "default" => "/v1"}
        ],
        credential_slots: [
          %{"slot" => "checkout_auth", "kind" => "bearer_token", "required" => true}
        ],
        nodes: [
          %{
            "id" => "journey_1",
            "kind" => "http_journey",
            "config" => %{
              "agent_id" => "agent-west-1",
              "steps" => [
                %{
                  "id" => "login",
                  "method" => "POST",
                  "url" => "{{target.url}}{{inputs.api_prefix}}/session",
                  "credential_slot" => "checkout_auth",
                  "expected_statuses" => [200]
                },
                %{
                  "id" => "verify_cart",
                  "method" => "GET",
                  "url" => "{{target.url}}{{inputs.api_prefix}}/orders/{{steps.login.order_id}}",
                  "expected_statuses" => [200]
                }
              ]
            }
          },
          %{
            "id" => "out",
            "kind" => "alert_output",
            "config" => %{}
          }
        ],
        edges: [
          %{"id" => "e1", "source" => "journey_1", "target" => "out"}
        ]
      }

      bindings = [
        %{slot: "checkout_auth", credential_secret_id: @secret_id}
      ]

      grant_issuer = fn attrs ->
        assert attrs.secret_id == @secret_id
        assert attrs.agent_id == "agent-west-1"
        assert attrs.allowed_schemes == ["https"]
        assert attrs.allowed_hosts == ["checkout.example.com"]
        assert attrs.allowed_ports == [443]

        {:ok,
         Map.merge(attrs, %{
           id: @grant_id,
           status: :issued,
           _unsolicited_plaintext: raw_secret_value
         })}
      end

      assert {:ok, [spec]} =
               AssignmentCompiler.compile_check(check,
                 credential_bindings: bindings,
                 grant_issuer: grant_issuer,
                 now: @fixed_now
               )

      assert spec.agent_id == "agent-west-1"
      assert spec.single_agent_complete == true

      assert spec.assignment_id ==
               AssignmentCompiler.deterministic_assignment_id(@check_id_1, "agent-west-1", 0)

      assert spec.permissions == %{
               allowed_domains: ["checkout.example.com"],
               allowed_networks: [],
               allowed_ports: [443]
             }

      encoded = Jason.encode!(spec)
      refute String.contains?(encoded, raw_secret_value)

      [target] = spec.params["targets"]
      slot_grant = get_in(target, ["credential_bindings", "checkout_auth", "credential_broker"])
      assert slot_grant["schema"] == "serviceradar.edge_credential_broker_grant.v1"
      assert slot_grant["grant_id"] == @grant_id
      assert slot_grant["allow"]["hosts"] == ["checkout.example.com"]

      # compile_for_agent produces AgentConfigGenerator-shaped assignments
      agent_assignments =
        AssignmentCompiler.compile_for_agent("agent-west-1", "default",
          checks: [check],
          credential_bindings: bindings,
          grant_issuer: grant_issuer,
          require_approved_package?: false,
          now: @fixed_now
        )

      assert [agent_cfg] = agent_assignments
      assert agent_cfg.plugin_id == "io.serviceradar.declarative-check-runner"
      assert agent_cfg.entrypoint == "run_check"
      assert agent_cfg.interval_sec == 60
      assert agent_cfg.timeout_sec == 15
    end

    test "compiles srql_devices and service_targets with per-agent grouping, IP CIDR allowlists, and deterministic chunking" do
      device_check = %{
        id: @check_id_2,
        slug: "dns-device-posture",
        name: "DNS Device Posture",
        state: :enabled,
        target_binding: %{"mode" => "srql_devices", "scope_query" => "in:devices role:dns"},
        nodes: [
          %{
            "id" => "dns_q",
            "kind" => "dns_lookup",
            "config" => %{"hostname" => "ns.example.com", "record_type" => "A"}
          },
          %{"id" => "out", "kind" => "alert_output", "config" => %{}}
        ],
        edges: [%{"id" => "e1", "source" => "dns_q", "target" => "out"}]
      }

      devices = [
        %{uid: "sr:dev-1", ip: "192.0.2.10", agent_id: "agent-a"},
        %{uid: "sr:dev-2", ip: "192.0.2.11", agent_id: "agent-a"},
        %{uid: "sr:dev-3", hostname: "dns3.example.com", ip: "192.0.2.12", agent_id: "agent-b"}
      ]

      assert {:ok, specs} =
               AssignmentCompiler.compile_check(device_check,
                 devices_loader: fn _ -> devices end,
                 chunk_size: 1
               )

      assert length(specs) == 3
      [a0, a1, b0] = specs
      assert a0.agent_id == "agent-a" and a0.chunk_index == 0
      assert a1.agent_id == "agent-a" and a1.chunk_index == 1
      assert a0.assignment_id != a1.assignment_id
      assert a0.permissions.allowed_networks == ["192.0.2.10/32"]
      assert a0.permissions.allowed_ports == [53]
      assert b0.agent_id == "agent-b"
      assert b0.permissions.allowed_domains == ["dns3.example.com"]

      service_check = %{
        id: @check_id_3,
        slug: "tls-service-targets",
        name: "TLS Service Targets",
        state: :enabled,
        target_binding: %{
          "mode" => "service_targets",
          "target_ids" => ["svc-1", "svc-2"]
        },
        nodes: [
          %{
            "id" => "tls_1",
            "kind" => "tls_handshake",
            "config" => %{"host" => "{{target.host}}", "port" => 8443, "min_days_remaining" => 21}
          },
          %{"id" => "out", "kind" => "alert_output", "config" => %{}}
        ],
        edges: [%{"id" => "e1", "source" => "tls_1", "target" => "out"}]
      }

      assert {:ok, [svc_spec]} =
               AssignmentCompiler.compile_check(service_check,
                 service_targets_loader: fn _ ->
                   [
                     %{id: "svc-1", host: "edge1.example.com", agent_id: "agent-tls"},
                     %{id: "svc-2", host: "bad/host\r\n", agent_id: "agent-tls"}
                   ]
                 end
               )

      assert svc_spec.agent_id == "agent-tls"
      assert Enum.map(svc_spec.params["targets"], & &1["target_key"]) == ["service:svc-1"]
      assert svc_spec.permissions.allowed_domains == ["edge1.example.com"]
      assert svc_spec.permissions.allowed_ports == [8443]
    end

    test "extracts only Edge subgraph for Hybrid checks and skips Core-only checks" do
      hybrid_check = %{
        id: @check_id_2,
        slug: "hybrid-api-and-errors",
        name: "Hybrid API + SRQL",
        state: :enabled,
        target_binding: %{"mode" => "singleton", "url" => "https://api.example.com/health"},
        nodes: [
          %{
            "id" => "edge_http",
            "kind" => "http_request",
            "config" => %{"url" => "{{target.url}}", "agent_id" => "agent-edge-1"}
          },
          %{
            "id" => "extract_lat",
            "kind" => "extract_field",
            "config" => %{"source_type" => "field", "field" => "latency_ms", "cast" => "float"}
          },
          %{
            "id" => "assert_edge",
            "kind" => "threshold_assert",
            "config" => %{"field" => "value", "crit" => %{">" => 500}}
          },
          %{
            "id" => "core_srql",
            "kind" => "srql_query",
            "config" => %{"query" => "in:logs severity:error", "result_mode" => "count"}
          },
          %{
            "id" => "decide",
            "kind" => "decision_table",
            "config" => %{"default_verdict" => "unknown", "rules" => []}
          },
          %{"id" => "out", "kind" => "alert_output", "config" => %{}}
        ],
        edges: [
          %{"source" => "edge_http", "target" => "extract_lat"},
          %{"source" => "extract_lat", "target" => "assert_edge"},
          %{"source" => "assert_edge", "target" => "decide"},
          %{"source" => "core_srql", "target" => "decide"},
          %{"source" => "decide", "target" => "out"}
        ]
      }

      assert {:ok, [spec]} = AssignmentCompiler.compile_check(hybrid_check)
      assert spec.topology == :hybrid
      assert spec.single_agent_complete == false

      assert Enum.map(spec.params["nodes"], & &1["id"]) == [
               "edge_http",
               "extract_lat",
               "assert_edge"
             ]

      assert spec.params["output_node_ids"] == ["assert_edge"]

      core_only = %{
        id: @check_id_3,
        slug: "core-only-posture",
        state: :enabled,
        nodes: [
          %{
            "id" => "p",
            "kind" => "platform_posture",
            "config" => %{"evaluator" => "storage.hold_pin_pressure"}
          },
          %{"id" => "out", "kind" => "alert_output", "config" => %{}}
        ],
        edges: [%{"source" => "p", "target" => "out"}]
      }

      assert {:ok, []} = AssignmentCompiler.compile_check(core_only)
    end
  end

  describe "EdgeResultIngestor" do
    test "is registered in PluginResultIngestor.platform_contract_handlers/0" do
      assert EdgeResultIngestor in PluginResultIngestor.platform_contract_handlers()
    end

    test "ingests single-agent Edge-only results into observations, instance, ServiceState, and OCSF transitions" do
      check = %{
        id: @check_id_1,
        slug: "checkout-journey",
        name: "Checkout Journey",
        state: :enabled,
        alert_policy: %{"emit_ocsf_transition" => true},
        nodes: [
          %{
            "id" => "journey_1",
            "kind" => "http_journey",
            "config" => %{"agent_id" => "agent-west-1"}
          },
          %{"id" => "out", "kind" => "alert_output", "config" => %{}}
        ],
        edges: [%{"source" => "journey_1", "target" => "out"}]
      }

      {:ok, state_agent} =
        Agent.start_link(fn -> %{obs: [], instances: %{}, states: [], events: []} end)

      payload = %{
        "status" => "CRITICAL",
        "summary" => "step verify_cart failed",
        "details" =>
          Jason.encode!(%{
            "schema" => "serviceradar.declarative_check_edge_result.v1",
            "check_id" => @check_id_1,
            "slug" => "checkout-journey",
            "topology" => "edge_only",
            "single_agent_complete" => true,
            "observed_at" => "2026-11-18T12:00:00Z",
            "targets" => [
              %{
                "target_key" => "singleton",
                "target_kind" => "singleton",
                "verdict" => "down",
                "status" => "down",
                "summary" => "Checkout failed with Bearer synth-leaked-secret",
                "node_snapshots" => %{
                  "journey_1" => %{
                    "status" => "down",
                    "access_token" => "synth-leaked-secret"
                  }
                },
                "edge_observations" => [
                  %{
                    "node_id" => "journey_1",
                    "status" => "down",
                    "value" => "down",
                    "duration_ms" => 44,
                    "observed_at" => "2026-11-18T12:00:00Z",
                    "payload" => %{"latency_ms" => 44, "probe_failed" => true}
                  }
                ]
              }
            ]
          })
      }

      ingest_opts = [
        check_loader: fn _id -> {:ok, check} end,
        observation_upserter: fn attrs ->
          Agent.update(state_agent, fn s -> %{s | obs: [attrs | s.obs]} end)
          {:ok, attrs}
        end,
        instance_loader: fn check_id, tkey ->
          Agent.get(state_agent, &Map.get(&1.instances, {check_id, tkey}))
        end,
        instance_upserter: fn attrs ->
          Agent.update(state_agent, fn s ->
            %{s | instances: Map.put(s.instances, {attrs.check_id, attrs.target_key}, attrs)}
          end)

          {:ok, attrs}
        end,
        service_state_writer: fn attrs ->
          Agent.update(state_agent, fn s -> %{s | states: [attrs | s.states]} end)
          {:ok, attrs}
        end,
        event_publisher: fn attrs, _opts ->
          Agent.update(state_agent, fn s -> %{s | events: [attrs | s.events]} end)
          {:ok, attrs}
        end
      ]

      assert EdgeResultIngestor.supports?(payload, %{agent_id: "agent-west-1"})
      assert :ok = EdgeResultIngestor.ingest(payload, %{agent_id: "agent-west-1"}, ingest_opts)

      snapshot = Agent.get(state_agent, & &1)
      assert [obs] = snapshot.obs
      assert obs.agent_id == "agent-west-1"
      assert obs.node_id == "journey_1"
      assert obs.status == :down

      inst = snapshot.instances[{@check_id_1, "singleton"}]
      assert inst.status == :down
      refute String.contains?(inst.summary, "synth-leaked-secret")
      refute String.contains?(Jason.encode!(inst.node_snapshots), "synth-leaked-secret")

      assert [svc_state] = snapshot.states
      assert svc_state.service_name == "checkout-journey"
      assert svc_state.available == false

      assert [event] = snapshot.events
      assert event.log_name == "declarative_check.health.state_change"

      # Re-ingesting identical verdict preserves changed_at and emits zero extra transitions
      later_payload =
        Map.put(
          payload,
          "details",
          String.replace(payload["details"], "2026-11-18T12:00:00Z", "2026-11-18T12:01:00Z")
        )

      assert :ok =
               EdgeResultIngestor.ingest(later_payload, %{agent_id: "agent-west-1"}, ingest_opts)

      snapshot2 = Agent.get(state_agent, & &1)
      assert length(snapshot2.events) == 1

      assert DateTime.compare(
               snapshot2.instances[{@check_id_1, "singleton"}].changed_at,
               @fixed_now
             ) == :eq
    end

    test "ingests Hybrid Edge observations, triggers debounced CoreEvaluationWorker refresh, and feeds Hybrid DAG evaluation" do
      hybrid_check = %{
        id: @check_id_2,
        slug: "hybrid-api-and-srql",
        name: "Hybrid API + SRQL",
        state: :enabled,
        target_binding: %{"mode" => "singleton", "url" => "https://api.example.com/health"},
        nodes: [
          %{
            "id" => "edge_http",
            "kind" => "http_request",
            "config" => %{"url" => "https://api.example.com/health", "agent_id" => "agent-edge-1"}
          },
          %{
            "id" => "core_errors",
            "kind" => "srql_query",
            "config" => %{"query" => "in:logs severity:error", "result_mode" => "count"}
          },
          %{
            "id" => "assert_errors",
            "kind" => "threshold_assert",
            "config" => %{"field" => "count", "crit" => %{"op" => ">=", "value" => 10}}
          },
          %{
            "id" => "decide",
            "kind" => "decision_table",
            "config" => %{
              "inputs" => [
                %{"key" => "edge_http", "field" => "status", "max_age_seconds" => 300},
                %{"key" => "assert_errors", "field" => "verdict"}
              ],
              "rules" => [
                %{
                  "match" => %{"edge_http" => "healthy", "assert_errors" => "healthy"},
                  "verdict" => "healthy",
                  "status" => "healthy",
                  "summary" => "Edge probe and Core SRQL error rate healthy"
                },
                %{
                  "match" => %{"edge_http" => "*", "assert_errors" => "*"},
                  "verdict" => "degraded",
                  "status" => "degraded",
                  "summary" => "Hybrid degraded"
                }
              ]
            }
          },
          %{"id" => "out", "kind" => "alert_output", "config" => %{}}
        ],
        edges: [
          %{"source" => "core_errors", "target" => "assert_errors"},
          %{"source" => "edge_http", "target" => "decide", "target_handle" => "in:edge_http"},
          %{
            "source" => "assert_errors",
            "target" => "decide",
            "target_handle" => "in:assert_errors"
          },
          %{"source" => "decide", "target" => "out"}
        ]
      }

      {:ok, tracker} = Agent.start_link(fn -> %{obs: [], refreshed: []} end)

      edge_payload = %{
        "status" => "OK",
        "summary" => "HTTP 200",
        "details" =>
          Jason.encode!(%{
            "schema" => "serviceradar.declarative_check_edge_result.v1",
            "check_id" => @check_id_2,
            "slug" => "hybrid-api-and-srql",
            "topology" => "hybrid",
            "single_agent_complete" => false,
            "observed_at" => "2026-11-18T12:00:00Z",
            "targets" => [
              %{
                "target_key" => "singleton",
                "target_kind" => "singleton",
                "verdict" => "healthy",
                "status" => "healthy",
                "edge_observations" => [
                  %{
                    "node_id" => "edge_http",
                    "status" => "healthy",
                    "value" => "200",
                    "duration_ms" => 12,
                    "observed_at" => "2026-11-18T12:00:00Z",
                    "payload" => %{
                      "status_code" => 200,
                      "latency_ms" => 12.0,
                      "probe_failed" => false
                    }
                  }
                ]
              }
            ]
          })
      }

      assert :ok =
               EdgeResultIngestor.ingest(edge_payload, %{agent_id: "agent-edge-1"},
                 check_loader: fn _ -> {:ok, hybrid_check} end,
                 observation_upserter: fn attrs ->
                   Agent.update(tracker, fn s -> %{s | obs: [attrs | s.obs]} end)
                   {:ok, attrs}
                 end,
                 hybrid_refresher: fn check_id ->
                   Agent.update(tracker, fn s -> %{s | refreshed: [check_id | s.refreshed]} end)
                   {:ok, :scheduled}
                 end
               )

      state = Agent.get(tracker, & &1)
      assert state.refreshed == [@check_id_2]
      assert [persisted_obs] = state.obs

      # Feed persisted Edge observation into Evaluation.run alongside Core SRQL query
      assert {:ok, eval_summary} =
               Evaluation.run(hybrid_check,
                 now: @fixed_now,
                 emit_events?: false,
                 edge_observations: %{
                   {"edge_http", "singleton", "agent-edge-1"} => persisted_obs,
                   {"edge_http", "singleton"} => persisted_obs
                 },
                 srql_runner: fn _q, _opts -> {:ok, %{rows: [%{"id" => "1"}, %{"id" => "2"}]}} end,
                 instance_persister: fn _check, rows, _kind, _at ->
                   assert [%{status: :healthy, verdict: "healthy"}] = rows
                   {:ok, []}
                 end
               )

      assert eval_summary.evaluated == 1
      assert eval_summary.topology == :hybrid
    end

    test "refuses missing agent_id and malformed envelopes" do
      valid_details =
        Jason.encode!(%{
          "schema" => "serviceradar.declarative_check_edge_result.v1",
          "check_id" => @check_id_1,
          "targets" => []
        })

      assert {:refused, :declarative_check_missing_agent_id, _} =
               EdgeResultIngestor.ingest(%{"details" => valid_details}, %{})

      bad_details =
        Jason.encode!(%{
          "schema" => "serviceradar.declarative_check_edge_result.v1",
          "check_id" => "not-a-uuid",
          "targets" => "bad"
        })

      assert {:refused, :declarative_check_invalid_edge_result, _} =
               EdgeResultIngestor.ingest(%{"details" => bad_details}, %{agent_id: "agent-1"})
    end
  end
end
