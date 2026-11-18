defmodule ServiceRadarWebNGWeb.Api.DeclarativeCheckControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.TestSupport.DeclarativeChecksStub
  alias ServiceRadarWebNGWeb.Api.DeclarativeCheckController, as: Controller
  alias ServiceRadarWebNGWeb.Router

  @moduletag :db_free

  @user_id "00000000-0000-4000-8000-000000000701"
  @secret_uuid "00000000-0000-4000-8000-000000000702"

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :declarative_checks)
    Application.put_env(:serviceradar_web_ng, :declarative_checks, DeclarativeChecksStub)
    DeclarativeChecksStub.reset!()

    on_exit(fn ->
      DeclarativeChecksStub.reset!()

      if previous do
        Application.put_env(:serviceradar_web_ng, :declarative_checks, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :declarative_checks)
      end
    end)

    operator_scope =
      scope_with_permissions([
        "declarative_checks.view",
        "declarative_checks.manage",
        "declarative_checks.evaluate"
      ])

    %{
      conn: assign(build_conn(), :current_scope, operator_scope),
      operator_scope: operator_scope
    }
  end

  describe "router wiring under /api/v2/declarative-checks" do
    test "resolves every CRUD, export, import, and test-run route before AshJsonApiRouter" do
      assert %{plug: Controller, plug_opts: :index} =
               Phoenix.Router.route_info(Router, "GET", "/api/v2/declarative-checks", "localhost")

      assert %{plug: Controller, plug_opts: :create} =
               Phoenix.Router.route_info(Router, "POST", "/api/v2/declarative-checks", "localhost")

      assert %{plug: Controller, plug_opts: :import_check} =
               Phoenix.Router.route_info(Router, "POST", "/api/v2/declarative-checks/import", "localhost")

      assert %{plug: Controller, plug_opts: :test_run_inline} =
               Phoenix.Router.route_info(Router, "POST", "/api/v2/declarative-checks/test-run", "localhost")

      assert %{plug: Controller, plug_opts: :show} =
               Phoenix.Router.route_info(
                 Router,
                 "GET",
                 "/api/v2/declarative-checks/storage-entitlement-utilization",
                 "localhost"
               )

      assert %{plug: Controller, plug_opts: :update} =
               Phoenix.Router.route_info(
                 Router,
                 "PUT",
                 "/api/v2/declarative-checks/storage-entitlement-utilization",
                 "localhost"
               )

      assert %{plug: Controller, plug_opts: :delete} =
               Phoenix.Router.route_info(
                 Router,
                 "DELETE",
                 "/api/v2/declarative-checks/storage-entitlement-utilization",
                 "localhost"
               )

      assert %{plug: Controller, plug_opts: :export} =
               Phoenix.Router.route_info(
                 Router,
                 "GET",
                 "/api/v2/declarative-checks/storage-entitlement-utilization/export",
                 "localhost"
               )

      assert %{plug: Controller, plug_opts: :test_run} =
               Phoenix.Router.route_info(
                 Router,
                 "POST",
                 "/api/v2/declarative-checks/storage-entitlement-utilization/test-run",
                 "localhost"
               )
    end
  end

  describe "authentication and RBAC enforcement" do
    test "returns 401 when unauthenticated" do
      anon = build_conn()

      assert json_response(call(anon, :index, %{}), 401)["error"] == "unauthorized"
      assert json_response(call(anon, :create, sample_check_doc()), 401)["error"] == "unauthorized"
      assert json_response(call(anon, :import_check, sample_check_doc()), 401)["error"] == "unauthorized"
      assert json_response(call(anon, :test_run_inline, sample_check_doc()), 401)["error"] == "unauthorized"
    end

    test "returns 403 without declarative_checks.* permissions across all endpoints" do
      no_perms = assign(build_conn(), :current_scope, scope_with_permissions([]))

      for {action, params, path_params} <- [
            {:index, %{}, %{}},
            {:show, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}},
            {:export, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}},
            {:create, sample_check_doc(), %{}},
            {:update, %{"slug" => "checkout-api-health", "state" => "enabled"}, %{"slug" => "checkout-api-health"}},
            {:delete, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}},
            {:import_check, %{"document" => sample_check_doc()}, %{}},
            {:test_run_inline, %{"document" => sample_check_doc()}, %{}},
            {:test_run, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}}
          ] do
        resp = json_response(call(no_perms, action, params, path_params), 403)
        assert resp["error"] == "forbidden"
      end
    end

    test "viewer with declarative_checks.view can read and export but receives 403 on manage and evaluate",
         %{conn: operator_conn} do
      assert json_response(call(operator_conn, :create, sample_check_doc()), 201)

      viewer_conn =
        assign(build_conn(), :current_scope, scope_with_permissions(["declarative_checks.view"]))

      assert %{"data" => [%{"slug" => "checkout-api-health"}]} =
               json_response(call(viewer_conn, :index, %{}), 200)

      assert %{"data" => %{"slug" => "checkout-api-health"}} =
               json_response(
                 call(viewer_conn, :show, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}),
                 200
               )

      export_conn =
        call(viewer_conn, :export, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"})

      assert export_conn.status == 200

      assert json_response(call(viewer_conn, :create, sample_check_doc("second-check")), 403)["error"] ==
               "forbidden"

      assert json_response(
               call(
                 viewer_conn,
                 :update,
                 %{"slug" => "checkout-api-health", "state" => "enabled"},
                 %{"slug" => "checkout-api-health"}
               ),
               403
             )["error"] == "forbidden"

      assert json_response(
               call(viewer_conn, :delete, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}),
               403
             )["error"] == "forbidden"

      assert json_response(call(viewer_conn, :import_check, sample_check_doc("second-check")), 403)["error"] ==
               "forbidden"

      assert json_response(call(viewer_conn, :test_run_inline, sample_check_doc()), 403)["error"] ==
               "forbidden"

      assert json_response(
               call(viewer_conn, :test_run, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}),
               403
             )["error"] == "forbidden"
    end

    test "evaluator with only declarative_checks.evaluate can test-run but cannot mutate checks",
         %{conn: operator_conn} do
      assert json_response(call(operator_conn, :create, sample_check_doc()), 201)

      eval_conn =
        assign(build_conn(), :current_scope, scope_with_permissions(["declarative_checks.evaluate"]))

      assert %{"data" => %{"ephemeral" => true}} =
               json_response(call(eval_conn, :test_run_inline, sample_check_doc()), 200)

      assert %{"data" => %{"ephemeral" => true, "slug" => "checkout-api-health"}} =
               json_response(
                 call(eval_conn, :test_run, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}),
                 200
               )

      assert json_response(call(eval_conn, :create, sample_check_doc("other-check")), 403)["error"] ==
               "forbidden"
    end
  end

  describe "CRUD and managed check detach protection" do
    test "creates, lists with filters, fetches bindings summary, updates, and deletes a check",
         %{conn: conn} do
      payload =
        sample_check_doc()
        |> Map.put("state", "enabled")
        |> Map.put("credential_bindings", [
          %{"slot" => "api_auth", "credential_secret_id" => @secret_uuid}
        ])

      create_conn = call(conn, :create, payload)
      assert get_resp_header(create_conn, "etag") != []
      created = json_response(create_conn, 201)["data"]
      assert created["slug"] == "checkout-api-health"
      assert is_binary(created["template_fingerprint"])
      assert [%{"slot" => "api_auth", "binding_kind" => "secret"}] = created["credential_bindings"]

      assert %{"data" => [%{"slug" => "checkout-api-health"}]} =
               json_response(call(conn, :index, %{"state" => "enabled"}), 200)

      assert %{"data" => []} =
               json_response(call(conn, :index, %{"state" => "disabled"}), 200)

      assert json_response(call(conn, :index, %{"state" => "invalid-state"}), 400)["error"] ==
               "invalid_request"

      fetched =
        conn
        |> call(:show, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"})
        |> json_response(200)
        |> Map.fetch!("data")

      assert fetched["instance_rollup"] == %{
               "total" => 1,
               "healthy" => 1,
               "degraded" => 0,
               "down" => 0,
               "unknown" => 0
             }

      deleted_conn =
        call(conn, :delete, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"})

      assert response(deleted_conn, 204) == ""

      assert call(conn, :show, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"}).status ==
               404
    end

    test "managed checks preserve fingerprint on parameter_overrides/ui_layout edits and require confirm_detach for structural edits",
         %{conn: conn} do
      managed_doc = sample_managed_pack_doc("1.0.0")
      created = json_response(call(conn, :create, managed_doc), 201)["data"]
      original_fp = created["template_fingerprint"]
      assert created["managed"] == true

      tuned =
        conn
        |> call(
          :update,
          %{
            "slug" => managed_doc["slug"],
            "parameter_overrides" => %{"warn_percent" => 80.0},
            "ui_layout" => %{"nodes" => %{"posture_1" => %{"x" => 120, "y" => 160}}}
          },
          %{"slug" => managed_doc["slug"]}
        )
        |> json_response(200)
        |> Map.fetch!("data")

      assert tuned["managed"] == true
      assert tuned["template_fingerprint"] == original_fp
      assert tuned["parameter_overrides"] == %{"warn_percent" => 80.0}

      modified_nodes =
        Enum.map(managed_doc["nodes"], fn node ->
          if node["id"] == "posture_1", do: Map.put(node, "label", "Custom Edited Label"), else: node
        end)

      blocked =
        conn
        |> call(
          :update,
          %{"slug" => managed_doc["slug"], "nodes" => modified_nodes},
          %{"slug" => managed_doc["slug"]}
        )
        |> json_response(422)

      assert blocked["error"] == "managed_detach_confirmation_required"

      detached =
        conn
        |> call(
          :update,
          %{
            "slug" => managed_doc["slug"],
            "nodes" => modified_nodes,
            "confirm_detach" => true
          },
          %{"slug" => managed_doc["slug"]}
        )
        |> json_response(200)
        |> Map.fetch!("data")

      assert detached["managed"] == false
      assert detached["template_fingerprint"] != original_fp
    end
  end

  describe "deterministic secret-free export" do
    test "exports sorted-key schema_version 1 JSON omitting local UUIDs and credential bindings",
         %{conn: conn} do
      payload =
        Map.put(sample_check_doc(), "credential_bindings", [
          %{"slot" => "api_auth", "credential_secret_id" => @secret_uuid}
        ])

      assert json_response(call(conn, :create, payload), 201)

      export_1 =
        call(conn, :export, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"})

      export_2 =
        call(conn, :export, %{"slug" => "checkout-api-health"}, %{"slug" => "checkout-api-health"})

      assert export_1.status == 200
      assert export_1.resp_body == export_2.resp_body
      assert [disposition] = get_resp_header(export_1, "content-disposition")
      assert disposition =~ "checkout-api-health.declarative-check.json"

      refute export_1.resp_body =~ @secret_uuid
      refute export_1.resp_body =~ "credential_secret_id"
      refute export_1.resp_body =~ "credential_rule_id"
      refute export_1.resp_body =~ "credential_bindings"

      decoded = Jason.decode!(export_1.resp_body)
      assert decoded["schema_version"] == 1
      assert decoded["slug"] == "checkout-api-health"
      assert [%{"slot" => "api_auth", "provider" => "http_bearer"}] = decoded["credential_slots"]
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "validated import, dry_run, and managed fingerprint reconciliation" do
    test "rejects secret-bearing import payloads with 422 without persisting data", %{conn: conn} do
      with_password =
        put_in(
          sample_check_doc("secret-leak-check"),
          ["nodes", Access.at(0), "config", "password"],
          "synthetic-placeholder"
        )

      resp_1 = json_response(call(conn, :import_check, %{"document" => with_password}), 422)
      assert resp_1["error"] == "secret_guard_violation"
      assert Enum.any?(resp_1["errors"], &(&1["code"] == "secret_forbidden"))

      with_secret_id = Map.put(sample_check_doc("secret-id-check"), "credential_secret_id", @secret_uuid)
      resp_2 = json_response(call(conn, :import_check, %{"document" => with_secret_id}), 422)
      assert resp_2["error"] == "secret_guard_violation"

      with_bearer =
        put_in(
          sample_check_doc("bearer-leak-check"),
          ["nodes", Access.at(0), "config", "headers"],
          %{"Authorization" => "Bearer synthetic-only"}
        )

      resp_3 = json_response(call(conn, :import_check, %{"document" => with_bearer}), 422)
      assert resp_3["error"] == "secret_guard_violation"

      assert %{"data" => []} = json_response(call(conn, :index, %{}), 200)
    end

    test "rejects cyclic DAGs with 422 schema_validation_failed", %{conn: conn} do
      cyclic =
        Map.put(sample_check_doc("cyclic-check"), "edges", [
          %{
            "id" => "e1",
            "source" => "http_1",
            "source_handle" => "signal",
            "target" => "out_1",
            "target_handle" => "in"
          },
          %{
            "id" => "e2",
            "source" => "out_1",
            "source_handle" => "out",
            "target" => "http_1",
            "target_handle" => "in"
          }
        ])

      resp = json_response(call(conn, :import_check, %{"document" => cyclic}), 422)
      assert resp["error"] == "schema_validation_failed"
      assert Enum.any?(resp["errors"], &(&1["code"] == "cycle_detected"))
    end

    test "supports dry_run without persisting and reconciles managed upgrades while preserving parameter_overrides",
         %{conn: conn} do
      pack_v1 = sample_managed_pack_doc("1.0.0")

      dry =
        conn
        |> call(:import_check, %{"document" => pack_v1, "dry_run" => true})
        |> json_response(200)
        |> Map.fetch!("data")

      assert dry["action"] == "dry_run"
      assert dry["dry_run"] == true
      assert is_nil(dry["check"])
      assert call(conn, :show, %{"slug" => pack_v1["slug"]}, %{"slug" => pack_v1["slug"]}).status == 404

      imported_v1 =
        conn
        |> call(:import_check, %{"document" => pack_v1, "dry_run" => false})
        |> json_response(200)
        |> Map.fetch!("data")

      assert imported_v1["action"] == "created"
      v1_fp = imported_v1["template_fingerprint"]

      _tuned =
        conn
        |> call(
          :update,
          %{
            "slug" => pack_v1["slug"],
            "parameter_overrides" => %{"warn_percent" => 78.5}
          },
          %{"slug" => pack_v1["slug"]}
        )
        |> json_response(200)

      pack_v2 =
        "1.1.0"
        |> sample_managed_pack_doc()
        |> put_in(["schedule", "interval_seconds"], 180)

      upgraded =
        conn
        |> call(:import_check, pack_v2)
        |> json_response(200)
        |> Map.fetch!("data")

      assert upgraded["action"] == "updated"
      assert upgraded["template_fingerprint"] != v1_fp
      assert upgraded["preserved_parameter_overrides"] == %{"warn_percent" => 78.5}
      assert upgraded["check"]["pack_version"] == "1.1.0"
      assert upgraded["check"]["parameter_overrides"] == %{"warn_percent" => 78.5}
      assert upgraded["check"]["schedule"]["interval_seconds"] == 180
    end
  end

  describe "ephemeral test-run endpoints" do
    test "executes inline check document without persisting or leaking secrets even when body contains slug",
         %{conn: conn} do
      inline_doc = sample_check_doc("ephemeral-unsaved-check")

      result =
        conn
        |> call(:test_run_inline, inline_doc)
        |> json_response(200)
        |> Map.fetch!("data")

      assert result["ephemeral"] == true
      assert result["slug"] == "ephemeral-unsaved-check"
      assert result["status"] == "healthy"
      assert [%{"node_id" => "http_1", "resolved_inputs" => resolved} | _] = result["node_traces"]
      assert resolved["credential_slot"] == "[REDACTED]"

      assert call(
               conn,
               :show,
               %{"slug" => "ephemeral-unsaved-check"},
               %{"slug" => "ephemeral-unsaved-check"}
             ).status == 404
    end

    test "executes saved check by slug with parameter_overrides and returns 404 when slug is unknown",
         %{conn: conn} do
      assert json_response(call(conn, :create, sample_managed_pack_doc("1.0.0")), 201)

      result =
        conn
        |> call(
          :test_run,
          %{
            "slug" => "storage-entitlement-utilization",
            "parameter_overrides" => %{"warn_percent" => 82.0}
          },
          %{"slug" => "storage-entitlement-utilization"}
        )
        |> json_response(200)
        |> Map.fetch!("data")

      assert result["ephemeral"] == true
      assert result["slug"] == "storage-entitlement-utilization"

      assert [%{"resolved_inputs" => %{"effective_overrides" => %{"warn_percent" => 82.0}}} | _] =
               result["node_traces"]

      assert call(conn, :test_run, %{"slug" => "missing-check"}, %{"slug" => "missing-check"}).status ==
               404
    end
  end

  describe "real ServiceRadar.DeclarativeChecks wiring (db_free)" do
    test "controller invokes real Importer secret-guard, dry_run, and TestRunner", %{conn: conn} do
      Application.delete_env(:serviceradar_web_ng, :declarative_checks)

      secret_doc =
        put_in(
          sample_managed_pack_doc("1.0.0"),
          ["nodes", Access.at(0), "config", "secret_access_key"],
          "synthetic-test-only"
        )

      rejected =
        conn
        |> call(:import_check, %{"document" => secret_doc, "dry_run" => true})
        |> json_response(422)

      assert rejected["error"] == "secret_guard_violation"
      assert Enum.any?(rejected["errors"], &(&1["code"] == "secret_forbidden"))

      dry_res =
        conn
        |> call(:import_check, %{"document" => sample_managed_pack_doc("1.0.0"), "dry_run" => true})
        |> json_response(200)
        |> Map.fetch!("data")

      assert dry_res["action"] == "dry_run"
      assert dry_res["dry_run"] == true
      assert String.length(dry_res["template_fingerprint"]) == 64

      decision_doc = %{
        "schema_version" => 1,
        "slug" => "multi-vantage-inline",
        "name" => "Synthetic Multi-Vantage Decision Check",
        "state" => "draft",
        "schedule" => %{"interval_seconds" => 60, "timeout_seconds" => 15, "jitter_seconds" => 0},
        "target_binding" => %{"mode" => "singleton"},
        "inputs" => [],
        "credential_slots" => [],
        "nodes" => [
          %{
            "id" => "vp_1",
            "kind" => "vantage_point",
            "label" => "Agent A Vantage",
            "config" => %{"agent_id" => "agent-synthetic-a", "max_age_seconds" => 300}
          },
          %{
            "id" => "dt_1",
            "kind" => "decision_table",
            "label" => "Vantage Decision",
            "config" => %{
              "inputs" => [
                %{"key" => "probe_a", "source_node_id" => "vp_1", "max_age_seconds" => 300}
              ],
              "rules" => [
                %{"match" => %{"probe_a" => "healthy"}, "status" => "healthy", "verdict" => "up"},
                %{"match" => %{"probe_a" => "*"}, "status" => "unknown", "verdict" => "stale"}
              ]
            }
          },
          %{
            "id" => "out_1",
            "kind" => "alert_output",
            "label" => "Final Verdict",
            "config" => %{
              "verdict_map" => %{
                "healthy" => "up",
                "degraded" => "degraded",
                "down" => "down",
                "unknown" => "stale"
              }
            }
          }
        ],
        "edges" => [
          %{
            "id" => "e0",
            "source" => "vp_1",
            "source_handle" => "signal",
            "target" => "dt_1",
            "target_handle" => "in"
          },
          %{
            "id" => "e1",
            "source" => "dt_1",
            "source_handle" => "verdict",
            "target" => "out_1",
            "target_handle" => "in"
          }
        ],
        "alert_policy" => %{"emit_ocsf_transition" => false, "open_on_statuses" => ["down"]}
      }

      run_res =
        conn
        |> call(:test_run_inline, %{
          "document" => decision_doc,
          "edge_observations" => %{
            "vp_1" => %{
              "status" => "healthy",
              "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
            }
          }
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert run_res["ephemeral"] == true
      assert run_res["slug"] == "multi-vantage-inline"
      assert is_list(run_res["node_traces"])
      assert length(run_res["node_traces"]) == 3
    end
  end

  defp call(conn, action, params, path_params \\ %{}) do
    Controller.call(
      %{conn | params: params, path_params: path_params},
      Controller.init(action)
    )
  end

  defp scope_with_permissions(perms) do
    %Scope{
      user: %{id: @user_id, email: "operator@example.com", role: :operator},
      permissions: MapSet.new(perms)
    }
  end

  defp sample_check_doc(slug \\ "checkout-api-health") do
    %{
      "schema_version" => 1,
      "slug" => slug,
      "name" => "Synthetic Checkout API Health",
      "description" => "Synthetic HTTP check fixture using example.com.",
      "state" => "draft",
      "schedule" => %{
        "interval_seconds" => 60,
        "timeout_seconds" => 15,
        "jitter_seconds" => 5
      },
      "target_binding" => %{
        "mode" => "singleton"
      },
      "inputs" => [],
      "credential_slots" => [
        %{
          "slot" => "api_auth",
          "provider" => "http_bearer",
          "role" => "reader",
          "purpose" => "synthetic_http",
          "required" => true
        }
      ],
      "nodes" => [
        %{
          "id" => "http_1",
          "kind" => "http_request",
          "label" => "GET Health Endpoint",
          "config" => %{
            "url" => "https://api.example.com/v1/health",
            "method" => "GET",
            "credential_slot" => "api_auth"
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "Checkout Health Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "ok",
              "degraded" => "slow",
              "down" => "unreachable",
              "unknown" => "unknown"
            }
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "http_1",
          "source_handle" => "verdict",
          "target" => "out_1",
          "target_handle" => "in"
        }
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down"],
        "priority" => 2
      }
    }
  end

  defp sample_managed_pack_doc(pack_version) do
    %{
      "schema_version" => 1,
      "slug" => "storage-entitlement-utilization",
      "name" => "Storage Entitlement Utilization",
      "description" => "Monitors SaaS recordings entitlement utilization and hard-cap state.",
      "state" => "enabled",
      "pack_id" => "io.serviceradar.storage-and-nvr-health",
      "pack_version" => pack_version,
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
          "max" => 100.0
        },
        %{
          "key" => "crit_percent",
          "type" => "number",
          "default" => 95.0,
          "min" => 1.0,
          "max" => 100.0
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
            "crit" => %{"op" => ">=", "value" => "{{inputs.crit_percent}}"}
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
        "priority" => 2
      }
    }
  end
end
