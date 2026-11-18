defmodule ServiceRadar.DeclarativeChecks.CanonicalJsonAndValidatorTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DeclarativeChecks
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.Exporter
  alias ServiceRadar.DeclarativeChecks.Importer
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Identity.RBAC.Catalog

  defp sample_http_check_doc(overrides \\ %{}) do
    base = %{
      "schema_version" => 1,
      "slug" => "synthetic-portal-health",
      "name" => "Synthetic Portal Health",
      "description" => "Synthetic HTTP health check against example.com",
      "state" => "enabled",
      "pack_id" => "io.serviceradar.synthetic-example",
      "pack_version" => "1.0.0",
      "managed" => true,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => 60,
        "timeout_seconds" => 10,
        "jitter_seconds" => 5
      },
      "target_binding" => %{"mode" => "singleton"},
      "inputs" => [
        %{
          "key" => "warn_ms",
          "type" => "integer",
          "default" => 400,
          "min" => 10,
          "max" => 30_000
        }
      ],
      "credential_slots" => [
        %{
          "slot" => "portal_api",
          "provider" => "generic_http",
          "role" => "bearer",
          "required" => true
        }
      ],
      "nodes" => [
        %{
          "id" => "http_1",
          "kind" => "http_request",
          "label" => "GET /healthz",
          "config" => %{
            "method" => "GET",
            "url" => "https://example.com/healthz",
            "credential_slot" => "portal_api",
            "timeout_ms" => 5_000
          }
        },
        %{
          "id" => "ext_1",
          "kind" => "extract_field",
          "label" => "Extract Latency",
          "config" => %{
            "source_type" => "jsonpath",
            "expression" => "$.metrics.latency_ms",
            "output_key" => "api_latency_ms",
            "cast" => "float"
          }
        },
        %{
          "id" => "assert_1",
          "kind" => "threshold_assert",
          "label" => "Latency Threshold",
          "config" => %{
            "field" => "api_latency_ms",
            "warn" => %{"op" => ">=", "value" => "{{inputs.warn_ms}}"},
            "crit" => %{"op" => ">=", "value" => 2_000}
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "Portal Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "portal_healthy",
              "degraded" => "portal_slow",
              "down" => "portal_down",
              "unknown" => "portal_unknown"
            }
          }
        }
      ],
      "edges" => [
        %{"id" => "e1", "source" => "http_1", "target" => "ext_1"},
        %{"id" => "e2", "source" => "ext_1", "target" => "assert_1"},
        %{"id" => "e3", "source" => "assert_1", "target" => "out_1"}
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down", "degraded"],
        "priority" => "p2"
      },
      "ui_layout" => %{
        "nodes" => %{"http_1" => %{"x" => 10, "y" => 20}}
      }
    }

    Map.merge(base, overrides)
  end

  describe "RBAC catalog (1.5)" do
    test "declares declarative_checks.view, manage, and evaluate with expected role grants" do
      viewer_perms = Catalog.permissions_for_role(:viewer)
      operator_perms = Catalog.permissions_for_role(:operator)
      admin_perms = Catalog.permissions_for_role(:admin)

      assert "declarative_checks.view" in viewer_perms
      refute "declarative_checks.manage" in viewer_perms
      refute "declarative_checks.evaluate" in viewer_perms

      assert "declarative_checks.view" in operator_perms
      assert "declarative_checks.manage" in operator_perms
      assert "declarative_checks.evaluate" in operator_perms

      assert "declarative_checks.view" in admin_perms
      assert "declarative_checks.manage" in admin_perms
      assert "declarative_checks.evaluate" in admin_perms
    end
  end

  describe "CanonicalJSON and template_fingerprint (1.4)" do
    test "produces byte-identical canonical JSON regardless of input map key ordering" do
      doc_a = sample_http_check_doc()

      doc_b =
        doc_a
        |> Enum.reverse()
        |> Map.new()
        |> Map.put("schedule", %{
          "jitter_seconds" => 5,
          "timeout_seconds" => 10,
          "interval_seconds" => 60
        })

      assert {:ok, json_a} = Exporter.export_json(doc_a, actor: SystemActor.system(:test))
      assert {:ok, json_b} = Exporter.export_json(doc_b, actor: SystemActor.system(:test))
      assert json_a == json_b
      refute json_a =~ "credential_secret_id"
      refute json_a =~ "credential_rule_id"
    end

    test "template_fingerprint is invariant across operator parameter_overrides, ui_layout, and state" do
      doc_base = sample_http_check_doc()

      doc_tuned =
        sample_http_check_doc(%{
          "state" => "disabled",
          "parameter_overrides" => %{"warn_ms" => 750},
          "ui_layout" => %{"nodes" => %{"http_1" => %{"x" => 400, "y" => 320}}}
        })

      assert CanonicalJSON.compute_template_fingerprint(doc_base) ==
               CanonicalJSON.compute_template_fingerprint(doc_tuned)
    end

    test "template_fingerprint changes when DAG structure changes" do
      doc_base = sample_http_check_doc()

      doc_modified =
        sample_http_check_doc(%{
          "edges" => [
            %{"id" => "e1", "source" => "http_1", "target" => "assert_1"},
            %{"id" => "e2", "source" => "assert_1", "target" => "out_1"}
          ],
          "nodes" => Enum.reject(doc_base["nodes"], &(&1["id"] == "ext_1"))
        })

      refute CanonicalJSON.compute_template_fingerprint(doc_base) ==
               CanonicalJSON.compute_template_fingerprint(doc_modified)
    end
  end

  describe "SchemaValidator secret-free preflight and DAG validation (1.4)" do
    test "rejects embedded secret keys, credential UUID keys, Authorization headers, and URL userinfo" do
      with_password =
        put_in(
          sample_http_check_doc(),
          ["nodes", Access.at(0), "config", "password"],
          "example-value"
        )

      assert {:error, %{kind: :secret_guard, errors: [err | _]}} =
               SchemaValidator.validate_document(with_password, skip_srql_nif?: true)

      assert err.code == "secret_forbidden"
      assert err.path =~ "password"

      with_secret_uuid =
        Map.put(
          sample_http_check_doc(),
          "credential_secret_id",
          "00000000-0000-0000-0000-000000000001"
        )

      assert {:error, %{kind: :secret_guard}} =
               SchemaValidator.validate_document(with_secret_uuid, skip_srql_nif?: true)

      with_auth_header =
        put_in(
          sample_http_check_doc(),
          ["nodes", Access.at(0), "config", "headers"],
          %{"Authorization" => "Basic dXNlcjpwYXNz"}
        )

      assert {:error, %{kind: :secret_guard}} =
               SchemaValidator.validate_document(with_auth_header, skip_srql_nif?: true)

      with_userinfo_url =
        put_in(
          sample_http_check_doc(),
          ["nodes", Access.at(0), "config", "url"],
          "https://operator:pass@example.com/healthz"
        )

      assert {:error, %{kind: :secret_guard}} =
               SchemaValidator.validate_document(with_userinfo_url, skip_srql_nif?: true)
    end

    test "rejects cyclic DAGs and names the cycle nodes and edges" do
      cyclic =
        sample_http_check_doc(%{
          "edges" => [
            %{"id" => "e1", "source" => "http_1", "target" => "ext_1"},
            %{"id" => "e2", "source" => "ext_1", "target" => "assert_1"},
            %{"id" => "e_back", "source" => "assert_1", "target" => "ext_1"},
            %{"id" => "e3", "source" => "assert_1", "target" => "out_1"}
          ]
        })

      assert {:error, %{kind: :schema_validation, errors: errors}} =
               SchemaValidator.validate_document(cyclic, skip_srql_nif?: true)

      cycle_err = Enum.find(errors, &(&1.code == "cyclic_graph"))
      assert cycle_err
      assert cycle_err.message =~ "ext_1"
      assert cycle_err.message =~ "assert_1"
      assert cycle_err.message =~ "e_back"
    end

    test "rejects unknown keys, incompatible handles, and decision tables without a catch-all row" do
      unknown_top = Map.put(sample_http_check_doc(), "unexpected_field", true)

      assert {:error, %{kind: :schema_validation, errors: errs1}} =
               SchemaValidator.validate_document(unknown_top, skip_srql_nif?: true)

      assert Enum.any?(errs1, &(&1.code == "unknown_field"))

      bad_handle =
        sample_http_check_doc(%{
          "edges" => [
            %{
              "id" => "e1",
              "source" => "http_1",
              "source_handle" => "bogus",
              "target" => "ext_1"
            },
            %{"id" => "e2", "source" => "ext_1", "target" => "assert_1"},
            %{"id" => "e3", "source" => "assert_1", "target" => "out_1"}
          ]
        })

      assert {:error, %{kind: :schema_validation, errors: errs_handle}} =
               SchemaValidator.validate_document(bad_handle, skip_srql_nif?: true)

      assert Enum.any?(errs_handle, &(&1.code == "incompatible_handle"))

      bad_dt = %{
        "schema_version" => 1,
        "slug" => "dt-missing-catchall",
        "name" => "Decision Table Missing Catch-All",
        "state" => "draft",
        "nodes" => [
          %{
            "id" => "q_1",
            "kind" => "srql_query",
            "config" => %{"query" => "in:devices", "limit" => 10}
          },
          %{
            "id" => "dt_1",
            "kind" => "decision_table",
            "config" => %{
              "inputs" => [%{"key" => "q", "source_node_id" => "q_1", "max_age_seconds" => 120}],
              "rules" => [
                %{"match" => %{"q" => "healthy"}, "status" => "healthy", "verdict" => "ok"}
              ]
            }
          },
          %{"id" => "out_1", "kind" => "alert_output", "config" => %{}}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "q_1", "target" => "dt_1"},
          %{"id" => "e2", "source" => "dt_1", "target" => "out_1"}
        ]
      }

      assert {:error, %{kind: :schema_validation, errors: errs2}} =
               SchemaValidator.validate_document(bad_dt, skip_srql_nif?: true)

      assert Enum.any?(errs2, &(&1.code == "missing_catch_all"))
    end
  end

  describe "Exporter, Importer dry_run, and Scope RBAC authorization (1.4, 1.5)" do
    test "enforces view and manage permissions from web-ng scope maps without DB access" do
      viewer_scope = %{
        user: %{id: "u-viewer", email: "viewer@example.com", role: :viewer},
        permissions: MapSet.new(["declarative_checks.view"])
      }

      operator_scope = %{
        user: %{id: "u-operator", email: "operator@example.com", role: :operator},
        permissions: MapSet.new(["declarative_checks.view", "declarative_checks.manage"])
      }

      unprivileged_scope = %{
        user: %{id: "u-none", email: "none@example.com", role: :viewer},
        permissions: MapSet.new([])
      }

      doc = sample_http_check_doc()

      assert {:ok, exported} = Exporter.export_map(doc, scope: viewer_scope)
      assert exported["slug"] == "synthetic-portal-health"
      refute Map.has_key?(exported, "id")

      assert {:error, %Forbidden{}} = Exporter.export_map(doc, scope: unprivileged_scope)

      assert {:error, %Forbidden{}} =
               Importer.import_document(doc, scope: viewer_scope, dry_run: true)

      assert {:ok, %{action: :dry_run, dry_run: true, template_fingerprint: fp}} =
               Importer.import_document(doc,
                 scope: operator_scope,
                 dry_run: true,
                 skip_srql_nif?: true
               )

      assert String.length(fp) == 64

      serialized =
        DeclarativeChecks.serialize_check(doc,
          credential_bindings: [
            %{
              id: "00000000-0000-0000-0000-000000000010",
              slot: "portal_api",
              credential_secret_id: "00000000-0000-0000-0000-000000000020",
              credential_rule_id: nil
            }
          ]
        )

      assert [%{"slot" => "portal_api", "binding_kind" => "secret"}] =
               serialized["credential_bindings"]
    end
  end
end
