defmodule ServiceRadarWebNGWeb.Admin.PluginPackageDetailsModalTest do
  @moduledoc false

  # Regression test for https://github.com/carverauto/serviceradar/issues/338:
  # viewing a plugin package whose manifest carries integrations
  # credential profiles (an api_token and an ssh_private_key auth method with
  # ssh_host_key_policies) crashed the detail view because details_modal
  # read @current_scope without receiving it.
  #
  # Renders Index.render/1 directly with a fabricated package so the test runs
  # in the database-free tier. Fails with KeyError :current_scope without the
  # fix, passes with it.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.CredentialCoverage
  alias ServiceRadarWebNGWeb.Admin.PluginPackageLive.Index

  @moduletag :unit
  @moduletag :db_free

  # Compact manifest with the salient shape from the issue: one credential
  # profile offering an api_token method and an ssh_private_key method that
  # carries ssh_host_key_policies.
  @manifest %{
    "id" => "proxmox-inventory",
    "description" => "Enriches Proxmox PVE hosts and guests using the Proxmox VE REST API",
    "entrypoint" => "run_check",
    "capabilities" => ["get_config", "log", "submit_result", "emit_telemetry", "http_request"],
    "permissions" => %{"allowed_domains" => [], "allowed_ports" => [8006]},
    "resources" => %{
      "requested_memory_mb" => 256,
      "requested_cpu_ms" => 10_000,
      "max_open_connections" => 2
    },
    "integrations" => %{
      "credential_profiles" => [
        %{
          "provider" => "proxmox",
          "label" => "Proxmox VE",
          "description" => "Inventory enrichment and explicitly authorized remote console access for Proxmox VE.",
          "default" => true,
          "auth_methods" => [
            %{
              "id" => "proxmox_api_token",
              "label" => "API token",
              "credential_kind" => "api_token",
              "tls_policies" => ["verify"],
              "fields" => [
                %{
                  "id" => "user",
                  "label" => "User",
                  "control" => "text",
                  "required" => true,
                  "secret" => false,
                  "public" => true,
                  "default" => "root"
                },
                %{
                  "id" => "token_secret",
                  "label" => "Token secret",
                  "control" => "password",
                  "required" => true,
                  "secret" => true,
                  "public" => false
                }
              ],
              "payload" => %{
                "format" => "template",
                "template" => "{{user}}@{{realm}}!{{token_id}}={{token_secret}}",
                "username_field" => "user"
              }
            },
            %{
              "id" => "ssh_private_key",
              "label" => "SSH private key",
              "credential_kind" => "ssh_private_key",
              "ssh_host_key_policies" => ["known_hosts", "trust_on_first_use"],
              "fields" => [
                %{
                  "id" => "username",
                  "label" => "Username",
                  "control" => "text",
                  "required" => true,
                  "secret" => false,
                  "public" => true,
                  "default" => "root"
                },
                %{
                  "id" => "private_key",
                  "label" => "Private key",
                  "control" => "textarea",
                  "required" => true,
                  "secret" => true,
                  "public" => false
                }
              ],
              "payload" => %{"format" => "json", "username_field" => "username"}
            }
          ]
        }
      ]
    }
  }

  @config_schema %{
    "type" => "object",
    "properties" => %{
      "timeout_ms" => %{"type" => "integer", "title" => "Timeout", "default" => 30_000},
      "include_guests" => %{"type" => "boolean", "title" => "Include guests", "default" => true}
    }
  }

  setup do
    ensure_endpoint_started()
    :ok
  end

  test "renders the detail modal for a manifest with api_token and ssh_private_key methods" do
    package = package_fixture()
    assigns = assigns_fixture(package)

    html =
      assigns
      |> Index.render()
      |> rendered_to_string()

    assert html =~ "Proxmox Inventory"
    assert html =~ "proxmox-inventory"
    assert html =~ "Version 0.1.6"
    # Manifest JSON (HTML-escaped) carries both auth methods.
    assert html =~ "proxmox_api_token"
    assert html =~ "ssh_private_key"
    assert html =~ "ssh_host_key_policies"
    # Display contract key, config schema, and every modal section render.
    assert html =~ "com.carverauto.proxmox.resource_event.display@1.0.0"
    assert html =~ "Timeout"
    assert html =~ "Upload Wasm Blob"
    assert html =~ "Wasm Package Requests"
    assert html =~ "Version History"
    assert html =~ "Assign to Agent"
    # The crashed sites render user timezone-aware timestamps.
    assert html =~ "Etc/UTC"
  end

  defp package_fixture do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    struct(PluginPackage,
      id: "ff70cbe8-2807-457d-b146-4500d61a4096",
      plugin_id: "proxmox-inventory",
      name: "Proxmox Inventory",
      version: "0.1.6",
      description: "Enriches Proxmox PVE hosts and guests using the Proxmox VE REST API",
      entrypoint: "run_check",
      runtime: "wasi-preview1",
      outputs: "serviceradar.plugin_result.v1",
      manifest: @manifest,
      config_schema: @config_schema,
      display_contract: %{},
      display_contracts: %{
        "com.carverauto.proxmox.resource_event.display@1.0.0" => %{
          "surface" => "signal",
          "schema_id" => "com.carverauto.proxmox.resource_event"
        }
      },
      signal_schemas: [],
      producer_schedules: [],
      alert_rules: [],
      snmp_requirements: [],
      status: :approved,
      source_type: :first_party,
      approved_capabilities: [],
      approved_permissions: %{},
      approved_resources: %{},
      content_hash: "abc123",
      signature: %{},
      gpg_key_id: nil,
      # A verified package exercises the GPG user_time branch too.
      gpg_verified_at: now,
      verification_status: "verified",
      source_release_tag: "v1.2.3",
      source_oci_ref: "example",
      source_oci_digest: "sha256:abc",
      source_bundle_digest: "sha256:def",
      wasm_object_key: nil,
      inserted_at: now,
      updated_at: now,
      approved_at: now
    )
  end

  defp assigns_fixture(package) do
    scope = %{user: %{email: "probe@example.com", role: :admin, timezone: "Etc/UTC"}}

    %{
      flash: %{},
      current_scope: scope,
      current_path: "/settings/agents/plugins/#{package.id}",
      plugins_base_path: "/settings/agents/plugins",
      settings_active_view: nil,
      settings_active_category: nil,
      settings_breadcrumbs: [],
      settings_nav_tree: %{categories: [], groups: []},
      settings_palette: [],
      settings_stats: [],
      page_title: "Plugins",
      can_stage_plugins: true,
      can_approve_plugins: true,
      can_assign_plugins: true,
      can_reconcile_credential_rules: true,
      can_manage_repositories: false,
      packages: [package],
      catalog_packages: [package],
      package_page: 1,
      package_page_size: 10,
      filter_status: nil,
      filter_source_type: nil,
      first_party_catalog: [],
      first_party_catalog_all: [],
      first_party_catalog_page: 1,
      first_party_catalog_page_size: 10,
      first_party_catalog_error: nil,
      first_party_catalog_status: nil,
      first_party_release_options: [],
      first_party_release_tag: nil,
      first_party_release_selected?: false,
      plugin_repositories: [],
      enabled_plugin_repositories: [],
      selected_repository: nil,
      first_party_repo_url: nil,
      capacity_rows: [],
      capacity_totals: %{assignments: 0, cpu_ms: 0, memory_mb: 0, connections: 0},
      show_repository_modal: false,
      repository_form: %{},
      repository_errors: [],
      editing_repository_id: nil,
      import_running?: false,
      show_create_modal: false,
      show_details_modal: true,
      create_form: %{"manifest_yaml" => ""},
      create_errors: [],
      selected_package: package,
      review_form: %{
        "approved_capabilities" => "",
        "approved_permissions" => "",
        "approved_resources" => ""
      },
      assignment_form: %{
        "agent_uid" => "",
        "interval_seconds" => "60",
        "timeout_seconds" => "10",
        "params" => "",
        "params_raw" => "",
        "permissions_override" => "",
        "resources_override" => ""
      },
      assignments: [],
      authenticated_partition_preview: nil,
      recovery_confirmation: nil,
      policy_recovery_polls: %{},
      legacy_recovery_candidate_page: 1,
      legacy_recovery_candidate_after_ids: %{1 => nil},
      legacy_recovery_candidates_more?: false,
      legacy_recovery_candidates: [],
      credential_fields: CredentialCoverage.materialized_fields(package.config_schema),
      credential_coverage: nil,
      assignment_coverage: %{},
      versions: [package],
      agents: [],
      verification_policy: %{require_gpg_for_github: false, allow_unsigned_uploads: true},
      upload_url: nil,
      upload_token: nil,
      upload_expires_at: nil,
      download_url: nil,
      download_token: nil,
      download_expires_at: nil,
      blob_present: nil,
      upload_errors: [],
      uploads: %{
        wasm_blob:
          struct(Phoenix.LiveView.UploadConfig,
            ref: "phx-test",
            name: "wasm_blob",
            accept: ".wasm",
            entries: [],
            auto_upload?: false,
            max_entries: 1
          )
      }
    }
  end

  defp ensure_endpoint_started do
    case ServiceRadarWebNGWeb.Endpoint.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
