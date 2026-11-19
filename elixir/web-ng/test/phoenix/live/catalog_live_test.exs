defmodule ServiceRadarWebNGWeb.CatalogLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Catalog.SvgSanitizer
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.CatalogLive.Index, as: CatalogLive
  alias ServiceRadarWebNGWeb.Components.PackProvenanceComponents
  alias ServiceRadarWebNGWeb.Router
  alias ServiceRadarWebNGWeb.Settings.Catalog, as: SettingsCatalog

  @moduletag :db_free

  @user_uuid "00000000-0000-4000-8000-000000000901"
  @secret_uuid "00000000-0000-4000-8000-000000000902"
  @rule_uuid "00000000-0000-4000-8000-000000000903"
  @repo_gitops_uuid "00000000-0000-4000-8000-000000000905"

  defmodule DisconnectedGuardBackend do
    @moduledoc false
    def list_packs(_opts), do: raise("disconnected mount must not call list_packs/1")
    def list_repositories(_opts), do: raise("disconnected mount must not call list_repositories/1")
    def list_credential_options(_opts), do: raise("disconnected mount must not call list_credential_options/1")
  end

  defmodule CatalogStub do
    @moduledoc false

    def reset! do
      :persistent_term.put({__MODULE__, :state}, initial_state())
    end

    def state do
      :persistent_term.get({__MODULE__, :state}, initial_state())
    end

    def update_state(fun) do
      next = fun.(state())
      :persistent_term.put({__MODULE__, :state}, next)
      next
    end

    def initial_state do
      {:ok, icon_uri} =
        SvgSanitizer.sanitize_icon(
          ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><script>alert(1)</script><rect x="4" y="4" width="40" height="40" fill="#0ea5e9" onload="evil()"/></svg>|
        )

      {:ok, readme} =
        SvgSanitizer.sanitize_markdown(
          "# Storage & NVR Health\n\nMonitors archive entitlement.\n<script>alert('xss')</script>\n- 4 checks"
        )

      %{
        packs: [
          %{
            "id" => "io.serviceradar.storage-and-nvr-health",
            "slug" => "storage-and-nvr-health",
            "name" => "Storage Entitlements & NVR Recording Health",
            "version" => "0.2.0",
            "author" => "ServiceRadar",
            "description" => "Monitors archive storage entitlement quota and NVR camera recording silence.",
            "categories" => ["Storage & NVR", "Infrastructure"],
            "icon" => icon_uri,
            "source_type" => "builtin",
            "installed" => true,
            "installed_version" => "0.1.0",
            "available_version" => "0.2.0",
            "update_available" => true,
            "counts" => %{"checks" => 4, "rules" => 2, "dashboards" => 1},
            "config" => [
              %{
                "key" => "utilization_warn_pct",
                "type" => "number",
                "default" => 85,
                "min" => 1,
                "max" => 100,
                "description" => "Warning threshold percent"
              },
              %{
                "key" => "silence_window_minutes",
                "type" => "integer",
                "default" => 15,
                "min" => 5,
                "max" => 1440,
                "description" => "Recording silence window"
              }
            ],
            "credential_slots" => [
              %{
                "slot" => "nvr_api_token",
                "provider" => "generic_http",
                "role" => "bearer_token",
                "purpose" => "Authenticate synthetic NVR health probe",
                "required" => true
              }
            ],
            "plugin_dependencies" => [
              %{
                "package_id" => "io.example.nvr-probe",
                "version_constraint" => ">= 0.1.0",
                "required" => false
              }
            ],
            "manifest" => %{"pack_format_version" => 1, "id" => "io.serviceradar.storage-and-nvr-health"},
            "readme" => readme,
            "assets" => [],
            "checks" => [
              %{
                "slug" => "storage-entitlement-utilization",
                "file" => "checks/entitlement-utilization.json",
                "document" => %{
                  "slug" => "storage-entitlement-utilization",
                  "name" => "Storage Entitlement Utilization",
                  "nodes" => [
                    %{"id" => "n1", "kind" => "platform_posture"},
                    %{"id" => "n2", "kind" => "threshold_assert"}
                  ],
                  "edges" => [%{"from" => "n1", "to" => "n2"}]
                }
              }
            ],
            "rules" => [
              %{
                "name" => "storage_entitlement_hard_cap",
                "kind" => "stateful_alert_rule",
                "install_state" => "paused",
                "file" => "rules/storage-hard-cap-alert.json",
                "document" => %{"name" => "storage_entitlement_hard_cap"}
              }
            ],
            "dashboards" => [
              %{
                "slug" => "storage-and-nvr-overview",
                "file" => "dashboards/storage-and-nvr-overview.json",
                "document" => %{"slug" => "storage-and-nvr-overview", "title" => "Storage & NVR Overview", "panels" => []}
              }
            ],
            "installed_record" => %{"config_values" => %{"utilization_warn_pct" => 80}}
          },
          %{
            "id" => "io.serviceradar.wan-edge-sla",
            "slug" => "wan-edge-sla",
            "name" => "WAN Edge Synthetic SLA",
            "version" => "0.1.0",
            "author" => "ServiceRadar",
            "description" => "Synthetic HTTP and DNS latency monitoring for WAN edges.",
            "categories" => ["Network & WAN", "Synthetic HTTP"],
            "icon" => icon_uri,
            "source_type" => "release_catalog",
            "installed" => false,
            "installed_version" => nil,
            "available_version" => "0.1.0",
            "update_available" => false,
            "counts" => %{"checks" => 2, "rules" => 1, "dashboards" => 1},
            "config" => [],
            "credential_slots" => [],
            "plugin_dependencies" => [],
            "manifest" => %{"pack_format_version" => 1, "id" => "io.serviceradar.wan-edge-sla"},
            "readme" => "# WAN Edge SLA",
            "assets" => [],
            "checks" => [],
            "rules" => [],
            "dashboards" => []
          }
        ],
        repositories: [
          %{
            "id" => "00000000-0000-4000-8000-000000000904",
            "name" => "ServiceRadar Official Solution Packs",
            "mode" => "release_catalog",
            "provider_type" => "github",
            "repo_url" => "https://github.com/carverauto/serviceradar",
            "branch" => "main",
            "base_path" => "packs",
            "push_strategy" => "pull_request",
            "builtin" => true,
            "enabled" => true,
            "last_sync_error" => nil
          },
          %{
            "id" => "00000000-0000-4000-8000-000000000905",
            "name" => "Example Private GitOps Packs",
            "mode" => "gitops_tree",
            "provider_type" => "github",
            "repo_url" => "https://github.com/example-org/serviceradar-packs",
            "branch" => "main",
            "base_path" => "packs",
            "push_strategy" => "pull_request",
            "builtin" => false,
            "enabled" => true,
            "last_sync_error" => nil
          }
        ],
        last_install_params: nil,
        last_push: nil,
        last_pull: nil
      }
    end

    def list_packs(_opts), do: {:ok, state().packs}

    def get_pack(slug, _opts) do
      case Enum.find(state().packs, &(&1["slug"] == slug or &1["id"] == slug)) do
        nil -> {:error, :not_found}
        pack -> {:ok, pack}
      end
    end

    def list_repositories(_opts), do: {:ok, state().repositories}

    def list_credential_options(_opts) do
      %{
        secrets: [
          %{
            "id" => "00000000-0000-4000-8000-000000000902",
            "name" => "Synthetic PAT Secret",
            "provider" => "generic_http",
            "credential_kind" => "api_token"
          }
        ],
        rules: [
          %{
            "id" => "00000000-0000-4000-8000-000000000903",
            "name" => "NVR API Rule",
            "provider" => "generic_http"
          }
        ]
      }
    end

    def check_dependencies(deps, _opts) do
      {:ok,
       %{
         ready?: true,
         blocking_count: 0,
         review_path: "/settings/agents/plugins",
         dependencies:
           Enum.map(deps, fn dep ->
             %{
               package_id: dep["package_id"],
               version_constraint: dep["version_constraint"],
               required: dep["required"] != false,
               status: :satisfied,
               matched_version: "0.1.2",
               review_path: nil,
               message: "Approved Wasm plugin satisfies constraint"
             }
           end)
       }}
    end

    def preview_install(slug, params, _opts) do
      decisions = Map.get(params, "decisions", %{})
      check_decision = Map.get(decisions, "check:storage-entitlement-utilization", "keep_customized")

      {:ok,
       %{
         pack_id: "io.serviceradar.storage-and-nvr-health",
         slug: slug,
         pack_version: "0.2.0",
         previous_version: "0.1.0",
         mode: :upgrade,
         config_values: Map.get(params, "config", %{}),
         has_diverged?: true,
         checks: [
           %{
             key: "check:storage-entitlement-utilization",
             slug: "storage-entitlement-utilization",
             action: String.to_atom(check_decision),
             diverged?: true,
             existing: %{"slug" => "storage-entitlement-utilization", "nodes" => [%{"id" => "custom"}]},
             active_doc: %{"slug" => "storage-entitlement-utilization", "nodes" => [%{"id" => "upstream_v2"}]}
           }
         ],
         rules: [
           %{
             key: "rule:stateful_alert_rule:storage_entitlement_hard_cap",
             name: "storage_entitlement_hard_cap",
             action: :upgrade,
             diverged?: false
           }
         ],
         dashboards: [
           %{
             key: "dashboard:storage-and-nvr-overview",
             slug: "storage-and-nvr-overview",
             action: :upgrade,
             diverged?: false
           }
         ]
       }}
    end

    def install_pack(_slug, params, _opts) do
      update_state(&Map.put(&1, :last_install_params, params))
      {:ok, %{status: :applied, pack_version: "0.2.0", config_values: params["config"]}}
    end

    def create_repository(attrs, _opts) do
      repo = %{
        "id" => "00000000-0000-4000-8000-000000000999",
        "name" => attrs["name"],
        "mode" => attrs["mode"] || "release_catalog",
        "provider_type" => attrs["provider_type"] || "github",
        "repo_url" => attrs["repo_url"],
        "branch" => attrs["branch"] || "main",
        "base_path" => attrs["base_path"] || "packs",
        "push_strategy" => attrs["push_strategy"] || "pull_request",
        "builtin" => false,
        "enabled" => true,
        "last_sync_error" => nil
      }

      update_state(&Map.update!(&1, :repositories, fn repos -> repos ++ [repo] end))
      {:ok, repo}
    end

    def test_repository(_id, _opts) do
      {:ok, %{"mode" => "gitops_tree", "pack_count" => 2, "commit_sha" => "abc12345"}}
    end

    def sync_repository(_id, _opts), do: {:ok, %{"pack_count" => 2}}

    def build_push_payload(slug, _spec, _opts), do: {:ok, %{"manifest.json" => ~s({"slug":"#{slug}"})}}

    def push_to_gitops(repo_id, _payload, opts) do
      result = %{
        commit_sha: "deadbeef1234",
        branch: "serviceradar/pack-storage-and-nvr-health-v0.2.0",
        pr_url: "https://github.com/example-org/serviceradar-packs/pull/42"
      }

      update_state(&Map.put(&1, :last_push, {repo_id, opts[:commit_message]}))
      {:ok, result}
    end

    def pull_from_gitops(repo_id, slug, opts) do
      dry_run? = Keyword.get(opts, :dry_run, true)
      update_state(&Map.put(&1, :last_pull, {repo_id, slug, dry_run?}))

      {:ok,
       %{
         pack_id: "io.serviceradar.#{slug}",
         pack_version: "0.2.0",
         source_commit_sha: "cafebabe9999",
         checks: [%{slug: "c1"}],
         rules: [%{name: "r1"}],
         dashboards: [%{slug: "d1"}]
       }}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :catalog_backend)
    Application.put_env(:serviceradar_web_ng, :catalog_backend, CatalogStub)
    CatalogStub.reset!()

    on_exit(fn ->
      if previous do
        Application.put_env(:serviceradar_web_ng, :catalog_backend, previous)
      else
        Application.delete_env(:serviceradar_web_ng, :catalog_backend)
      end
    end)

    :ok
  end

  describe "router wiring, Settings.Catalog, and Iron Law disconnected mount" do
    test "resolves /catalog, /catalog/:slug, and /settings/catalog routes" do
      assert %{phoenix_live_view: {CatalogLive, :index, _, _}} =
               Phoenix.Router.route_info(Router, "GET", "/catalog", "localhost")

      assert %{phoenix_live_view: {CatalogLive, :show, _, _}} =
               Phoenix.Router.route_info(Router, "GET", "/catalog/storage-and-nvr-health", "localhost")

      assert %{phoenix_live_view: {CatalogLive, :index, _, _}} =
               Phoenix.Router.route_info(Router, "GET", "/settings/catalog", "localhost")
    end

    test "Settings.Catalog exposes :solution_packs_catalog only to authorized catalog scopes" do
      viewer = scope_with_permissions(["catalog.view"])
      unpermitted = scope_with_permissions(["devices.view"])

      view = SettingsCatalog.view_for_path("/settings/catalog")
      assert view.id == :solution_packs_catalog
      assert SettingsCatalog.visible_view?(viewer, view)
      refute SettingsCatalog.visible_view?(unpermitted, view)
    end

    test "disconnected mount performs zero database calls" do
      Application.put_env(:serviceradar_web_ng, :catalog_backend, DisconnectedGuardBackend)

      socket = disconnected_socket(scope_with_permissions(["catalog.view"]))
      assert {:ok, mounted} = CatalogLive.mount(%{}, %{}, socket)
      assert mounted.assigns.loading? == true
      assert {:noreply, after_params} = CatalogLive.handle_params(%{}, "http://localhost/catalog", mounted)
      assert after_params.assigns.loading? == true
    end

    test "redirects users lacking catalog.* permissions on mount" do
      socket = connected_socket(scope_with_permissions(["devices.view"]))
      assert {:ok, redirected} = CatalogLive.mount(%{}, %{}, socket)
      assert redirected.redirected == {:live, :redirect, %{kind: :push, to: "/dashboard"}}
    end
  end

  describe "Catalog Gallery filtering, sanitization, and detail preview" do
    test "filters by category pill, search, source, and tabs; renders sanitized SVG and portal link" do
      socket = mount_connected(full_catalog_scope())
      html = render_html(socket)

      assert html =~ "https://developer.serviceradar.cloud/packs"
      assert html =~ "4 checks"
      assert html =~ "2 alert rules"
      assert html =~ "1 dashboards"
      assert html =~ "Storage Entitlements &amp; NVR Recording Health"
      assert html =~ "WAN Edge Synthetic SLA"
      refute html =~ "<script>"

      {:noreply, socket} = CatalogLive.handle_event("select_category", %{"category" => "Storage & NVR"}, socket)
      assert Enum.map(socket.assigns.filtered_packs, & &1["slug"]) == ["storage-and-nvr-health"]

      {:noreply, socket} = CatalogLive.handle_event("select_category", %{"category" => "all"}, socket)
      {:noreply, socket} = CatalogLive.handle_event("select_tab", %{"tab" => "updates"}, socket)
      assert Enum.map(socket.assigns.filtered_packs, & &1["slug"]) == ["storage-and-nvr-health"]

      {:noreply, socket} = CatalogLive.handle_event("select_tab", %{"tab" => "available"}, socket)
      assert Enum.map(socket.assigns.filtered_packs, & &1["slug"]) == ["wan-edge-sla"]

      {:noreply, socket} = CatalogLive.handle_event("select_tab", %{"tab" => "all"}, socket)
      {:noreply, socket} = CatalogLive.handle_event("search", %{"q" => "synthetic"}, socket)
      assert Enum.map(socket.assigns.filtered_packs, & &1["slug"]) == ["wan-edge-sla"]

      {:noreply, socket} = CatalogLive.handle_event("open_pack_detail", %{"slug" => "storage-and-nvr-health"}, socket)
      detail_html = render_html(socket)
      assert detail_html =~ "pack-detail-drawer"
      assert detail_html =~ "Monitors archive entitlement."
      refute detail_html =~ "alert(&#39;xss&#39;)"

      {:noreply, socket} = CatalogLive.handle_event("select_detail_tab", %{"tab" => "dag"}, socket)
      dag_html = render_html(socket)
      assert dag_html =~ "DeclarativeCheckCanvasHook"
      assert dag_html =~ "platform_posture"

      {:noreply, socket} = CatalogLive.handle_event("select_detail_tab", %{"tab" => "json"}, socket)
      assert render_html(socket) =~ "pack-manifest-json-inspector"
    end
  end

  describe "4-step guided install & upgrade wizard (0.1.0 -> 0.2.0)" do
    test "walks steps 1..4 preserving overrides and honoring Keep Forked vs Reset to Upstream" do
      socket = mount_connected(full_catalog_scope())

      {:noreply, socket} =
        CatalogLive.handle_event("open_install_wizard", %{"slug" => "storage-and-nvr-health"}, socket)

      assert socket.assigns.wizard.step == 1
      assert socket.assigns.wizard.config_values["utilization_warn_pct"] == "80"

      {:noreply, socket} =
        CatalogLive.handle_event(
          "wizard_update_config",
          %{"config" => %{"utilization_warn_pct" => "78", "silence_window_minutes" => "20"}},
          socket
        )

      {:noreply, socket} = CatalogLive.handle_event("wizard_next_step", %{}, socket)
      assert socket.assigns.wizard.step == 2
      step2_html = render_html(socket)
      assert step2_html =~ "/settings/networks/credentials"
      assert step2_html =~ "io.example.nvr-probe"

      {:noreply, socket} =
        CatalogLive.handle_event(
          "wizard_update_bindings",
          %{"bindings" => %{"nvr_api_token" => "rule:#{@rule_uuid}"}},
          socket
        )

      {:noreply, socket} = CatalogLive.handle_event("wizard_next_step", %{}, socket)
      assert socket.assigns.wizard.step == 3
      step3_html = render_html(socket)
      assert step3_html =~ "Keep Forked (managed: false)"
      assert step3_html =~ "Reset to Upstream"

      # Flip diverged check decision to reset_to_upstream and verify preview updates
      {:noreply, socket} =
        CatalogLive.handle_event(
          "wizard_set_decision",
          %{"key" => "check:storage-entitlement-utilization", "decision" => "reset_to_upstream"},
          socket
        )

      assert socket.assigns.wizard.decisions["check:storage-entitlement-utilization"] == "reset_to_upstream"

      {:noreply, socket} = CatalogLive.handle_event("wizard_apply_install", %{}, socket)
      assert socket.assigns.wizard.step == 4

      saved = CatalogStub.state().last_install_params
      assert saved["config"]["utilization_warn_pct"] == 78.0
      assert saved["config"]["silence_window_minutes"] == 20
      assert saved["credential_bindings"]["nvr_api_token"] == %{"credential_rule_id" => @rule_uuid}
      assert saved["decisions"]["check:storage-entitlement-utilization"] == "reset_to_upstream"
    end
  end

  describe "Repository modal, GitOps push/pull, and RBAC visibility" do
    test "viewer without catalog.repositories.manage does not see repository create/edit/remove controls" do
      socket = mount_connected(scope_with_permissions(["catalog.view"]))
      {:noreply, socket} = CatalogLive.handle_event("open_repositories_modal", %{}, socket)
      html = render_html(socket)

      assert html =~ "ServiceRadar Official Solution Packs"
      refute html =~ "catalog-repository-form"
      refute html =~ "save-catalog-repo-btn"
    end

    test "authorized admin creates repository, tests connection, pushes PR, and runs pull dry-run" do
      socket = mount_connected(full_catalog_scope())
      {:noreply, socket} = CatalogLive.handle_event("open_repositories_modal", %{}, socket)

      {:noreply, socket} =
        CatalogLive.handle_event(
          "save_repository",
          %{
            "repo" => %{
              "name" => "Staging GitOps",
              "mode" => "gitops_tree",
              "provider_type" => "gitlab",
              "repo_url" => "https://gitlab.example.com/ops/packs",
              "credential_secret_id" => @secret_uuid
            }
          },
          socket
        )

      assert Enum.any?(socket.assigns.repositories, &(&1["name"] == "Staging GitOps"))

      {:noreply, socket} = CatalogLive.handle_event("test_repository", %{"id" => @repo_gitops_uuid}, socket)
      assert socket.assigns.repo_test_result["commit_sha"] == "abc12345"

      {:noreply, socket} = CatalogLive.handle_event("open_gitops_push", %{"slug" => "storage-and-nvr-health"}, socket)

      {:noreply, socket} =
        CatalogLive.handle_event(
          "submit_gitops_push",
          %{
            "push" => %{
              "repository_id" => @repo_gitops_uuid,
              "pack_slug" => "storage-and-nvr-health",
              "commit_message" => "chore(packs): backup storage pack"
            }
          },
          socket
        )

      assert socket.assigns.gitops_push_result.pr_url =~ "/pull/42"

      {:noreply, socket} = CatalogLive.handle_event("open_gitops_pull", %{"id" => @repo_gitops_uuid}, socket)

      {:noreply, socket} =
        CatalogLive.handle_event(
          "preview_gitops_pull",
          %{"pull" => %{"slug" => "storage-and-nvr-health", "ref" => "main"}},
          socket
        )

      assert socket.assigns.gitops_pull_state.preview.source_commit_sha == "cafebabe9999"
      assert CatalogStub.state().last_pull == {@repo_gitops_uuid, "storage-and-nvr-health", true}

      {:noreply, socket} = CatalogLive.handle_event("apply_gitops_pull", %{}, socket)
      assert socket.assigns.gitops_pull_open == false
      assert CatalogStub.state().last_pull == {@repo_gitops_uuid, "storage-and-nvr-health", false}
    end
  end

  describe "PackProvenanceComponents" do
    test "renders managed provenance banner and structural-edit fork confirmation modal" do
      banner_html =
        rendered_to_string(
          PackProvenanceComponents.pack_provenance_banner(%{
            pack_id: "io.serviceradar.storage-and-nvr-health",
            pack_version: "0.1.0",
            managed: true,
            resource_kind: "alert rule",
            class: nil
          })
        )

      assert banner_html =~ "Managed Solution Pack"
      assert banner_html =~ "io.serviceradar.storage-and-nvr-health"
      assert banner_html =~ "managed: true"

      modal_html =
        rendered_to_string(
          PackProvenanceComponents.pack_fork_confirmation_modal(%{
            id: "test-fork-modal",
            open: true,
            resource_label: "alert rule",
            pack_id: "io.serviceradar.storage-and-nvr-health",
            pack_version: "0.1.0",
            allow_override_save: true,
            on_save_override: "save_override",
            on_confirm_fork: "confirm_fork",
            on_cancel: "cancel_fork"
          })
        )

      assert modal_html =~ "Save Parameter Override"
      assert modal_html =~ "Detach / Fork (managed: false)"
    end
  end

  defp full_catalog_scope do
    scope_with_permissions([
      "catalog.view",
      "catalog.packs.install",
      "catalog.packs.export",
      "catalog.repositories.manage",
      "catalog.gitops.sync"
    ])
  end

  defp scope_with_permissions(perms) do
    Scope.for_user(
      %{id: @user_uuid, email: "operator@example.com", role: :operator},
      permissions: MapSet.new(perms)
    )
  end

  defp disconnected_socket(scope) do
    assign(
      %Socket{endpoint: ServiceRadarWebNGWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}, live_action: :index}},
      :current_scope,
      scope
    )
  end

  defp connected_socket(scope) do
    assign(
      %Socket{
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        transport_pid: self(),
        assigns: %{__changed__: %{}, flash: %{}, live_action: :index}
      },
      :current_scope,
      scope
    )
  end

  defp mount_connected(scope) do
    socket = connected_socket(scope)
    {:ok, socket} = CatalogLive.mount(%{}, %{}, socket)
    {:noreply, socket} = CatalogLive.handle_params(%{}, "http://localhost/catalog", socket)
    socket
  end

  defp render_html(socket) do
    socket.assigns
    |> CatalogLive.render()
    |> rendered_to_string()
  end
end
