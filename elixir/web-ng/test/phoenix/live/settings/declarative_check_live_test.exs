defmodule ServiceRadarWebNGWeb.Settings.DeclarativeCheckLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.TestSupport.DeclarativeChecksStub
  alias ServiceRadarWebNGWeb.AgentLive.Show, as: AgentShowLive
  alias ServiceRadarWebNGWeb.Router
  alias ServiceRadarWebNGWeb.ServiceLive.Show, as: ServiceShowLive
  alias ServiceRadarWebNGWeb.Settings.Catalog
  alias ServiceRadarWebNGWeb.Settings.CompositeChecksLive.Index, as: CompositeChecksIndexLive
  alias ServiceRadarWebNGWeb.Settings.DeclarativeCheckLive.Edit, as: EditLive
  alias ServiceRadarWebNGWeb.Settings.DeclarativeCheckLive.Index, as: IndexLive
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialInventoryComponents
  alias ServiceRadarWebNGWeb.Settings.StatusCards

  @moduletag :db_free

  @user_uuid "00000000-0000-4000-8000-000000000801"
  @secret_uuid "00000000-0000-4000-8000-000000000802"
  @legacy_check_uuid "00000000-0000-4000-8000-000000000803"
  @legacy_composite_uuid "00000000-0000-4000-8000-000000000804"

  defmodule DisconnectedGuardBackend do
    @moduledoc false

    def list_checks(_opts), do: raise("disconnected mount must not call list_checks/1")
    def get_check(_slug, _opts), do: raise("disconnected mount must not call get_check/2")

    def list_credential_options(_opts), do: raise("disconnected mount must not call list_credential_options/1")

    def supported_posture_evaluators do
      [
        "storage.entitlement_utilization",
        "storage.hold_pin_pressure",
        "storage.archive_credential_and_usage_health",
        "camera.continuous_recording_silence"
      ]
    end
  end

  setup do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    previous = Application.get_env(:serviceradar_web_ng, :declarative_checks)
    Application.put_env(:serviceradar_web_ng, :declarative_checks, DeclarativeChecksStub)
    DeclarativeChecksStub.reset!()

    DeclarativeChecksStub.put_credential_options!(%{
      secrets: [
        %{id: @secret_uuid, name: "Synthetic API Token", provider: "http_bearer"}
      ],
      rules: []
    })

    on_exit(fn ->
      DeclarativeChecksStub.reset!()

      if previous do
        Application.put_env(:serviceradar_web_ng, :declarative_checks, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :declarative_checks)
      end
    end)

    :ok
  end

  describe "router wiring and Settings.Catalog integration" do
    test "resolves /settings/declarative-checks, /new, and /:slug LiveView routes" do
      assert %{
               phoenix_live_view: {IndexLive, :index, _, _}
             } =
               Phoenix.Router.route_info(
                 Router,
                 "GET",
                 "/settings/declarative-checks",
                 "localhost"
               )

      assert %{
               phoenix_live_view: {EditLive, :new, _, _}
             } =
               Phoenix.Router.route_info(
                 Router,
                 "GET",
                 "/settings/declarative-checks/new",
                 "localhost"
               )

      assert %{
               phoenix_live_view: {EditLive, :edit, _, _}
             } =
               Phoenix.Router.route_info(
                 Router,
                 "GET",
                 "/settings/declarative-checks/checkout-api-health",
                 "localhost"
               )
    end

    test "Settings.Catalog exposes :declarative_checks to viewers, managers, and evaluators" do
      viewer = scope_with_permissions(["declarative_checks.view"])
      unpermitted = scope_with_permissions(["devices.view"])

      view = Catalog.view_for_path("/settings/declarative-checks")
      assert view.id == :declarative_checks
      assert view.route == "/settings/declarative-checks"
      assert Catalog.visible_view?(viewer, view)
      refute Catalog.visible_view?(unpermitted, view)
    end
  end

  describe "disconnected mount Iron Law and RBAC authorization" do
    test "denies users lacking declarative_checks.* permissions on both Index and Edit" do
      unpermitted = scope_with_permissions(["devices.view"])

      assert {:ok, redirected_index} = IndexLive.mount(%{}, %{}, base_socket(unpermitted))
      assert {:live, :redirect, %{to: "/settings/profile"}} = redirected_index.redirected
      assert Phoenix.Flash.get(redirected_index.assigns.flash, :error) =~ "Not authorized"

      assert {:ok, redirected_edit} = EditLive.mount(%{}, %{}, base_socket(unpermitted, :edit))
      assert {:live, :redirect, %{to: "/settings/profile"}} = redirected_edit.redirected
      assert Phoenix.Flash.get(redirected_edit.assigns.flash, :error) =~ "Not authorized"
    end

    test "disconnected mount performs zero backend reads on Index and Edit" do
      scope = manager_scope()

      disconnected_index =
        scope
        |> base_socket()
        |> assign(:declarative_checks_backend, DisconnectedGuardBackend)

      assert {:ok, mounted_index} = IndexLive.mount(%{}, %{}, disconnected_index)
      assert mounted_index.assigns.loading? == true
      assert mounted_index.assigns.checks == []
      assert render_index(mounted_index) =~ "Loading declarative checks..."

      disconnected_edit =
        scope
        |> base_socket(:edit)
        |> assign(:declarative_checks_backend, DisconnectedGuardBackend)

      assert {:ok, mounted_edit} = EditLive.mount(%{}, %{}, disconnected_edit)

      assert {:noreply, params_edit} =
               EditLive.handle_params(%{"slug" => "checkout-api-health"}, "", mounted_edit)

      assert params_edit.assigns.loading? == true
      assert render_edit(params_edit) =~ "Loading declarative check builder..."
    end

    test "viewer with declarative_checks.view can view list, open builder read-only, and export JSON, but cannot mutate or test-run" do
      {:ok, _} = DeclarativeChecksStub.create_check(sample_check_doc())
      viewer = scope_with_permissions(["declarative_checks.view"])

      index_socket = mount_connected_index(viewer)
      html = render_index(index_socket)

      assert html =~ "Synthetic Checkout API Health"
      assert html =~ "Targets: 1"
      refute html =~ "new-declarative-check-btn"
      refute html =~ "open-import-declarative-check-btn"
      refute html =~ "toggle-check-checkout-api-health"
      refute html =~ "delete-check-checkout-api-health"

      assert {:noreply, denied_toggle} =
               IndexLive.handle_event(
                 "toggle_state",
                 %{"slug" => "checkout-api-health", "next_state" => "enabled"},
                 index_socket
               )

      assert Phoenix.Flash.get(denied_toggle.assigns.flash, :error) =~ "permission"

      assert {:noreply, exported_socket} =
               IndexLive.handle_event(
                 "export_check",
                 %{"slug" => "checkout-api-health"},
                 index_socket
               )

      assert exported_socket.assigns.exported_json_preview.slug == "checkout-api-health"
      assert exported_socket.assigns.exported_json_preview.json =~ ~s("schema_version": 1)

      new_socket = mount_connected_edit(viewer, :new, %{})
      assert {:live, :redirect, %{to: "/settings/declarative-checks"}} = new_socket.redirected

      edit_socket = mount_connected_edit(viewer, :edit, %{"slug" => "checkout-api-health"})
      edit_html = render_edit(edit_socket)
      assert edit_html =~ "declarative-check-canvas"
      assert edit_html =~ ~s(&quot;canManage&quot;:false)
      assert edit_html =~ ~s(&quot;canEvaluate&quot;:false)
      refute edit_html =~ "header-save-check-btn"
      refute edit_html =~ "header-test-run-btn"

      assert {:noreply, denied_save} = EditLive.handle_event("save_check", %{}, edit_socket)
      assert Phoenix.Flash.get(denied_save.assigns.flash, :error) =~ "permission"

      assert {:noreply, denied_eval} = EditLive.handle_event("run_test", %{}, edit_socket)

      assert Phoenix.Flash.get(denied_eval.assigns.flash, :error) =~
               "declarative_checks.evaluate"
    end
  end

  describe "DeclarativeCheckLive.Index list, state toggle, JSON export, and JSON import dry_run" do
    test "filters checks, toggles state, exports secret-free JSON, and deletes checks" do
      {:ok, _} =
        DeclarativeChecksStub.create_check(
          Map.put(sample_check_doc(), "credential_bindings", [
            %{"slot" => "api_auth", "credential_secret_id" => @secret_uuid}
          ])
        )

      {:ok, _} = DeclarativeChecksStub.create_check(sample_managed_pack_doc("1.0.0"))

      socket = mount_connected_index(manager_scope())
      html = render_index(socket)

      assert html =~ "checkout-api-health"
      assert html =~ "storage-entitlement-utilization"
      assert html =~ "Managed -- io.serviceradar.storage-and-nvr-health@1.0.0"

      {:noreply, filtered} =
        IndexLive.handle_event(
          "filter_checks",
          %{"state" => "enabled", "pack_id" => "io.serviceradar.storage-and-nvr-health"},
          socket
        )

      assert Enum.map(filtered.assigns.checks, & &1["slug"]) == [
               "storage-entitlement-utilization"
             ]

      {:noreply, reset_filter} =
        IndexLive.handle_event("filter_checks", %{"state" => "all", "pack_id" => ""}, filtered)

      {:noreply, toggled} =
        IndexLive.handle_event(
          "toggle_state",
          %{"slug" => "checkout-api-health", "next_state" => "enabled"},
          reset_filter
        )

      assert {:ok, updated} = DeclarativeChecksStub.get_check("checkout-api-health")
      assert updated["state"] == "enabled"

      {:noreply, exported} =
        IndexLive.handle_event("export_check", %{"slug" => "checkout-api-health"}, toggled)

      exported_json = exported.assigns.exported_json_preview.json
      refute exported_json =~ @secret_uuid
      refute exported_json =~ "credential_secret_id"
      refute exported_json =~ "credential_bindings"
      assert Jason.decode!(exported_json)["slug"] == "checkout-api-health"

      {:noreply, after_delete} =
        IndexLive.handle_event("delete_check", %{"slug" => "checkout-api-health"}, exported)

      refute Enum.any?(after_delete.assigns.checks, &(&1["slug"] == "checkout-api-health"))
      assert {:error, :not_found} = DeclarativeChecksStub.get_check("checkout-api-health")
    end

    test "JSON import modal validates secret-free guard, previews dry_run without persisting, and applies import" do
      socket = mount_connected_index(manager_scope())

      {:noreply, modal_open} = IndexLive.handle_event("open_import_modal", %{}, socket)
      assert modal_open.assigns.import_modal_open == true
      assert render_index(modal_open) =~ "declarative-check-import-modal"

      secret_bearing_json =
        "forbidden-secret-check"
        |> sample_check_doc()
        |> put_in(["nodes", Access.at(0), "config", "api_key"], "synthetic-forbidden-value")
        |> Jason.encode!()

      {:noreply, rejected} =
        IndexLive.handle_event(
          "preview_import",
          %{"import" => %{"json" => secret_bearing_json}},
          modal_open
        )

      assert rejected.assigns.import_preview == nil
      assert Enum.any?(rejected.assigns.import_errors, &(&1.code == "secret_forbidden"))
      assert render_index(rejected) =~ "declarative-check-import-errors"
      assert {:error, :not_found} = DeclarativeChecksStub.get_check("forbidden-secret-check")

      valid_json = Jason.encode!(sample_managed_pack_doc("1.2.0"))

      {:noreply, changed} =
        IndexLive.handle_event(
          "change_import_form",
          %{"import" => %{"json" => valid_json, "force_overwrite" => "false"}},
          rejected
        )

      {:noreply, dry_preview} = IndexLive.handle_event("preview_import_current", %{}, changed)
      assert dry_preview.assigns.import_preview["action"] == "dry_run"
      assert render_index(dry_preview) =~ "declarative-check-import-preview"

      assert {:error, :not_found} =
               DeclarativeChecksStub.get_check("storage-entitlement-utilization")

      {:noreply, imported} =
        IndexLive.handle_event(
          "confirm_import",
          %{"import" => %{"json" => valid_json, "force_overwrite" => "false"}},
          dry_preview
        )

      assert imported.assigns.import_modal_open == false
      assert {:ok, stored} = DeclarativeChecksStub.get_check("storage-entitlement-utilization")
      assert stored["pack_version"] == "1.2.0"
    end
  end

  describe "DeclarativeCheckLive.Edit create, Test Run, and managed pack detach workflow" do
    test "built-in starter document validates cleanly against SchemaValidator" do
      socket = mount_connected_edit(manager_scope(), :new, %{})

      assert {:ok, validated} =
               SchemaValidator.validate_document(socket.assigns.document, skip_srql_nif?: true)

      assert validated["schema_version"] == 1
      assert validated["slug"] == "http-json-api-check"
    end

    test "creates a new check with credential bindings and executes ephemeral Test Run with scrubbed secrets" do
      socket = mount_connected_edit(manager_scope(), :new, %{})
      doc = sample_check_doc("synthetic-portal-check")
      bindings = [%{"slot" => "api_auth", "credential_secret_id" => @secret_uuid}]

      {:noreply, changed} =
        EditLive.handle_event(
          "canvas_change",
          %{"document" => doc, "credential_bindings" => bindings},
          socket
        )

      assert changed.assigns.dirty == true

      {:noreply, tested} =
        EditLive.handle_event(
          "run_test",
          %{"document" => doc, "parameter_overrides" => %{"timeout_ms" => 2500}},
          changed
        )

      assert tested.assigns.test_run_result["ephemeral"] == true
      assert tested.assigns.test_run_result["status"] == "healthy"
      test_html = render_edit(tested)
      assert test_html =~ "declarative-check-test-run-summary"
      assert test_html =~ "[REDACTED]"
      assert {:error, :not_found} = DeclarativeChecksStub.get_check("synthetic-portal-check")

      {:noreply, saved} =
        EditLive.handle_event(
          "save_check",
          %{"document" => doc, "credential_bindings" => bindings},
          tested
        )

      assert saved.assigns.mode == :edit
      assert saved.assigns.slug == "synthetic-portal-check"
      assert saved.assigns.dirty == false

      assert {:live, :patch, %{to: "/settings/declarative-checks/synthetic-portal-check"}} =
               saved.redirected

      assert {:ok, persisted} = DeclarativeChecksStub.get_check("synthetic-portal-check")
      assert [%{"slot" => "api_auth", "binding_kind" => "secret"}] = persisted["credential_bindings"]
    end

    test "managed Solution Pack check allows parameter_overrides edits and prompts confirm-detach on structural edits" do
      managed_doc = sample_managed_pack_doc("1.0.0")
      {:ok, created} = DeclarativeChecksStub.create_check(managed_doc)
      original_fp = created["template_fingerprint"]

      socket =
        mount_connected_edit(manager_scope(), :edit, %{
          "slug" => "storage-entitlement-utilization"
        })

      tuned_doc =
        socket.assigns.document
        |> Map.put("parameter_overrides", %{"warn_percent" => 80.0})
        |> Map.put("ui_layout", %{"nodes" => %{"posture_1" => %{"x" => 150, "y" => 200}}})

      {:noreply, saved_override} =
        EditLive.handle_event("save_check", %{"document" => tuned_doc}, socket)

      assert saved_override.assigns.detach_prompt_open == false
      assert saved_override.assigns.document["managed"] == true

      assert {:ok, still_managed} =
               DeclarativeChecksStub.get_check("storage-entitlement-utilization")

      assert still_managed["managed"] == true
      assert still_managed["template_fingerprint"] == original_fp
      assert still_managed["parameter_overrides"] == %{"warn_percent" => 80.0}

      mutated_nodes =
        Enum.map(saved_override.assigns.document["nodes"], fn node ->
          if node["id"] == "posture_1",
            do: Map.put(node, "label", "Custom Operator Posture Node"),
            else: node
        end)

      structural_doc = Map.put(saved_override.assigns.document, "nodes", mutated_nodes)

      {:noreply, prompt_open} =
        EditLive.handle_event("save_check", %{"document" => structural_doc}, saved_override)

      assert prompt_open.assigns.detach_prompt_open == true
      assert render_edit(prompt_open) =~ "managed-detach-confirmation-banner"

      {:noreply, cancelled} = EditLive.handle_event("cancel_detach_prompt", %{}, prompt_open)
      assert cancelled.assigns.detach_prompt_open == false

      {:noreply, re_prompted} =
        EditLive.handle_event("save_check", %{"document" => structural_doc}, cancelled)

      {:noreply, detached_saved} =
        EditLive.handle_event("confirm_detach_and_save", %{}, re_prompted)

      assert detached_saved.assigns.detach_prompt_open == false
      assert detached_saved.assigns.document["managed"] == false

      assert {:ok, detached} =
               DeclarativeChecksStub.get_check("storage-entitlement-utilization")

      assert detached["managed"] == false
      assert detached["template_fingerprint"] != original_fp
    end
  end

  describe "legacy clone actions and CredentialUsage deep-links" do
    test "AgentLive.Show and ServiceLive.Show clone legacy service checks as draft declarative checks without mutating source" do
      legacy_service_check = %{
        id: @legacy_check_uuid,
        name: "Edge Portal HTTPS Probe",
        check_type: :http,
        target: "https://portal.example.com/healthz",
        interval_seconds: 60,
        timeout_seconds: 10,
        enabled: true,
        config: %{"method" => "GET"}
      }

      agent_socket = %Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: manager_scope(),
          checks: [legacy_service_check]
        }
      }

      assert {:noreply, cloned_agent_socket} =
               AgentShowLive.handle_event(
                 "clone_as_declarative_check",
                 %{"id" => @legacy_check_uuid},
                 agent_socket
               )

      assert {:live, :redirect, %{to: "/settings/declarative-checks/edge-portal-https-probe"}} =
               cloned_agent_socket.redirected

      assert {:ok, cloned} = DeclarativeChecksStub.get_check("edge-portal-https-probe")
      assert cloned["state"] == "draft"
      assert legacy_service_check.enabled == true

      service_socket = %Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: manager_scope(),
          service: %{
            "service_name" => "Core API TCP Check",
            "service_type" => "tcp",
            "target" => "api.example.com:443"
          }
        }
      }

      assert {:noreply, cloned_service_socket} =
               ServiceShowLive.handle_event("clone_as_declarative_check", %{}, service_socket)

      assert {:live, :redirect, %{to: "/settings/declarative-checks/core-api-tcp-check"}} =
               cloned_service_socket.redirected

      assert {:ok, cloned_tcp} = DeclarativeChecksStub.get_check("core-api-tcp-check")
      assert cloned_tcp["state"] == "draft"
    end

    test "CompositeChecksLive.Index clones legacy composite check with vantage inputs and rules into decision_table draft" do
      legacy_composite = %{
        id: @legacy_composite_uuid,
        name: "Camera VLAN Isolation Proof",
        slug: "camera-vlan-isolation-proof",
        description: "Synthetic composite isolation check.",
        scope_query: "in:devices tags.role:camera",
        evaluation_interval_seconds: 300,
        severity: :high,
        inputs: [
          %{
            key: "inside_vp",
            kind: :vantage_point,
            agent_id: "agent-synthetic-inside",
            max_age_seconds: 600,
            position: 0
          },
          %{
            key: "outside_vp",
            kind: :vantage_point,
            agent_id: "agent-synthetic-outside",
            max_age_seconds: 600,
            position: 1
          }
        ],
        rules: [
          %{
            position: 0,
            verdict: "isolated",
            alert: false,
            match: %{"inside_vp" => "reachable", "outside_vp" => "unreachable"}
          },
          %{
            position: 1,
            verdict: "exposed",
            alert: true,
            match: %{"inside_vp" => "*", "outside_vp" => "reachable"}
          }
        ]
      }

      composite_socket = %Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: manager_scope(),
          editing: legacy_composite,
          checks: [%{check: legacy_composite, rollup: nil, scope_count: 2}],
          rules: legacy_composite.rules
        }
      }

      assert {:noreply, cloned_socket} =
               CompositeChecksIndexLive.handle_event(
                 "clone_as_declarative_check",
                 %{"id" => @legacy_composite_uuid},
                 composite_socket
               )

      assert {:live, :redirect, %{to: "/settings/declarative-checks/camera-vlan-isolation-proof"}} =
               cloned_socket.redirected

      assert {:ok, cloned} = DeclarativeChecksStub.get_check("camera-vlan-isolation-proof")
      assert cloned["state"] == "draft"
      assert Enum.any?(cloned["nodes"], &(&1["kind"] == "decision_table"))
    end

    test "CredentialInventoryComponents renders navigable /settings/declarative-checks/:id link and EditLive resolves check UUID" do
      {:ok, created} =
        DeclarativeChecksStub.create_check(
          Map.put(sample_check_doc(), "credential_bindings", [
            %{"slot" => "api_auth", "credential_secret_id" => @secret_uuid}
          ])
        )

      check_uuid = created["id"]

      usage_result = %Result{
        consumers: [
          %Consumer{
            kind: :declarative_check,
            id: check_uuid,
            label: "Synthetic Checkout API Health",
            slot: "api_auth"
          }
        ],
        live_grants: []
      }

      secret = %{
        id: @secret_uuid,
        name: "Synthetic API Token",
        description: "Synthetic token for unit test",
        provider: "http_bearer",
        credential_kind: :api_token,
        source_type: :internal_encrypted,
        rotation_state: :active,
        username: nil,
        metadata: %{"auth_method" => "api_token"}
      }

      table_html =
        rendered_to_string(
          CredentialInventoryComponents.credential_inventory_table(%{
            loading?: false,
            secrets: [secret],
            focused_credential_id: nil,
            integration_profiles: %{},
            usage_by_id: %{@secret_uuid => usage_result}
          })
        )

      assert table_html =~ "/settings/declarative-checks/#{check_uuid}"
      assert table_html =~ "Edit declarative check Synthetic Checkout API Health"
      assert table_html =~ "1 declarative check"

      resolved_socket = mount_connected_edit(manager_scope(), :edit, %{"slug" => check_uuid})
      assert resolved_socket.assigns.slug == "checkout-api-health"
      assert resolved_socket.assigns.document["name"] == "Synthetic Checkout API Health"
    end
  end

  defp mount_connected_index(scope) do
    socket = assign(base_socket(scope), :force_connected_load?, true)
    {:ok, mounted} = IndexLive.mount(%{}, %{}, socket)
    mounted
  end

  defp mount_connected_edit(scope, live_action, params) do
    socket = assign(base_socket(scope, live_action), :force_connected_load?, true)
    {:ok, mounted} = EditLive.mount(params, %{}, socket)

    if mounted.redirected do
      mounted
    else
      {:noreply, after_params} = EditLive.handle_params(params, "", mounted)
      after_params
    end
  end

  defp base_socket(scope, live_action \\ :index) do
    path = "/settings/declarative-checks"
    view = Catalog.view_for_path(path)
    category = Catalog.category_for_view(view)

    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      router: Router,
      view: if(live_action == :index, do: IndexLive, else: EditLive),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: live_action,
        current_scope: scope,
        settings_active_view: view,
        settings_active_category: category,
        settings_breadcrumbs: Catalog.breadcrumbs_for_path(path),
        settings_nav_tree: %{
          categories: Catalog.visible_categories(scope),
          groups: Catalog.nav_tree(scope, category.id)
        },
        settings_palette: Catalog.palette_index(scope),
        settings_stats: StatusCards.for_view(view)
      }
    }
  end

  defp render_index(%Socket{} = socket) do
    socket.assigns
    |> IndexLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render_edit(%Socket{} = socket) do
    socket.assigns
    |> EditLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp manager_scope do
    scope_with_permissions([
      "declarative_checks.view",
      "declarative_checks.manage",
      "declarative_checks.evaluate"
    ])
  end

  defp scope_with_permissions(perms) do
    %Scope{
      user: %{id: @user_uuid, email: "operator@example.com", timezone: "Etc/UTC"},
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
