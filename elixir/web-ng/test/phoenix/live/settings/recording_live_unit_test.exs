defmodule ServiceRadarWebNGWeb.Settings.RecordingLiveUnitTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.NVRStorageSettings
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RecordingHealth
  alias ServiceRadar.Camera.RecordingHold
  alias ServiceRadar.Camera.RetentionCalculator
  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.CameraRecordingSettings
  alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
  alias ServiceRadarWebNGWeb.CameraLive.Show, as: CameraShowLive
  alias ServiceRadarWebNGWeb.Settings.Catalog
  alias ServiceRadarWebNGWeb.Settings.RecordingLive
  alias ServiceRadarWebNGWeb.Settings.StatusCards

  @moduletag :db_free

  setup do
    if !Process.whereis(ServiceRadarWebNGWeb.Endpoint) do
      start_supervised!(ServiceRadarWebNGWeb.Endpoint)
    end

    :ok
  end

  describe "mount/3 authorization and disconnected iron law" do
    test "denies users lacking all three recording permissions at mount" do
      unpermitted_scope = %Scope{
        user: %{
          id: "00000000-0000-4000-8000-000000000021",
          email: "viewer@example.com",
          timezone: "Etc/UTC"
        },
        permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
      }

      socket = base_socket(unpermitted_scope)
      assert {:ok, redirected} = RecordingLive.mount(%{}, %{}, socket)
      assert {:redirect, %{to: "/settings/profile"}} = redirected.redirected
      assert Phoenix.Flash.get(redirected.assigns.flash, :error) =~ "Not authorized"
    end

    test "disconnected mount performs zero runtime RPC or DB calls and renders cleanly" do
      forbidden_deps = %{
        runtime_status: fn -> flunk("disconnected mount must not call runtime RPC") end,
        list_archive_bindings: fn _ -> flunk("disconnected mount must not read bindings") end,
        list_enabled_s3_credentials: fn _ -> flunk("disconnected mount must not read secrets") end,
        load_archive_settings_view: fn _ -> flunk("disconnected mount must not read settings") end,
        load_retention_usage_summary: fn _ -> flunk("disconnected mount must not read retention usage") end,
        list_camera_sources: fn _ -> flunk("disconnected mount must not read cameras") end,
        list_policies: fn _ -> flunk("disconnected mount must not read policies") end,
        what_if_policy_preview: fn _, _, _ -> flunk("disconnected mount must not run DB what-if") end,
        list_storage_settings: fn _ -> flunk("disconnected mount must not read storage settings") end,
        fetch_nvr_member_statuses: fn _ -> flunk("disconnected mount must not probe NVR /v1/status") end,
        load_recording_health: fn _ -> flunk("disconnected mount must not read recording health") end
      }

      for perm <- [
            "settings.recording.view",
            "settings.recording.manage",
            "settings.recording.operate"
          ] do
        scope = scope_with_permissions([perm])
        socket = assign(base_socket(scope), :recording_deps, forbidden_deps)
        assert {:ok, mounted} = RecordingLive.mount(%{}, %{}, socket)
        refute mounted.redirected
        assert mounted.assigns.runtime.core_elx.reachability == :unknown

        html = render_mounted(mounted)
        assert html =~ "Recording &amp; Storage"
        assert html =~ "docs/nvr-runtime.md"
      end
    end
  end

  describe "explicit runtime, archive, and Stage B states" do
    test "not_installed state reports NVR is not installed and omits empty recorder/destination/block lists across roles" do
      runtime = %{
        recovery_gate: %{state: :not_configured, generation: nil},
        core_elx: %{
          reachability: :reachable,
          node: :"core-elx@example.internal",
          supervisor: :disabled,
          nvr_installation: :not_installed
        }
      }

      socket = mounted_with_runtime(scope_with_permissions(["settings.recording.view"]), runtime)
      html = render_mounted(socket)

      assert html =~ "NVR is not installed"
      assert html =~ "Not configured"
      assert html =~ "docs/nvr-runtime.md"
      refute html =~ "archive-destinations-list"
      refute html =~ "archive-bindings-empty"
      refute html =~ "camera-recording-blocks-section"
      refute html =~ "open_recovery_gate"
      refute html =~ "close_recovery_gate"

      manager_scope =
        scope_with_permissions(["settings.recording.manage", "devices.view"])

      manager_socket =
        mounted_with_runtime(manager_scope, runtime, %{
          list_camera_sources: fn _ ->
            {:ok,
             [
               %{
                 id: "00000000-0000-4000-8000-000000000061",
                 display_name: "Synthetic Gate Camera",
                 device_uid: "sr:cam-01",
                 vendor_camera_id: "cam-01"
               }
             ]}
          end
        })

      {:noreply, archive_socket} =
        RecordingLive.handle_params(
          %{"tab" => "archive"},
          "/settings/recording?tab=archive",
          manager_socket
        )

      archive_doc = archive_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert archive_doc |> LazyHTML.query("#archive-not-installed-notice") |> Enum.count() == 1
      assert archive_doc |> LazyHTML.query("#archive-bindings-empty") |> Enum.count() == 0
      assert archive_doc |> LazyHTML.query("#archive-bindings-card") |> Enum.count() == 0

      {:noreply, cameras_socket} =
        RecordingLive.handle_params(
          %{"tab" => "cameras"},
          "/settings/recording?tab=cameras",
          manager_socket
        )

      cameras_doc = cameras_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert cameras_doc |> LazyHTML.query("#cameras-not-installed-notice") |> Enum.count() == 1
      assert cameras_doc |> LazyHTML.query("#recording-camera-picker-card") |> Enum.count() == 0
      assert cameras_doc |> LazyHTML.query("#camera-recording-blocks-empty") |> Enum.count() == 0
    end

    test "distinguishes closed recovery gate from not_configured and states local retention is not enforced" do
      runtime = %{
        recovery_gate: %{state: :closed, generation: "00000000-0000-4000-8000-000000000011"},
        core_elx: %{
          reachability: :reachable,
          node: :"core-elx@example.internal",
          supervisor: :enabled,
          nvr_installation: :installed
        }
      }

      socket = mounted_with_runtime(scope_with_permissions(["settings.recording.view"]), runtime)
      html = render_mounted(socket)

      assert html =~ "Closed"
      assert html =~ "00000000"
      assert html =~ "Core deployment recovery gate is closed."
      assert html =~ "local blocks are not reclaimed by byte budget or maximum local age"
      assert html =~ "refused when recorder"
      assert html =~ "recording-member-budgets-section"
      assert html =~ "Local only: no object storage configured"
      refute html =~ "NVR is not installed"
    end

    test "default local-only archive state renders 'Local only: no object storage configured' as a normal state without alerts or warning styles" do
      socket =
        ["settings.recording.view"]
        |> scope_with_permissions()
        |> mounted_with_runtime(installed_open_runtime())
        |> assign(:active_tab, "archive")

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      banner = LazyHTML.query(doc, "#archive-local-only-banner")
      assert Enum.count(banner) == 1
      assert LazyHTML.text(banner) =~ "Local only: no object storage configured"
      assert LazyHTML.attribute(banner, "role") == []

      [banner_classes] = LazyHTML.attribute(banner, "class")
      refute banner_classes =~ "amber"
      refute banner_classes =~ "rose"

      assert doc |> LazyHTML.query("#archive-credential-unavailable-banner") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#recording-tab-panel-archive [role='alert']") |> Enum.count() == 0
    end

    test "unreachable core-elx renders unknown state rather than absent or not_installed" do
      runtime = %{
        recovery_gate: %{state: :open, generation: "00000000-0000-4000-8000-000000000011"},
        core_elx: %{
          reachability: :unreachable,
          node: nil,
          supervisor: :unknown,
          nvr_installation: :unknown
        }
      }

      socket = mounted_with_runtime(scope_with_permissions(["settings.recording.view"]), runtime)
      html = render_mounted(socket)

      assert html =~ "Recorder state unknown"
      assert html =~ "Unknown (unreachable)"
      refute html =~ "NVR is not installed"
    end

    test "archive tab renders unqualified bindings, split-permission disabled credential selectors across all 3 slots, unenforced retention notice, and zero secret inputs" do
      runtime = installed_open_runtime()
      user_id = "00000000-0000-4000-8000-000000000022"
      Cache.put(user_id, MapSet.new(["settings.recording.manage"]))
      on_exit(fn -> Cache.invalidate(user_id) end)

      binding = %ArchiveBinding{
        id: "00000000-0000-4000-8000-000000000031",
        provisioning_ref: "operator:primary",
        generation: 1,
        endpoint: "https://objects.example.com",
        region: "example-1",
        bucket: "example-archive",
        namespace: "recordings/v1",
        destination_sha256: String.duplicate("a", 64),
        capability_state: "unqualified"
      }

      writer_secret_id = "00000000-0000-4000-8000-000000000041"
      scope = scope_with_permissions(["settings.recording.manage"], user_id)

      settings_view =
        CameraRecordingSettings.load_archive_settings_view(scope,
          loaders: %{
            settings_loader: fn ->
              {:ok,
               struct(RecordingArchiveSettings.default_settings(),
                 active_archive_binding_id: binding.id,
                 writer_credential_secret_id: writer_secret_id,
                 reader_credential_secret_id: nil,
                 retention_credential_secret_id: nil,
                 archive_enabled: true
               )}
            end,
            binding_loader: fn _id -> {:ok, binding} end,
            secret_loader: fn ^writer_secret_id ->
              {:ok,
               %{
                 id: writer_secret_id,
                 name: "Synthetic archive writer",
                 provider: "s3_compatible",
                 credential_kind: :opaque,
                 rotation_state: :disabled,
                 metadata: %{}
               }}
            end
          }
        )

      socket =
        scope
        |> mounted_with_runtime(runtime)
        |> assign(:active_tab, "archive")
        |> assign(:storage_mode, settings_view.storage_mode)
        |> assign(:bindings, [binding])
        |> assign(:settings_form, settings_view.form)
        |> assign(:active_binding_id, settings_view.active_binding_id)
        |> assign(:selected_writer_label, settings_view.selected_writer_label)
        |> assign(:selected_reader_label, settings_view.selected_reader_label)
        |> assign(:selected_retention_label, settings_view.selected_retention_label)
        |> assign(:object_retention_enforced?, settings_view.object_retention_enforced?)
        |> assign(:credential_issue, settings_view.credential_issue)

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#archive-destinations-list") |> LazyHTML.text() =~
               "https://objects.example.com"

      assert doc |> LazyHTML.query("#archive-destinations-list") |> LazyHTML.text() =~
               "unqualified"

      assert doc |> LazyHTML.query("input[type='password']") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#writer-credential-disabled-select[disabled]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#reader-credential-disabled-select[disabled]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#retention-credential-disabled-select[disabled]") |> Enum.count() == 1

      assert doc |> LazyHTML.query("#writer-credential-disabled-select") |> LazyHTML.text() =~
               "Synthetic archive writer (disabled)"

      assert doc |> LazyHTML.query("#retention-credential-disabled-select") |> LazyHTML.text() =~
               "None selected (object retention not enforced)"

      assert doc |> LazyHTML.query("#archive-retention-unenforced-notice") |> LazyHTML.text() =~
               "Object retention not enforced: no delete credential"

      assert doc |> LazyHTML.query("#archive-missing-credentials-permission-note") |> LazyHTML.text() =~
               "settings.credentials.manage"

      assert doc |> LazyHTML.query("#archive-credential-unavailable-banner") |> LazyHTML.text() =~
               "disabled"

      assert doc
             |> LazyHTML.query("#archive-credentials-inventory-link")
             |> LazyHTML.attribute("href") == ["/settings/networks/credentials"]

      # Clearing active_archive_binding_id while archive_enabled == true warns about awaiting_binding
      {:noreply, cleared_binding_socket} =
        RecordingLive.handle_event(
          "validate_archive_settings",
          %{
            "settings" => %{
              "active_archive_binding_id" => "",
              "archive_enabled" => "true"
            }
          },
          socket
        )

      cleared_doc = cleared_binding_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert cleared_doc |> LazyHTML.query("#archive-awaiting-binding-warning") |> LazyHTML.text() =~
               "awaiting_binding"
    end

    test "all six recording tabs render without Blocked badges and open live policy and health panels" do
      socket =
        mounted_with_runtime(
          scope_with_permissions(["settings.recording.view"]),
          installed_open_runtime()
        )

      tabs_doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      for tab_id <- ~w(recorders archive cameras policy retention health) do
        refute tabs_doc |> LazyHTML.query("#recording-tab-#{tab_id}") |> LazyHTML.text() =~
                 "Blocked"
      end

      refute tabs_doc |> LazyHTML.query("#recording-settings-tabs") |> LazyHTML.text() =~ "Blocked"

      {:noreply, policy_socket} =
        RecordingLive.handle_params(%{"tab" => "policy"}, "/settings/recording?tab=policy", socket)

      policy_doc = policy_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert policy_doc |> LazyHTML.query("#recording-tab-panel-policy") |> Enum.count() == 1
      assert policy_doc |> LazyHTML.query("#recording-policy-blocked-panel") |> Enum.count() == 0
      assert policy_doc |> LazyHTML.query("#recording-policy-what-if-panel") |> Enum.count() == 1

      assert policy_doc |> LazyHTML.query("#recording-policy-runtime-notice") |> LazyHTML.text() =~
               "ContinuousRecorder"

      {:noreply, health_socket} =
        RecordingLive.handle_params(%{"tab" => "health"}, "/settings/recording?tab=health", socket)

      health_doc = health_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert health_doc |> LazyHTML.query("#recording-tab-panel-health") |> Enum.count() == 1
      assert health_doc |> LazyHTML.query("#recording-health-blocked-panel") |> Enum.count() == 0
      assert health_doc |> LazyHTML.query("#recording-health-backlog-card") |> Enum.count() == 1
      assert health_doc |> LazyHTML.query("#recording-health-storage-card") |> Enum.count() == 1

      assert health_doc |> LazyHTML.query("#recording-health-reconciliation-card") |> Enum.count() ==
               1

      assert health_doc |> LazyHTML.query("#recording-health-gaps-alerts-card") |> Enum.count() == 1
    end
  end

  describe "live Retention tab (?tab=retention): local-only usability, what-if simulator, validation, and confirmation gates" do
    test "viewer sees live retention panel in local-only mode with read-only inputs and cannot invoke retention mutations" do
      viewer_scope = scope_with_permissions(["settings.recording.view"])
      socket = mounted_with_runtime(viewer_scope, installed_open_runtime())

      {:noreply, retention_socket} =
        RecordingLive.handle_params(
          %{"tab" => "retention"},
          "/settings/recording?tab=retention",
          socket
        )

      doc = retention_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#recording-tab-panel-retention") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#recording-retention-blocked-panel") |> Enum.count() == 0

      assert doc |> LazyHTML.query("#recording-retention-stage-notice") |> LazyHTML.text() =~
               "LocalRetentionJob"

      assert doc |> LazyHTML.query("#recording-retention-stage-notice") |> LazyHTML.text() =~
               "ArchiveRetentionJob"

      assert doc |> LazyHTML.query("#retention-reaper-flag-notice") |> LazyHTML.text() =~
               "reaper flag remains disabled"

      assert doc |> LazyHTML.query("#retention-storage-mode-badge") |> LazyHTML.text() =~
               "Local only: no object storage configured"

      assert doc |> LazyHTML.query("#retention-archive-local-only-indicator") |> LazyHTML.text() =~
               "Not used: local only"

      assert doc |> LazyHTML.query("#retention-local-only-effective-state") |> LazyHTML.text() =~
               "Unset (behaves as stop_when_full)"

      assert doc |> LazyHTML.query("#retention-calculated-local-summary") |> LazyHTML.text() =~
               "Not recording"

      assert doc |> LazyHTML.query("#save-retention-settings-btn") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#retention-local-high-water-input[disabled]") |> Enum.count() == 1

      # RBAC re-authorization denies preview and save events for view-only users
      {:noreply, denied_preview} =
        RecordingLive.handle_event(
          "preview_retention_settings",
          %{"retention" => %{"archive_retention_days" => "14"}},
          retention_socket
        )

      assert Phoenix.Flash.get(denied_preview.assigns.flash, :error) =~ "Not authorized"

      {:noreply, denied_save} =
        RecordingLive.handle_event(
          "save_retention_settings",
          %{"retention" => %{"archive_retention_days" => "14"}},
          retention_socket
        )

      assert Phoenix.Flash.get(denied_save.assigns.flash, :error) =~ "Not authorized"
    end

    test "preview_retention_settings recalculates effective object retention, local window, and shorter-archive warning live before saving" do
      manager_scope = scope_with_permissions(["settings.recording.manage"])

      socket =
        manager_scope
        |> mounted_with_runtime(installed_open_runtime())
        |> assign(:active_tab, "retention")

      # Simulate 4 cameras at 2,000 kbit/s each (~88.128 GB/day archived with 1.02 overhead, 1 MB/s local)
      # with 500 GB object budget (80% low water = 400 GB available -> T = 400 / 88.128 = ~4.5 days, capacity binds)
      # and 20 GiB local spool budget (80%..90% = 16 GiB..18 GiB -> ~4.8 to 5.4 hours, budget binds)
      {:noreply, preview_socket} =
        RecordingLive.handle_event(
          "preview_retention_settings",
          %{
            "simulator" => %{
              "camera_count" => "4",
              "nominal_bitrate_kbps" => "2000",
              "local_budget_gib" => "20"
            },
            "retention" => %{
              "archive_retention_mode" => "limited",
              "archive_retention_days" => "30",
              "object_budget_mode" => "limited",
              "object_budget_bytes" => "500000000000",
              "object_high_water_percent" => "90",
              "object_low_water_percent" => "80",
              "object_capacity_policy" => "reap_oldest"
            }
          },
          socket
        )

      doc = preview_socket |> render_mounted() |> LazyHTML.from_fragment()

      object_text = doc |> LazyHTML.query("#retention-calculated-object-summary") |> LazyHTML.text()
      assert object_text =~ "configured 30 days, effective about 4.5 days (capacity binds)"

      local_text = doc |> LazyHTML.query("#retention-calculated-local-summary") |> LazyHTML.text()
      assert local_text =~ "Local storage holds about 4.8 to 5.4 hours at the current rate"
      assert local_text =~ "estimated"

      # Setting limited archive retention (1 day) shorter than limited max local age (2 days = 172,800 s)
      # surfaces an advisory warning without blocking save
      {:noreply, shorter_socket} =
        RecordingLive.handle_event(
          "preview_retention_settings",
          %{
            "retention" => %{
              "archive_retention_mode" => "limited",
              "archive_retention_days" => "1",
              "max_local_age_mode" => "limited",
              "max_local_age_seconds" => "172800"
            }
          },
          preview_socket
        )

      assert shorter_socket.assigns.retention_errors == %{}
      shorter_doc = shorter_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert shorter_doc
             |> LazyHTML.query("#retention-shorter-archive-warning")
             |> LazyHTML.text()
             |> normalize_ws() =~
               "Archive copies will expire while their local copies remain, leaving that footage with a single local copy"
    end

    test "enforces mode+value bounds and explicit confirmation gates for overwrite_oldest and reap_oldest" do
      user_id = "00000000-0000-4000-8000-000000000029"
      manager_scope = scope_with_permissions(["settings.recording.manage"], user_id)

      persisted_agent =
        start_supervised!(
          {Agent, fn -> RecordingArchiveSettings.default_settings() end},
          id: :retention_settings_store
        )

      loaders = %{
        settings_loader: fn -> {:ok, Agent.get(persisted_agent, & &1)} end
      }

      deps = %{
        runtime_status: fn -> installed_open_runtime() end,
        authorize_current: &scope_authorize_current/2,
        authorize_current_any: &scope_authorize_current_any/2,
        list_archive_bindings: fn _ -> [] end,
        list_enabled_s3_credentials: fn _ -> [] end,
        load_archive_settings_view: fn s ->
          CameraRecordingSettings.load_archive_settings_view(s, loaders: loaders)
        end,
        load_retention_usage_summary: fn _ ->
          CameraRecordingSettings.default_usage_summary(Agent.get(persisted_agent, & &1))
        end,
        list_camera_sources: fn _ -> {:ok, []} end,
        save_retention_settings: fn s, params ->
          CameraRecordingSettings.save_retention_settings(s, params,
            loaders: loaders,
            save_fn: fn attrs ->
              changeset =
                RecordingArchiveSettings.preview_changeset(attrs,
                  existing: Agent.get(persisted_agent, & &1),
                  scope: s,
                  loaders: %{
                    binding_loader: fn id -> {:ok, %{id: id}} end,
                    secret_loader: fn id -> {:ok, %{id: id}} end
                  }
                )

              if changeset.valid? do
                {:ok, updated} = Ash.Changeset.apply_attributes(changeset)
                Agent.update(persisted_agent, fn _ -> updated end)
                {:ok, updated}
              else
                {:error, %{errors: changeset.errors}}
              end
            end
          )
        end
      }

      socket =
        manager_scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "retention")

      # Draft preselects overwrite_oldest while unset; saving without confirm_local_only_overwrite fails
      assert socket.assigns.retention_form["local_only_full_policy"] == "overwrite_oldest"
      assert socket.assigns.retention_form["confirm_local_only_overwrite"] == "false"

      {:noreply, unconfirmed_local_socket} =
        RecordingLive.handle_event(
          "save_retention_settings",
          %{
            "retention" => %{
              "local_only_full_policy" => "overwrite_oldest",
              "confirm_local_only_overwrite" => "false"
            }
          },
          socket
        )

      assert Map.has_key?(unconfirmed_local_socket.assigns.retention_errors, :local_only_full_policy)
      assert Agent.get(persisted_agent, & &1.local_only_full_policy) == nil

      # Saving stop_when_full succeeds without overwrite confirmation and stamps confirming actor
      {:noreply, stop_socket} =
        RecordingLive.handle_event(
          "save_retention_settings",
          %{
            "retention" => %{
              "local_only_full_policy" => "stop_when_full",
              "confirm_local_only_overwrite" => "false"
            }
          },
          socket
        )

      assert Phoenix.Flash.get(stop_socket.assigns.flash, :info) =~ "Retention settings saved"
      assert Agent.get(persisted_agent, & &1.local_only_full_policy) == :stop_when_full
      assert Agent.get(persisted_agent, & &1.local_only_full_policy_confirmed_by_id) == user_id
      assert %DateTime{} = Agent.get(persisted_agent, & &1.local_only_full_policy_confirmed_at)

      # Mode + value and watermark validation errors surface per field
      {:noreply, invalid_bounds_socket} =
        RecordingLive.handle_event(
          "save_retention_settings",
          %{
            "retention" => %{
              "local_high_water_percent" => "90",
              "local_low_water_percent" => "88",
              "max_local_age_mode" => "limited",
              "max_local_age_seconds" => "120",
              "local_only_max_age_mode" => "unlimited",
              "local_only_max_age_seconds" => "7200",
              "object_budget_mode" => "limited",
              "object_budget_bytes" => "1024",
              "object_capacity_policy" => "stop_archiving",
              "local_only_full_policy" => "stop_when_full"
            }
          },
          stop_socket
        )

      errs = invalid_bounds_socket.assigns.retention_errors
      assert Map.has_key?(errs, :local_low_water_percent)
      assert Map.has_key?(errs, :max_local_age_seconds)
      assert Map.has_key?(errs, :local_only_max_age_seconds)
      assert Map.has_key?(errs, :object_budget_bytes)

      # reap_oldest statement is rendered and requires explicit confirm_reap_oldest before saving
      reap_doc = stop_socket |> render_mounted() |> LazyHTML.from_fragment()

      reap_statement =
        reap_doc |> LazyHTML.query("#retention-reap-oldest-statement") |> LazyHTML.text() |> normalize_ws()

      assert reap_statement =~ "can delete the last copy of footage once the local copy has been evicted"

      assert reap_statement =~
               "can delete the last copy, including by later local eviction of blocks whose archive copy was reaped"

      {:noreply, unconfirmed_reap_socket} =
        RecordingLive.handle_event(
          "save_retention_settings",
          %{
            "retention" => %{
              "local_only_full_policy" => "overwrite_oldest",
              "confirm_local_only_overwrite" => "true",
              "object_budget_mode" => "limited",
              "object_budget_bytes" => "10737418240",
              "object_capacity_policy" => "reap_oldest",
              "confirm_reap_oldest" => "false"
            }
          },
          stop_socket
        )

      assert Map.has_key?(unconfirmed_reap_socket.assigns.retention_errors, :object_capacity_policy)
      assert Agent.get(persisted_agent, & &1.object_capacity_policy) == nil

      # Confirming both overwrite_oldest and reap_oldest saves cleanly and records confirming actor & timestamps
      {:noreply, confirmed_both_socket} =
        RecordingLive.handle_event(
          "save_retention_settings",
          %{
            "retention" => %{
              "local_only_full_policy" => "overwrite_oldest",
              "confirm_local_only_overwrite" => "true",
              "object_budget_mode" => "limited",
              "object_budget_bytes" => "10737418240",
              "object_capacity_policy" => "reap_oldest",
              "confirm_reap_oldest" => "true",
              "archive_retention_mode" => "limited",
              "archive_retention_days" => "1",
              "max_local_age_mode" => "limited",
              "max_local_age_seconds" => "172800"
            }
          },
          stop_socket
        )

      assert Phoenix.Flash.get(confirmed_both_socket.assigns.flash, :info) =~ "Retention settings saved"
      saved = Agent.get(persisted_agent, & &1)
      assert saved.local_only_full_policy == :overwrite_oldest
      assert saved.object_capacity_policy == :reap_oldest
      assert saved.object_capacity_policy_confirmed_by_id == user_id
      assert %DateTime{} = saved.object_capacity_policy_confirmed_at
      assert saved.archive_retention_days == 1
      assert saved.max_local_age_seconds == 172_800
    end

    test "renders C3a same-bucket multi-binding usage scope and separate non-blocking other-bucket info line" do
      viewer_scope = scope_with_permissions(["settings.recording.view"])
      storage_id = "00000000-0000-4000-8000-000000000011"
      binding_gen1_id = "00000000-0000-4000-8000-000000000031"
      binding_gen2_id = "00000000-0000-4000-8000-000000000032"
      other_binding_id = "00000000-0000-4000-8000-000000000033"
      retention_secret_id = "00000000-0000-4000-8000-000000000045"
      now = ~U[2026-11-16 14:00:00Z]

      settings =
        struct(RecordingArchiveSettings.default_settings(),
          active_archive_binding_id: binding_gen2_id,
          archive_enabled: true,
          retention_credential_secret_id: retention_secret_id
        )

      bindings = [
        %ArchiveBinding{
          id: binding_gen1_id,
          provisioning_ref: "operator:primary",
          generation: 1,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-archive",
          namespace: "recordings/v1"
        },
        %ArchiveBinding{
          id: binding_gen2_id,
          provisioning_ref: "operator:primary",
          generation: 2,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-archive",
          namespace: "recordings/v2"
        },
        %ArchiveBinding{
          id: other_binding_id,
          provisioning_ref: "operator:legacy",
          generation: 1,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-legacy-bucket",
          namespace: "recordings/v1"
        }
      ]

      key_1 = String.duplicate("1", 64)
      key_2 = String.duplicate("2", 64)
      key_3 = String.duplicate("3", 64)
      key_reaped = String.duplicate("4", 64)

      catalog_entries = [
        %{
          id: "00000000-0000-4000-8000-000000000081",
          storage_id: storage_id,
          block_key: key_1,
          local_state: :present,
          archive_state: :verified,
          archive_binding_id: binding_gen1_id,
          media_bytes: 52_428_800,
          sealed_at: ~U[2026-11-15 10:00:00Z],
          archived_at: ~U[2026-11-15 10:01:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000082",
          storage_id: storage_id,
          block_key: key_2,
          local_state: :present,
          archive_state: :pending,
          archive_binding_id: binding_gen2_id,
          media_bytes: 26_214_400,
          sealed_at: ~U[2026-11-16 13:55:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000083",
          storage_id: storage_id,
          block_key: key_3,
          local_state: :reclaimed,
          archive_state: :verified,
          archive_binding_id: other_binding_id,
          media_bytes: 67_108_864,
          sealed_at: ~U[2026-11-14 08:00:00Z],
          archived_at: ~U[2026-11-14 08:02:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000084",
          storage_id: storage_id,
          block_key: key_reaped,
          local_state: :present,
          archive_state: :deleted,
          archive_deleted_reason: :object_capacity,
          archive_binding_id: binding_gen1_id,
          media_bytes: 16_777_216,
          sealed_at: ~U[2026-11-10 06:00:00Z]
        }
      ]

      {:ok, summary} =
        RetentionCalculator.usage_summary(
          scope: viewer_scope,
          now: now,
          settings: settings,
          loaders: %{
            bindings_loader: fn -> {:ok, bindings} end,
            all_receipts_loader: fn -> {:ok, []} end,
            catalog_loader: fn -> {:ok, catalog_entries} end,
            blocks_loader: fn -> {:ok, []} end
          }
        )

      assert summary.archive.same_bucket_binding_count == 2
      assert summary.archive.archive_used_bytes == 78_643_200
      assert summary.archive.other_buckets_used_bytes == 67_108_864

      deps = %{
        load_archive_settings_view: fn _ ->
          %{
            default_overview()
            | settings: settings,
              storage_mode: :local_and_archive,
              active_binding_id: binding_gen2_id,
              object_retention_enforced?: true,
              selected_retention_label: "Synthetic retention deleter"
          }
        end,
        load_retention_usage_summary: fn _ -> summary end
      }

      socket =
        viewer_scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "retention")

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      used_text = doc |> LazyHTML.query("#retention-metric-archive-used") |> LazyHTML.text() |> normalize_ws()
      assert used_text =~ "75 MiB"
      assert used_text =~ "+25 MiB in flight (1 uploads)"
      assert used_text =~ "Counts all 2 retained bindings on https://objects.example.com / synthetic-archive"

      local_tail_text =
        doc |> LazyHTML.query("#retention-single-copy-local-tail") |> LazyHTML.text() |> normalize_ws()

      assert local_tail_text =~ "Local only after archive: 16 MiB"

      other_info = LazyHTML.query(doc, "#retention-other-buckets-info")
      assert Enum.count(other_info) == 1
      assert LazyHTML.attribute(other_info, "role") == []

      [other_classes] = LazyHTML.attribute(other_info, "class")
      refute other_classes =~ "rose"
      refute other_classes =~ "amber"

      other_text = other_info |> LazyHTML.text() |> normalize_ws()
      assert other_text =~ "64 MiB retained across 1 other bucket(s)"
      assert other_text =~ "https://objects.example.com / synthetic-legacy-bucket (64 MiB)"
      assert other_text =~ "excluded from active budget"

      # When other_buckets_used_bytes is 0, the other-buckets info banner is omitted
      no_other_summary = put_in(summary, [:archive, :other_buckets_used_bytes], 0)
      no_other_socket = assign(socket, :usage_summary, no_other_summary)
      no_other_doc = no_other_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert no_other_doc |> LazyHTML.query("#retention-other-buckets-info") |> Enum.count() == 0
    end

    test "renders held/non-reapable bytes and high-water/missing hold alerts" do
      manager_scope = scope_with_permissions(["settings.recording.manage"])
      storage_id = "00000000-0000-4000-8000-000000000011"
      camera_id = "00000000-0000-4000-8000-000000000061"
      binding_id = "00000000-0000-4000-8000-000000000031"
      retention_secret_id = "00000000-0000-4000-8000-000000000045"
      now = ~U[2026-11-16 14:00:00Z]

      # 1 GiB limited object budget -> 90% high water = 966,367,641 B
      settings =
        struct(RecordingArchiveSettings.default_settings(),
          active_archive_binding_id: binding_id,
          archive_enabled: true,
          retention_credential_secret_id: retention_secret_id,
          local_only_full_policy: :overwrite_oldest,
          object_budget_mode: :limited,
          object_budget_bytes: 1_073_741_824,
          object_high_water_percent: 90,
          object_low_water_percent: 80,
          object_capacity_policy: :reap_oldest
        )

      bindings = [
        %ArchiveBinding{
          id: binding_id,
          provisioning_ref: "operator:primary",
          generation: 1,
          endpoint: "https://objects.example.com",
          region: "example-1",
          bucket: "synthetic-archive",
          namespace: "recordings/v1"
        }
      ]

      # Entry 1: archive-verified (800 MiB) covered by Hold 1 -> PD5 pins archive copy, NOT local copy
      # Entry 2: in-flight pending (200 MiB) -> brings non_reapable_bytes to 1,000 MiB (>= 921.6 MiB high water)
      # Entry 3: local-only not_required (64 MiB) covered by Hold 2 -> PD5 pins local copy
      catalog_entries = [
        %{
          id: "00000000-0000-4000-8000-000000000111",
          camera_source_id: camera_id,
          storage_id: storage_id,
          block_key: String.duplicate("5", 64),
          timeline_start_us: 1_763_290_000_000_000,
          timeline_end_us: 1_763_290_060_000_000,
          local_state: :present,
          archive_state: :verified,
          archive_binding_id: binding_id,
          media_bytes: 838_860_800,
          sealed_at: ~U[2026-11-16 12:33:20Z],
          archived_at: ~U[2026-11-16 12:34:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000112",
          camera_source_id: camera_id,
          storage_id: storage_id,
          block_key: String.duplicate("6", 64),
          timeline_start_us: 1_763_290_120_000_000,
          timeline_end_us: 1_763_290_180_000_000,
          local_state: :present,
          archive_state: :pending,
          archive_binding_id: binding_id,
          media_bytes: 209_715_200,
          sealed_at: ~U[2026-11-16 13:55:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000113",
          camera_source_id: camera_id,
          storage_id: storage_id,
          block_key: String.duplicate("7", 64),
          timeline_start_us: 1_763_290_300_000_000,
          timeline_end_us: 1_763_290_360_000_000,
          local_state: :present,
          archive_state: :not_required,
          media_bytes: 67_108_864,
          sealed_at: ~U[2026-11-16 13:58:00Z]
        }
      ]

      accepted_holds = [
        %RecordingHold{
          id: "00000000-0000-4000-8000-000000000201",
          camera_source_id: camera_id,
          start_us: 1_763_290_000_000_000,
          end_us: 1_763_290_060_000_000,
          kind: :investigation,
          reason: "Synthetic gate incident",
          state: :accepted,
          unavailable_blocks: []
        },
        %RecordingHold{
          id: "00000000-0000-4000-8000-000000000202",
          camera_source_id: camera_id,
          start_us: 1_763_290_300_000_000,
          end_us: 1_763_290_360_000_000,
          kind: :export,
          reason: "Synthetic clip hold",
          state: :accepted,
          unavailable_blocks: []
        }
      ]

      {:ok, summary} =
        RetentionCalculator.usage_summary(
          scope: manager_scope,
          now: now,
          settings: settings,
          loaders: %{
            bindings_loader: fn -> {:ok, bindings} end,
            all_receipts_loader: fn -> {:ok, []} end,
            catalog_loader: fn -> {:ok, catalog_entries} end,
            holds_loader: fn -> {:ok, accepted_holds} end,
            blocks_loader: fn -> {:ok, []} end
          }
        )

      assert summary.holds == %{
               active_hold_count: 2,
               held_archive_bytes: 838_860_800,
               held_local_pinned_bytes: 67_108_864,
               held_archive_missing_count: 0
             }

      assert summary.object_projection.non_reapable_bytes == 1_048_576_000
      assert summary.object_projection.archiving_paused? == true

      deps = %{
        load_archive_settings_view: fn _ ->
          %{
            default_overview()
            | record: settings,
              settings: settings,
              retention_form: CameraRecordingSettings.retention_form_from_settings(settings),
              storage_mode: :local_and_archive,
              active_binding_id: binding_id,
              object_retention_enforced?: true,
              selected_retention_label: "Synthetic retention deleter"
          }
        end,
        load_retention_usage_summary: fn _ -> summary end
      }

      socket =
        manager_scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "retention")

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#retention-active-holds-count") |> LazyHTML.text() =~
               "Active holds: 2"

      held_arch_text =
        doc |> LazyHTML.query("#retention-held-archive-bytes") |> LazyHTML.text() |> normalize_ws()

      assert held_arch_text =~ "Held archive: 800 MiB"
      assert held_arch_text =~ "Non-reapable: 1000 MiB"

      assert doc
             |> LazyHTML.query("#retention-held-local-pinned-bytes")
             |> LazyHTML.text()
             |> normalize_ws() == "Held local-pinned: 64 MiB"

      holds_rule_text =
        doc |> LazyHTML.query("#retention-holds-capacity-summary") |> LazyHTML.text() |> normalize_ws()

      assert holds_rule_text =~ "archive-verified held blocks pin the archive copy"
      assert holds_rule_text =~ "keep their local copy evictable"
      assert holds_rule_text =~ "placed and released on the camera Timeline, not in Settings"

      high_water_alert = LazyHTML.query(doc, "#retention-non-reapable-high-water-alert[role='alert']")
      assert Enum.count(high_water_alert) == 1

      assert high_water_alert |> LazyHTML.text() |> normalize_ws() =~
               "Non-reapable bytes (held archive copies and uploads in flight) have reached object high water — new archive uploads pause until holds are released or the budget is raised"

      assert doc |> LazyHTML.query("#retention-held-archive-missing-alert") |> Enum.count() == 0

      # Raising the draft object budget to 10 GiB puts high water (9 GiB) above 1,000 MiB and clears the alert live
      {:noreply, raised_socket} =
        RecordingLive.handle_event(
          "preview_retention_settings",
          %{
            "retention" => %{
              "object_budget_mode" => "limited",
              "object_budget_bytes" => "10737418240"
            }
          },
          socket
        )

      raised_doc = raised_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert raised_doc |> LazyHTML.query("#retention-non-reapable-high-water-alert") |> Enum.count() == 0

      # When a held entry's archive copy is missing, held_archive_missing_count > 0 surfaces the critical alert
      missing_entries =
        List.update_at(catalog_entries, 0, &Map.put(&1, :archive_state, :missing))

      {:ok, missing_summary} =
        RetentionCalculator.usage_summary(
          scope: manager_scope,
          now: now,
          settings: settings,
          loaders: %{
            bindings_loader: fn -> {:ok, bindings} end,
            all_receipts_loader: fn -> {:ok, []} end,
            catalog_loader: fn -> {:ok, missing_entries} end,
            holds_loader: fn -> {:ok, accepted_holds} end,
            blocks_loader: fn -> {:ok, []} end
          }
        )

      assert missing_summary.holds.held_archive_missing_count == 1
      assert missing_summary.holds.held_local_pinned_bytes == 838_860_800 + 67_108_864

      missing_socket = assign(raised_socket, :usage_summary, missing_summary)
      missing_doc = missing_socket |> render_mounted() |> LazyHTML.from_fragment()

      missing_alert =
        LazyHTML.query(missing_doc, "#retention-held-archive-missing-alert[role='alert']")

      assert Enum.count(missing_alert) == 1
      assert LazyHTML.text(missing_alert) =~ "held_archive_missing"
      assert LazyHTML.text(missing_alert) =~ "1 held block(s)"
    end
  end

  describe "A1.8 archive mutations and per-event RBAC re-authorization" do
    test "register_destination creates immutable generations and surfaces field-level errors on invalid inputs" do
      user_id = "00000000-0000-4000-8000-000000000023"
      perms = ["settings.recording.manage"]
      Cache.put(user_id, MapSet.new(perms))
      on_exit(fn -> Cache.invalidate(user_id) end)

      scope = scope_with_permissions(perms, user_id)
      store = start_supervised!({Agent, fn -> [] end}, id: :dest_bindings_store)

      deps = %{
        runtime_status: fn -> installed_open_runtime() end,
        authorize_current: &scope_authorize_current/2,
        authorize_current_any: &scope_authorize_current_any/2,
        list_archive_bindings: fn _scope -> Agent.get(store, & &1) end,
        list_enabled_s3_credentials: fn _scope -> [] end,
        load_archive_settings_view: fn _scope -> default_overview() end,
        load_retention_usage_summary: fn _scope -> CameraRecordingSettings.default_usage_summary() end,
        list_camera_sources: fn _scope -> {:ok, []} end,
        list_policies: fn _scope -> [] end,
        what_if_policy_preview: &db_free_what_if_preview/3,
        list_storage_settings: fn _scope -> [] end,
        load_recording_health: fn _scope -> CameraRecordingSettings.default_health_summary() end,
        register_operator_destination: fn s, params ->
          CameraRecordingSettings.register_operator_destination(s, params,
            register_fn: fn normalized ->
              next_gen =
                store
                |> Agent.get(& &1)
                |> Enum.filter(&(&1.provisioning_ref == normalized.provisioning_ref))
                |> Enum.map(& &1.generation)
                |> Enum.max(fn -> 0 end)
                |> Kernel.+(1)

              {:ok, attrs} =
                ArchiveDestination.validate(%{
                  "schema_version" => 2,
                  "provisioning_ref" => normalized.provisioning_ref,
                  "generation" => next_gen,
                  "purpose" => "recording",
                  "provider" => "s3_compatible",
                  "endpoint" => normalized.endpoint,
                  "region" => normalized.region,
                  "bucket" => normalized.bucket,
                  "namespace" => normalized.namespace,
                  "archive_format_version" => 1,
                  "required_encryption" => "sse_s3_aes256"
                })

              binding =
                struct(
                  ArchiveBinding,
                  Map.merge(attrs, %{
                    id: Ecto.UUID.generate(),
                    capability_state: "unqualified"
                  })
                )

              Agent.update(store, &[binding | &1])
              {:ok, binding}
            end
          )
        end
      }

      socket =
        scope
        |> mounted_with_runtime(installed_open_runtime())
        |> assign(:active_tab, "archive")
        |> assign(:recording_deps, deps)

      for bad_endpoint <- [
            "https://192.0.2.10",
            "https://objects.example.com:8443",
            "http://objects.example.com",
            "https://objects.example.com/subpath"
          ] do
        {:noreply, err_socket} =
          RecordingLive.handle_event(
            "register_destination",
            %{
              "destination" => %{
                "name" => "primary",
                "endpoint" => bad_endpoint,
                "region" => "example-1",
                "bucket" => "example-archive",
                "namespace" => "recordings/site-a"
              }
            },
            socket
          )

        assert Map.has_key?(err_socket.assigns.destination_errors, :endpoint),
               "expected :endpoint error for #{bad_endpoint}"

        err_doc = err_socket |> render_mounted() |> LazyHTML.from_fragment()
        assert err_doc |> LazyHTML.query("#destination-error-endpoint") |> Enum.count() == 1
      end

      {:noreply, gen1_socket} =
        RecordingLive.handle_event(
          "register_destination",
          %{
            "destination" => %{
              "name" => "primary",
              "endpoint" => "https://objects.example.com",
              "region" => "example-1",
              "bucket" => "example-archive",
              "namespace" => "recordings/site-a"
            }
          },
          socket
        )

      assert [gen1] = gen1_socket.assigns.bindings
      assert gen1.provisioning_ref == "operator:primary"
      assert gen1.generation == 1
      assert gen1.namespace == "recordings/site-a"

      {:noreply, gen2_socket} =
        RecordingLive.handle_event(
          "register_destination",
          %{
            "destination" => %{
              "name" => "primary",
              "endpoint" => "https://objects.example.com",
              "region" => "example-1",
              "bucket" => "example-archive-v2",
              "namespace" => "recordings/site-a"
            }
          },
          gen1_socket
        )

      assert [gen2, ^gen1] = gen2_socket.assigns.bindings
      assert gen2.generation == 2
      assert gen2.destination_sha256 != gen1.destination_sha256

      revoked_socket =
        assign(gen2_socket, :current_scope, scope_with_permissions(["settings.recording.view"]))

      {:noreply, denied_socket} =
        RecordingLive.handle_event(
          "register_destination",
          %{
            "destination" => %{
              "name" => "secondary",
              "endpoint" => "https://objects.example.com",
              "region" => "example-1",
              "bucket" => "example-archive",
              "namespace" => "recordings/v1"
            }
          },
          revoked_socket
        )

      assert Phoenix.Flash.get(denied_socket.assigns.flash, :error) =~ "Not authorized"
    end

    test "save_archive_settings enforces split-permission credential rules across writer, reader, and retention slots" do
      binding_id = "00000000-0000-4000-8000-000000000031"
      writer_id = "00000000-0000-4000-8000-000000000041"
      retention_id = "00000000-0000-4000-8000-000000000043"
      disabled_writer_id = "00000000-0000-4000-8000-000000000042"
      existing_writer_id = "00000000-0000-4000-8000-000000000040"

      persisted_state =
        start_supervised!(
          {Agent,
           fn ->
             struct(RecordingArchiveSettings.default_settings(),
               active_archive_binding_id: nil,
               writer_credential_secret_id: existing_writer_id,
               reader_credential_secret_id: nil,
               retention_credential_secret_id: nil,
               archive_enabled: false
             )
           end},
          id: :archive_settings_store
        )

      saved_attrs_agent = start_supervised!({Agent, fn -> nil end}, id: :saved_attrs_store)

      loaders = %{
        settings_loader: fn -> {:ok, Agent.get(persisted_state, & &1)} end,
        binding_loader: fn ^binding_id ->
          {:ok, %ArchiveBinding{id: binding_id, destination_sha256: String.duplicate("a", 64)}}
        end,
        secret_loader: fn
          ^existing_writer_id ->
            {:ok,
             %{
               id: existing_writer_id,
               name: "Existing writer",
               provider: "s3_compatible",
               credential_kind: :opaque,
               rotation_state: :active,
               metadata: %{}
             }}

          ^writer_id ->
            {:ok,
             %{
               id: writer_id,
               name: "New active writer",
               provider: "s3_compatible",
               credential_kind: :opaque,
               rotation_state: :active,
               metadata: %{}
             }}

          ^retention_id ->
            {:ok,
             %{
               id: retention_id,
               name: "Active retention deleter",
               provider: "s3_compatible",
               credential_kind: :opaque,
               rotation_state: :active,
               metadata: %{}
             }}

          ^disabled_writer_id ->
            {:ok,
             %{
               id: disabled_writer_id,
               name: "Disabled credential",
               provider: "s3_compatible",
               credential_kind: :opaque,
               rotation_state: :disabled,
               metadata: %{}
             }}
        end
      }

      deps = %{
        runtime_status: fn -> installed_open_runtime() end,
        authorize_current: &scope_authorize_current/2,
        authorize_current_any: &scope_authorize_current_any/2,
        list_archive_bindings: fn _ -> [] end,
        list_enabled_s3_credentials: fn _ -> [] end,
        load_archive_settings_view: fn s ->
          CameraRecordingSettings.load_archive_settings_view(s, loaders: loaders)
        end,
        load_retention_usage_summary: fn _ ->
          CameraRecordingSettings.default_usage_summary(Agent.get(persisted_state, & &1))
        end,
        list_camera_sources: fn _ -> {:ok, []} end,
        save_archive_settings: fn s, params, can_manage_creds? ->
          CameraRecordingSettings.save_archive_settings(s, params, can_manage_creds?,
            loaders: loaders,
            save_fn: fn attrs ->
              Agent.update(saved_attrs_agent, fn _ -> attrs end)
              updated = struct(Agent.get(persisted_state, & &1), attrs)
              Agent.update(persisted_state, fn _ -> updated end)
              {:ok, updated}
            end
          )
        end
      }

      # 1. Split-duty operator (settings.recording.manage WITHOUT settings.credentials.manage)
      split_scope = scope_with_permissions(["settings.recording.manage"])

      split_socket =
        split_scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "archive")

      {:noreply, ok_split} =
        RecordingLive.handle_event(
          "save_archive_settings",
          %{
            "settings" => %{
              "active_archive_binding_id" => binding_id,
              "archive_enabled" => "true"
            }
          },
          split_socket
        )

      assert Phoenix.Flash.get(ok_split.assigns.flash, :info) =~ "Archive settings saved"
      saved_split_attrs = Agent.get(saved_attrs_agent, & &1)
      assert saved_split_attrs == %{active_archive_binding_id: binding_id, archive_enabled: true}
      refute Map.has_key?(saved_split_attrs, :writer_credential_secret_id)
      refute Map.has_key?(saved_split_attrs, :retention_credential_secret_id)
      assert Agent.get(persisted_state, & &1.writer_credential_secret_id) == existing_writer_id

      # Split-duty operator tampering with writer or retention credential param is rejected
      for tampered_field <- ["writer_credential_secret_id", "retention_credential_secret_id"] do
        {:noreply, rejected_split} =
          RecordingLive.handle_event(
            "save_archive_settings",
            %{
              "settings" => %{
                "active_archive_binding_id" => binding_id,
                "archive_enabled" => "true",
                tampered_field => retention_id
              }
            },
            split_socket
          )

        assert Phoenix.Flash.get(rejected_split.assigns.flash, :error) =~
                 "settings.credentials.manage"
      end

      # 2. Full operator WITH settings.credentials.manage cannot select a disabled retention credential
      full_scope =
        scope_with_permissions(["settings.recording.manage", "settings.credentials.manage"])

      full_socket = assign(split_socket, :current_scope, full_scope)

      {:noreply, rejected_disabled} =
        RecordingLive.handle_event(
          "save_archive_settings",
          %{
            "settings" => %{
              "active_archive_binding_id" => binding_id,
              "archive_enabled" => "true",
              "writer_credential_secret_id" => writer_id,
              "reader_credential_secret_id" => "",
              "retention_credential_secret_id" => disabled_writer_id
            }
          },
          full_socket
        )

      assert Phoenix.Flash.get(rejected_disabled.assigns.flash, :error) =~ "disabled"

      # 3. Full operator WITH settings.credentials.manage can bind active writer + retention credentials
      {:noreply, ok_full} =
        RecordingLive.handle_event(
          "save_archive_settings",
          %{
            "settings" => %{
              "active_archive_binding_id" => binding_id,
              "archive_enabled" => "true",
              "writer_credential_secret_id" => writer_id,
              "reader_credential_secret_id" => "",
              "retention_credential_secret_id" => retention_id
            }
          },
          full_socket
        )

      assert Phoenix.Flash.get(ok_full.assigns.flash, :info) =~ "Archive settings saved"
      assert ok_full.assigns.object_retention_enforced? == true
      assert ok_full.assigns.selected_retention_label == "Active retention deleter"

      assert Agent.get(saved_attrs_agent, & &1) == %{
               active_archive_binding_id: binding_id,
               archive_enabled: true,
               writer_credential_secret_id: writer_id,
               reader_credential_secret_id: nil,
               retention_credential_secret_id: retention_id
             }
    end
  end

  describe "cameras tab block reservation stream and pagination" do
    test "streams Core block reservations with unknown local state and verified receipt details" do
      camera_id = "00000000-0000-4000-8000-000000000061"
      profile_id = "00000000-0000-4000-8000-000000000062"
      storage_id = "00000000-0000-4000-8000-000000000011"
      block_key_1 = String.duplicate("b", 64)
      block_key_2 = String.duplicate("c", 64)

      receipt = %{
        storage_id: storage_id,
        block_key: block_key_1,
        objects: [
          %{
            "name" => "media.m4s",
            "key" => "recordings/v1/#{storage_id}/#{block_key_1}/media.m4s",
            "length" => 4096,
            "sha256" => String.duplicate("d", 64),
            "etag" => "\"etag-1\"",
            "version_id" => "synth-ver-0001"
          }
        ]
      }

      row_1 =
        CameraRecordingSettings.decorate_block_row(
          %{
            id: "00000000-0000-4000-8000-000000000071",
            block_key: block_key_1,
            storage_id: storage_id,
            stream_profile_id: profile_id,
            state: :open_local,
            inserted_at: ~U[2026-11-15 12:00:00Z]
          },
          %{{storage_id, block_key_1} => receipt}
        )

      row_2 =
        CameraRecordingSettings.decorate_block_row(
          %{
            id: "00000000-0000-4000-8000-000000000072",
            block_key: block_key_2,
            storage_id: storage_id,
            stream_profile_id: profile_id,
            state: :open_local,
            inserted_at: ~U[2026-11-15 11:00:00Z]
          },
          %{}
        )

      sub_profile_id = "00000000-0000-4000-8000-000000000063"

      deps = %{
        authorize_current: &scope_authorize_current/2,
        authorize_current_any: &scope_authorize_current_any/2,
        list_relay_profiles: fn _scope, ^camera_id ->
          [
            %{id: profile_id, profile_name: "main", codec_hint: "h264"},
            %{id: sub_profile_id, profile_name: "sub", codec_hint: "h264"}
          ]
        end,
        list_camera_blocks_page: fn _scope, ^camera_id, opts ->
          profile = Keyword.get(opts, :stream_profile_id)

          case {profile, Keyword.get(opts, :cursor)} do
            {^sub_profile_id, nil} -> {:ok, %{rows: [], next_cursor: "cursor-sub-2"}}
            {^sub_profile_id, "cursor-sub-2"} -> {:ok, %{rows: [], next_cursor: nil}}
            {_, nil} -> {:ok, %{rows: [row_1], next_cursor: "cursor-page-2"}}
            {_, "cursor-page-2"} -> {:ok, %{rows: [row_2], next_cursor: nil}}
          end
        end
      }

      scope = scope_with_permissions(["settings.recording.view", "devices.view"])

      socket =
        scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "cameras")
        |> assign(:sources, [
          %{
            id: camera_id,
            display_name: "Synthetic Gate Camera",
            device_uid: "sr:cam-01",
            vendor_camera_id: "cam-01"
          }
        ])

      {:noreply, selected_socket} =
        RecordingLive.handle_event(
          "select_camera_context",
          %{"camera_source_id" => camera_id},
          socket
        )

      html = render_mounted(selected_socket)
      assert html =~ block_key_1
      assert html =~ "Core reservation"
      assert html =~ "Unknown (NVR lookup unavailable)"
      assert html =~ "Verified receipt"
      assert html =~ "media.m4s"
      assert html =~ "version synth-ver-0001"
      assert html =~ "next-camera-blocks-page"

      {:noreply, page2_socket} =
        RecordingLive.handle_event("next_blocks_page", %{}, selected_socket)

      assert page2_socket.assigns.blocks_next_cursor == nil
      page2_html = render_mounted(page2_socket)
      assert page2_html =~ block_key_2
      assert page2_html =~ "No receipt in Core"

      {:noreply, filtered_page1} =
        RecordingLive.handle_event(
          "select_camera_context",
          %{"camera_source_id" => camera_id, "stream_profile_id" => sub_profile_id},
          page2_socket
        )

      filtered_doc = filtered_page1 |> render_mounted() |> LazyHTML.from_fragment()
      assert filtered_doc |> LazyHTML.query("#camera-recording-blocks-empty") |> Enum.count() == 0
      assert filtered_doc |> LazyHTML.query("#camera-recording-blocks-filtered-more") |> Enum.count() == 1
      assert filtered_doc |> LazyHTML.query("#next-camera-blocks-page") |> Enum.count() == 1

      {:noreply, filtered_page2} =
        RecordingLive.handle_event("next_blocks_page", %{}, filtered_page1)

      filtered_end_doc = filtered_page2 |> render_mounted() |> LazyHTML.from_fragment()
      assert filtered_end_doc |> LazyHTML.query("#camera-recording-blocks-empty") |> Enum.count() == 1
      assert filtered_end_doc |> LazyHTML.query("#camera-recording-blocks-filtered-more") |> Enum.count() == 0
      assert filtered_end_doc |> LazyHTML.query("#next-camera-blocks-page") |> Enum.count() == 0
    end

    test "joins RecordingCatalogEntry copy states and received time basis while preserving Core reservation and unknown local state on uncataloged rows" do
      camera_id = "00000000-0000-4000-8000-000000000061"
      profile_id = "00000000-0000-4000-8000-000000000062"
      storage_id = "00000000-0000-4000-8000-000000000011"

      key_verified = String.duplicate("a", 64)
      key_reaped_local = String.duplicate("b", 64)
      key_reclaimed = String.duplicate("c", 64)
      key_failed = String.duplicate("d", 64)
      key_uncataloged = String.duplicate("e", 64)

      blocks = [
        %{
          id: "00000000-0000-4000-8000-000000000091",
          block_key: key_verified,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :sealed,
          inserted_at: ~U[2026-11-16 12:10:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000092",
          block_key: key_reaped_local,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :sealed,
          inserted_at: ~U[2026-11-16 12:08:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000093",
          block_key: key_reclaimed,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :sealed,
          inserted_at: ~U[2026-11-16 12:06:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000094",
          block_key: key_failed,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :sealed,
          inserted_at: ~U[2026-11-16 12:04:00Z]
        },
        %{
          id: "00000000-0000-4000-8000-000000000095",
          block_key: key_uncataloged,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :open_local,
          inserted_at: ~U[2026-11-16 12:02:00Z]
        }
      ]

      receipt_id = "00000000-0000-4000-8000-000000000099"

      receipt = %{
        id: receipt_id,
        storage_id: storage_id,
        block_key: key_verified,
        objects: [
          %{
            "name" => "media.m4s",
            "key" => "recordings/v1/#{storage_id}/#{key_verified}/media.m4s",
            "length" => 4_194_304,
            "sha256" => String.duplicate("f", 64),
            "etag" => "\"etag-cat-1\"",
            "version_id" => "synth-v2-cat-01"
          }
        ]
      }

      catalog_entries = %{
        {storage_id, key_verified} => %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000101",
          recording_block_id: "00000000-0000-4000-8000-000000000091",
          storage_id: storage_id,
          block_key: key_verified,
          local_state: :present,
          archive_state: :verified,
          nvr_archive_receipt_id: receipt_id,
          time_basis: :received,
          timeline_start_us: 1_763_295_000_000_000,
          timeline_end_us: 1_763_295_012_000_000,
          time_uncertainty_us: nil,
          reanchored: true,
          media_bytes: 4_194_304,
          fragment_count: 6
        },
        {storage_id, key_reaped_local} => %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000102",
          recording_block_id: "00000000-0000-4000-8000-000000000092",
          storage_id: storage_id,
          block_key: key_reaped_local,
          local_state: :present,
          archive_state: :deleted,
          archive_deleted_reason: :object_capacity,
          time_basis: :received,
          timeline_start_us: 1_763_294_880_000_000,
          timeline_end_us: 1_763_294_892_000_000,
          time_uncertainty_us: nil,
          reanchored: false,
          media_bytes: 2_097_152,
          fragment_count: 3
        },
        {storage_id, key_reclaimed} => %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000103",
          recording_block_id: "00000000-0000-4000-8000-000000000093",
          storage_id: storage_id,
          block_key: key_reclaimed,
          local_state: :reclaimed,
          archive_state: :not_required,
          time_basis: :received,
          timeline_start_us: 1_763_294_760_000_000,
          timeline_end_us: 1_763_294_770_000_000,
          time_uncertainty_us: nil,
          reanchored: false,
          media_bytes: 1_048_576,
          fragment_count: 2
        },
        {storage_id, key_failed} => %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000104",
          recording_block_id: "00000000-0000-4000-8000-000000000094",
          storage_id: storage_id,
          block_key: key_failed,
          local_state: :missing,
          archive_state: :failed_terminal,
          archive_attempts: 2,
          archive_last_error_class: "archive_receipt_conflict",
          time_basis: :received,
          timeline_start_us: 1_763_294_640_000_000,
          timeline_end_us: 1_763_294_650_000_000,
          time_uncertainty_us: nil,
          reanchored: false,
          media_bytes: 1_048_576,
          fragment_count: 2
        }
      }

      scope = scope_with_permissions(["settings.recording.view", "devices.view"])

      deps = %{
        authorize_current: &scope_authorize_current/2,
        authorize_current_any: &scope_authorize_current_any/2,
        list_relay_profiles: fn _scope, ^camera_id ->
          [%{id: profile_id, profile_name: "main", codec_hint: "h264"}]
        end,
        list_camera_blocks_page: fn s, cid, opts ->
          CameraRecordingSettings.list_camera_blocks_page(
            s,
            cid,
            Keyword.put(opts, :loaders, %{
              blocks_page_loader: fn ^camera_id, _page_opts -> {:ok, blocks} end,
              receipts_for_blocks_loader: fn _ ->
                %{
                  {storage_id, key_verified} => receipt,
                  {:receipt_id, receipt_id} => receipt
                }
              end,
              catalog_for_blocks_loader: fn _ -> {:ok, catalog_entries} end
            })
          )
        end
      }

      socket =
        scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "cameras")
        |> assign(:sources, [
          %{
            id: camera_id,
            display_name: "Synthetic Gate Camera",
            device_uid: "sr:cam-01",
            vendor_camera_id: "cam-01"
          }
        ])

      {:noreply, selected_socket} =
        RecordingLive.handle_event(
          "select_camera_context",
          %{"camera_source_id" => camera_id},
          socket
        )

      doc = selected_socket |> render_mounted() |> LazyHTML.from_fragment()
      rows_html = doc |> LazyHTML.query("#camera-recording-blocks-stream") |> LazyHTML.text() |> normalize_ws()

      # Cataloged rows render Cataloged · Sealed, provisional local copy (PD2), archive_state, and received time basis
      assert rows_html =~ "Cataloged · Sealed"
      assert rows_html =~ "present (provisional)"
      assert rows_html =~ "4 MiB · 6 fragments"
      assert rows_html =~ "verified"
      assert rows_html =~ "version synth-v2-cat-01"
      assert rows_html =~ "Local only after archive reaping"
      assert rows_html =~ "Deleted (object_capacity)"
      assert rows_html =~ "reclaimed"
      assert rows_html =~ "not_required (local only)"
      assert rows_html =~ "missing"
      assert rows_html =~ "failed_terminal"
      assert rows_html =~ "Error: archive_receipt_conflict (attempt 2)"
      assert rows_html =~ "received"
      assert rows_html =~ "time re-anchored"
      assert rows_html =~ "Uncertainty: unmeasured"
      assert doc |> LazyHTML.query("#block-timeline-start-00000000-0000-4000-8000-000000000091") |> Enum.count() == 1

      # Uncataloged open_local row preserves Core reservation and Unknown (never absent)
      assert rows_html =~ "Core reservation"
      assert rows_html =~ "Unknown (NVR lookup unavailable)"
      assert rows_html =~ "Not cataloged"
      refute String.downcase(rows_html) =~ "absent"
      refute String.downcase(rows_html) =~ "capture time"
    end

    test "renders PD5 archive vs local hold-pin badges on cameras tab" do
      camera_id = "00000000-0000-4000-8000-000000000061"
      profile_id = "00000000-0000-4000-8000-000000000062"
      storage_id = "00000000-0000-4000-8000-000000000011"

      block_arch_id = "00000000-0000-4000-8000-000000000301"
      block_local_id = "00000000-0000-4000-8000-000000000302"
      block_unheld_id = "00000000-0000-4000-8000-000000000303"

      key_arch = String.duplicate("8", 64)
      key_local = String.duplicate("9", 64)
      key_unheld = String.duplicate("0", 64)

      blocks = [
        %{
          id: block_arch_id,
          block_key: key_arch,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :sealed,
          inserted_at: ~U[2026-11-16 13:10:00Z]
        },
        %{
          id: block_local_id,
          block_key: key_local,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :sealed,
          inserted_at: ~U[2026-11-16 13:08:00Z]
        },
        %{
          id: block_unheld_id,
          block_key: key_unheld,
          storage_id: storage_id,
          stream_profile_id: profile_id,
          state: :sealed,
          inserted_at: ~U[2026-11-16 13:06:00Z]
        }
      ]

      catalog_entries = %{
        {storage_id, key_arch} => %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000311",
          recording_block_id: block_arch_id,
          camera_source_id: camera_id,
          stream_profile_id: profile_id,
          storage_id: storage_id,
          block_key: key_arch,
          local_state: :present,
          archive_state: :verified,
          time_basis: :received,
          timeline_start_us: 1_763_298_600_000_000,
          timeline_end_us: 1_763_298_612_000_000,
          media_bytes: 4_194_304,
          fragment_count: 6
        },
        {storage_id, key_local} => %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000312",
          recording_block_id: block_local_id,
          camera_source_id: camera_id,
          stream_profile_id: profile_id,
          storage_id: storage_id,
          block_key: key_local,
          local_state: :present,
          archive_state: :not_required,
          time_basis: :received,
          timeline_start_us: 1_763_298_480_000_000,
          timeline_end_us: 1_763_298_492_000_000,
          media_bytes: 2_097_152,
          fragment_count: 3
        },
        {storage_id, key_unheld} => %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000313",
          recording_block_id: block_unheld_id,
          camera_source_id: camera_id,
          stream_profile_id: profile_id,
          storage_id: storage_id,
          block_key: key_unheld,
          local_state: :present,
          archive_state: :verified,
          time_basis: :received,
          timeline_start_us: 1_763_298_360_000_000,
          timeline_end_us: 1_763_298_372_000_000,
          media_bytes: 2_097_152,
          fragment_count: 3
        }
      }

      holds = [
        %RecordingHold{
          id: "00000000-0000-4000-8000-000000000321",
          camera_source_id: camera_id,
          stream_profile_id: profile_id,
          start_us: 1_763_298_600_000_000,
          end_us: 1_763_298_615_000_000,
          kind: :investigation,
          reason: "Synthetic investigation hold",
          state: :accepted,
          unavailable_blocks: []
        },
        %RecordingHold{
          id: "00000000-0000-4000-8000-000000000322",
          camera_source_id: camera_id,
          stream_profile_id: profile_id,
          start_us: 1_763_298_480_000_000,
          end_us: 1_763_298_495_000_000,
          kind: :export,
          reason: "Synthetic export hold",
          state: :accepted,
          unavailable_blocks: []
        }
      ]

      scope = scope_with_permissions(["settings.recording.view", "devices.view"])

      deps = %{
        authorize_current: &scope_authorize_current/2,
        authorize_current_any: &scope_authorize_current_any/2,
        list_relay_profiles: fn _scope, ^camera_id ->
          [%{id: profile_id, profile_name: "main", codec_hint: "h264"}]
        end,
        list_camera_blocks_page: fn s, cid, opts ->
          CameraRecordingSettings.list_camera_blocks_page(
            s,
            cid,
            Keyword.put(opts, :loaders, %{
              blocks_page_loader: fn ^camera_id, _page_opts -> {:ok, blocks} end,
              receipts_for_blocks_loader: fn _ -> %{} end,
              catalog_for_blocks_loader: fn _ -> {:ok, catalog_entries} end,
              holds_loader: fn [^camera_id] -> {:ok, holds} end
            })
          )
        end
      }

      socket =
        scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "cameras")
        |> assign(:sources, [
          %{
            id: camera_id,
            display_name: "Synthetic Gate Camera",
            device_uid: "sr:cam-01",
            vendor_camera_id: "cam-01"
          }
        ])

      {:noreply, selected_socket} =
        RecordingLive.handle_event(
          "select_camera_context",
          %{"camera_source_id" => camera_id},
          socket
        )

      doc = selected_socket |> render_mounted() |> LazyHTML.from_fragment()

      timeline_note =
        doc
        |> LazyHTML.query("#camera-recording-holds-timeline-note")
        |> LazyHTML.text()
        |> normalize_ws()

      assert timeline_note =~ "placed or released from the camera Timeline, not in Settings"

      arch_pin_text =
        doc |> LazyHTML.query("#block-hold-pin-#{block_arch_id}") |> LazyHTML.text() |> normalize_ws()

      assert arch_pin_text =~ "Hold pins archive copy (local evictable)"
      assert arch_pin_text =~ "1 active hold (investigation)"
      assert arch_pin_text =~ "Placed/released on Timeline"

      local_pin_text =
        doc |> LazyHTML.query("#block-hold-pin-#{block_local_id}") |> LazyHTML.text() |> normalize_ws()

      assert local_pin_text =~ "Hold pins local copy"
      refute local_pin_text =~ "local evictable"
      assert local_pin_text =~ "1 active hold (export)"

      assert doc |> LazyHTML.query("#block-hold-pin-#{block_unheld_id}") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#camera-recording-blocks-stream") |> LazyHTML.text() =~ "No active hold"
    end
  end

  describe "CameraLive.Show and RecordingsComponents links & source labels" do
    test "CameraLive.Show renders Recording & storage link only when user has a recording settings permission" do
      source_id = "00000000-0000-4000-8000-000000000051"

      unpermitted = scope_with_permissions(["devices.view", "devices.cameras.view"])

      {:ok, unpermitted_socket} =
        CameraShowLive.mount(%{"camera_source_id" => source_id}, %{}, base_socket(unpermitted))

      unpermitted_html =
        unpermitted_socket.assigns
        |> CameraShowLive.render()
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      refute unpermitted_html =~ "camera-recording-settings-link"

      permitted =
        scope_with_permissions(["devices.view", "devices.cameras.view", "settings.recording.view"])

      {:ok, permitted_socket} =
        CameraShowLive.mount(%{"camera_source_id" => source_id}, %{}, base_socket(permitted))

      permitted_doc =
        permitted_socket.assigns
        |> CameraShowLive.render()
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()

      assert permitted_doc
             |> LazyHTML.query("#camera-recording-settings-link")
             |> LazyHTML.attribute("href") == ["/settings/recording"]
    end

    test "RecordingsComponents labels ArchiveUploads source and conditionally renders Recording & storage link" do
      source = %{
        id: "00000000-0000-4000-8000-000000000051",
        device_uid: "sr:synthetic-camera-01",
        display_name: "Synthetic Yard Camera"
      }

      default_doc =
        (&RecordingsComponents.recordings/1)
        |> render_component(source: source, items: [], timezone: "Etc/UTC")
        |> LazyHTML.from_fragment()

      assert default_doc |> LazyHTML.query("#camera-recordings-source-label") |> LazyHTML.text() =~
               "ArchiveUploads"

      assert default_doc |> LazyHTML.query("#camera-recording-settings-link") |> Enum.count() == 0

      permitted_doc =
        (&RecordingsComponents.recordings/1)
        |> render_component(
          source: source,
          items: [],
          timezone: "Etc/UTC",
          can_view_recording_settings: true
        )
        |> LazyHTML.from_fragment()

      assert permitted_doc
             |> LazyHTML.query("#camera-recording-settings-link")
             |> LazyHTML.attribute("href") == ["/settings/recording"]
    end
  end

  describe "E.1 live Policy tab (?tab=policy): table inspection, RBAC, CRUD revisions, and C1a what-if warnings" do
    test "viewer inspects per-camera policies and profile estimates read-only and is denied on policy events" do
      viewer_scope = scope_with_permissions(["settings.recording.view", "devices.view"])
      camera_id = "00000000-0000-4000-8000-000000000401"
      profile_id = "00000000-0000-4000-8000-000000000402"
      policy_id = "00000000-0000-4000-8000-000000000403"

      existing_policy = %CameraRecordingPolicy{
        id: policy_id,
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        mode: :continuous,
        nvr_member: "nvr-0",
        storage: :local_and_archive,
        archive_retention_override_mode: :limited,
        archive_retention_days_override: 14,
        policy_revision: 2,
        camera_source: %{
          id: camera_id,
          display_name: "Synthetic Gate North",
          device_uid: "sr:cam-north-01"
        },
        stream_profile: %{
          id: profile_id,
          profile_name: "main",
          codec_hint: "h264",
          relay_eligible: true,
          metadata: %{"observed_bitrate_bps" => 2_000_000}
        }
      }

      socket =
        viewer_scope
        |> mounted_with_runtime(installed_open_runtime(), %{
          list_policies: fn _ -> [existing_policy] end
        })
        |> assign(:active_tab, "policy")

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()
      table_text = doc |> LazyHTML.query("#recording-policies-table") |> LazyHTML.text() |> normalize_ws()

      assert table_text =~ "Synthetic Gate North (sr:cam-north-01)"
      assert table_text =~ "main (h264)"
      assert table_text =~ "2000 kbit/s (observed)"
      assert table_text =~ "blocks/day"
      # The policy asks for continuous recording, but no recorder is running for it.
      assert table_text =~ "continuous: not recording yet"

      recording_text =
        viewer_scope
        |> mounted_with_runtime(installed_open_runtime(), %{
          list_policies: fn _ -> [existing_policy] end,
          recording_now: fn _ -> MapSet.new([{camera_id, profile_id}]) end
        })
        |> assign(:active_tab, "policy")
        |> render_mounted()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#policy-recording-state-#{policy_id}")
        |> LazyHTML.text()
        |> normalize_ws()

      assert recording_text == "continuous: recording"
      assert table_text =~ "nvr-0"
      assert table_text =~ "local_and_archive"
      assert table_text =~ "limited (14 days)"
      assert table_text =~ "rev 2"

      assert doc |> LazyHTML.query("#save-policy-btn") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#edit-policy-#{policy_id}") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#policy-mode-select[disabled]") |> Enum.count() == 1

      for {event, payload} <- [
            {"preview_policy", %{"policy" => %{"mode" => "continuous"}}},
            {"save_policy", %{"policy" => %{"mode" => "continuous"}}},
            {"edit_policy", %{"id" => policy_id}},
            {"reset_policy_form", %{}}
          ] do
        {:noreply, denied} = RecordingLive.handle_event(event, payload, socket)
        assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "Not authorized"
      end
    end

    test "preview_policy computes live C1a warnings (window < alert threshold, >16 sessions, ~2x throughput) before saving" do
      manager_scope = scope_with_permissions(["settings.recording.manage", "devices.view"])
      cand_cam_id = "00000000-0000-4000-8000-000000000450"
      cand_prof_id = "00000000-0000-4000-8000-000000000451"

      # 16 existing continuous cameras at 4 Mbit/s each on nvr-0
      existing_16 =
        for idx <- 1..16 do
          %CameraRecordingPolicy{
            id: Ecto.UUID.load!(Ecto.UUID.bingenerate()),
            camera_source_id: Ecto.UUID.load!(Ecto.UUID.bingenerate()),
            stream_profile_id: Ecto.UUID.load!(Ecto.UUID.bingenerate()),
            mode: :continuous,
            nvr_member: "nvr-0",
            storage: :local_and_archive,
            archive_retention_override_mode: :inherit,
            policy_revision: 1,
            stream_profile: %{
              id: Ecto.UUID.load!(Ecto.UUID.bingenerate()),
              profile_name: "main-#{idx}",
              codec_hint: "h264",
              relay_eligible: true,
              metadata: %{"observed_bitrate_bps" => 4_000_000}
            }
          }
        end

      cand_profile = %{
        id: cand_prof_id,
        camera_source_id: cand_cam_id,
        profile_name: "main-4m",
        codec_hint: "h264",
        relay_eligible: true,
        metadata: %{"observed_bitrate_bps" => 4_000_000}
      }

      archive_settings =
        struct(RecordingArchiveSettings.default_settings(),
          archive_enabled: true,
          local_window_alert_mode: :enabled,
          local_window_alert_seconds: 3_600,
          object_budget_mode: :limited,
          object_budget_bytes: 500_000_000_000,
          object_capacity_policy: :reap_oldest
        )

      deps = %{
        load_archive_settings_view: fn _ ->
          %{default_overview() | settings: archive_settings, storage_mode: :local_and_archive}
        end,
        list_camera_sources: fn _ ->
          {:ok,
           [
             %{
               id: cand_cam_id,
               display_name: "Synthetic Camera 17",
               device_uid: "sr:cam-17",
               vendor_camera_id: "cam-17"
             }
           ]}
        end,
        list_relay_profiles: fn _scope, ^cand_cam_id -> [cand_profile] end,
        list_policies: fn _ -> existing_16 end,
        what_if_policy_preview: fn s, form, opts ->
          CameraRecordingSettings.what_if_policy_preview(
            s,
            form,
            opts ++
              [
                local_budget_bytes: 20 * 1_073_741_824,
                measured_archive_goodput_bytes_per_sec: 2_000_000.0,
                loaders: %{
                  settings_loader: fn -> {:ok, archive_settings} end,
                  policies_loader: fn -> {:ok, existing_16} end,
                  catalog_loader: fn -> {:ok, []} end,
                  holds_loader: fn -> {:ok, []} end,
                  all_receipts_loader: fn -> {:ok, []} end,
                  storage_settings_loader: fn -> {:ok, []} end
                }
              ]
          )
        end
      }

      socket =
        manager_scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "policy")

      {:noreply, previewed} =
        RecordingLive.handle_event(
          "preview_policy",
          %{
            "policy" => %{
              "camera_source_id" => cand_cam_id,
              "stream_profile_id" => cand_prof_id,
              "mode" => "continuous",
              "nvr_member" => "nvr-0",
              "storage" => "local_and_archive",
              "archive_retention_override_mode" => "limited",
              "archive_retention_days_override" => "60"
            }
          },
          socket
        )

      doc = previewed |> render_mounted() |> LazyHTML.from_fragment()

      est_text = doc |> LazyHTML.query("#policy-profile-estimates") |> LazyHTML.text() |> normalize_ws()
      assert est_text =~ "4000 kbit/s (observed)"
      assert est_text =~ "3433 blocks/day"

      assert doc |> LazyHTML.query("#what-if-member-sessions") |> LazyHTML.text() =~ "17 / 16 sessions"
      assert doc |> LazyHTML.query("#policy-warning-sessions_exceed_limit") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#policy-warning-local_window_below_alert") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#policy-warning-provider_throughput_exceeds_measured") |> Enum.count() == 1

      tp_text = doc |> LazyHTML.query("#what-if-archive-throughput") |> LazyHTML.text() |> normalize_ws()
      assert tp_text =~ "Needed:"
      assert tp_text =~ "Measured:"

      obj_text = doc |> LazyHTML.query("#what-if-object-retention") |> LazyHTML.text() |> normalize_ws()
      assert obj_text =~ "capacity binds"
    end

    test "save_policy creates and updates CameraRecordingPolicy revisions and surfaces field validation errors" do
      manager_scope = scope_with_permissions(["settings.recording.manage", "devices.view"])
      cam_id = "00000000-0000-4000-8000-000000000461"
      prof_id = "00000000-0000-4000-8000-000000000462"

      prof = %{
        id: prof_id,
        camera_source_id: cam_id,
        profile_name: "main",
        codec_hint: "h264",
        relay_eligible: true,
        metadata: %{"observed_bitrate_bps" => 1_000_000}
      }

      store = start_supervised!({Agent, fn -> [] end}, id: :unit_policy_store)

      deps = %{
        list_camera_sources: fn _ ->
          {:ok, [%{id: cam_id, display_name: "Synthetic Dock Cam", device_uid: "sr:dock-1", vendor_camera_id: "dock-1"}]}
        end,
        list_relay_profiles: fn _scope, ^cam_id -> [prof] end,
        list_policies: fn _ -> Agent.get(store, & &1) end,
        what_if_policy_preview: &db_free_what_if_preview/3,
        save_policy: fn s, params ->
          CameraRecordingSettings.save_policy(s, params,
            save_fn: fn attrs ->
              existing =
                Agent.get(store, fn rows ->
                  Enum.find(rows, &(to_string(&1.camera_source_id) == to_string(attrs.camera_source_id)))
                end)

              rev = if existing, do: existing.policy_revision + 1, else: 1
              id = if existing, do: existing.id, else: "00000000-0000-4000-8000-000000000469"

              record = %CameraRecordingPolicy{
                id: id,
                camera_source_id: attrs.camera_source_id,
                stream_profile_id: attrs.stream_profile_id,
                mode: attrs.mode,
                nvr_member: attrs.nvr_member,
                storage: attrs.storage,
                archive_retention_override_mode: attrs.archive_retention_override_mode,
                archive_retention_days_override: attrs.archive_retention_days_override,
                policy_revision: rev,
                stream_profile: prof
              }

              Agent.update(store, fn rows ->
                Enum.reject(rows, &(&1.id == id)) ++ [record]
              end)

              {:ok, record}
            end
          )
        end
      }

      socket =
        manager_scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "policy")

      # Invalid member name and missing limited override days surface field errors
      {:noreply, invalid_socket} =
        RecordingLive.handle_event(
          "save_policy",
          %{
            "policy" => %{
              "camera_source_id" => cam_id,
              "stream_profile_id" => prof_id,
              "mode" => "continuous",
              "nvr_member" => "INVALID_UPPERCASE",
              "storage" => "local_only",
              "archive_retention_override_mode" => "limited",
              "archive_retention_days_override" => ""
            }
          },
          socket
        )

      invalid_doc = invalid_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert invalid_doc |> LazyHTML.query("#policy-error-nvr-member") |> Enum.count() == 1
      assert invalid_doc |> LazyHTML.query("#policy-error-override-days") |> Enum.count() == 1

      # Valid create saves revision 1
      {:noreply, created_socket} =
        RecordingLive.handle_event(
          "save_policy",
          %{
            "policy" => %{
              "camera_source_id" => cam_id,
              "stream_profile_id" => prof_id,
              "mode" => "continuous",
              "nvr_member" => "nvr-0",
              "storage" => "local_only",
              "archive_retention_override_mode" => "inherit",
              "archive_retention_days_override" => ""
            }
          },
          socket
        )

      assert Phoenix.Flash.get(created_socket.assigns.flash, :info) =~ "revision 1"
      created_doc = created_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert created_doc |> LazyHTML.query("#recording-policies-table") |> LazyHTML.text() =~ "rev 1"

      # Edit mode renders hidden camera_source_id + stream_profile_id alongside disabled <select>s
      assert created_doc
             |> LazyHTML.query("#recording-policy-form input[type='hidden'][name='policy[camera_source_id]']")
             |> LazyHTML.attribute("value") == [cam_id]

      assert created_doc
             |> LazyHTML.query("#recording-policy-form input[type='hidden'][name='policy[stream_profile_id]']")
             |> LazyHTML.attribute("value") == [prof_id]

      # Subsequent update omitting disabled select params increments policy_revision to rev 2
      {:noreply, updated_socket} =
        RecordingLive.handle_event(
          "save_policy",
          %{
            "policy" => %{
              "id" => "00000000-0000-4000-8000-000000000469",
              "mode" => "continuous",
              "nvr_member" => "nvr-1",
              "storage" => "local_only",
              "archive_retention_override_mode" => "unlimited",
              "archive_retention_days_override" => ""
            }
          },
          created_socket
        )

      assert Phoenix.Flash.get(updated_socket.assigns.flash, :info) =~ "revision 2"
      updated_doc = updated_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert updated_doc |> LazyHTML.query("#recording-policies-table") |> LazyHTML.text() =~ "rev 2"
      assert updated_doc |> LazyHTML.query("#recording-policies-table") |> LazyHTML.text() =~ "nvr-1"
    end
  end

  describe "C.17 Recorders tab (?tab=recorders): NVRStorageSettings desired vs applied, pinned floor, and RBAC" do
    test "displays install defaults and desired-vs-applied sync states, denies viewer saves, and enforces Core pinned-bytes floor" do
      storage_id = "00000000-0000-4000-8000-000000000511"
      pinned_bytes = 536_870_912

      initial_row = %NVRStorageSettings{
        storage_id: storage_id,
        budget_mode: :custom,
        budget_bytes: 10_737_418_240,
        reserve_mode: :install_default,
        reserve_bytes: nil,
        revision: 2,
        applied_revision: 1,
        sync_state: :refused,
        last_refusal_class: "exceeds_install_ceiling"
      }

      store = start_supervised!({Agent, fn -> [initial_row] end}, id: :unit_storage_settings_store)

      health_fn = fn _ ->
        base = CameraRecordingSettings.default_health_summary()

        member = %{
          storage_id: storage_id,
          member_name: "nvr-0",
          desired_settings: hd(Agent.get(store, & &1)),
          persisted_settings?: true,
          pinned_bytes: pinned_bytes,
          pinned_breakdown: %{p1: pinned_bytes, p2: 0, p3: 0, p4: 0, p5: 0, total_pinned_bytes: pinned_bytes},
          min_custom_budget_bytes: pinned_bytes + 33_554_432,
          local_present_blocks: 4,
          local_present_bytes: pinned_bytes,
          unarchived_local_bytes: pinned_bytes,
          quarantined_local_bytes: 0,
          held_local_pinned_bytes: 0,
          effective_budget_bytes: 10_737_418_240,
          window_projection: %{status: :not_recording, binding_bound: :not_recording},
          time_to_full_seconds: :not_filling,
          assigned_continuous_cameras: 1,
          live_status_state: :unknown_until_nvr_status,
          ledger_state: :unknown_until_nvr_status
        }

        %{base | storage_members: [member]}
      end

      deps = %{
        list_storage_settings: fn _ -> Agent.get(store, & &1) end,
        load_recording_health: health_fn,
        save_storage_settings: fn s, sid, params ->
          CameraRecordingSettings.save_storage_settings(s, sid, params,
            pinned_bytes: pinned_bytes,
            save_fn: fn target_sid, attrs ->
              existing = hd(Agent.get(store, & &1))

              changeset =
                NVRStorageSettings.preview_changeset(target_sid, attrs,
                  existing: existing,
                  scope: s,
                  pinned_bytes: pinned_bytes,
                  loaders: %{
                    settings_loader: fn -> {:ok, RecordingArchiveSettings.default_settings()} end,
                    catalog_loader: fn -> {:ok, []} end,
                    holds_loader: fn -> {:ok, []} end
                  }
                )

              if changeset.valid? do
                {:ok, applied} = Ash.Changeset.apply_attributes(changeset)
                updated = %{applied | revision: existing.revision + 1, sync_state: :pending, last_refusal_class: nil}
                Agent.update(store, fn _ -> [updated] end)
                {:ok, updated}
              else
                {:error, %{errors: changeset.errors}}
              end
            end
          )
        end
      }

      viewer_socket =
        ["settings.recording.view"]
        |> scope_with_permissions()
        |> mounted_with_runtime(installed_open_runtime(), deps)

      viewer_doc = viewer_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert viewer_doc |> LazyHTML.query("#recorders-install-defaults-callout") |> LazyHTML.text() =~
               "85% of PVC minus max(64 MiB, 1%)"

      row_text =
        viewer_doc |> LazyHTML.query("#storage-settings-row-#{storage_id}") |> LazyHTML.text() |> normalize_ws()

      assert row_text =~ "custom: 10 GiB"
      assert row_text =~ "rev 2"
      assert row_text =~ "refused"
      assert row_text =~ "exceeds_install_ceiling"
      assert row_text =~ "Pinned: 512 MiB"
      assert viewer_doc |> LazyHTML.query("#save-storage-settings-btn") |> Enum.count() == 0

      {:noreply, denied_viewer} =
        RecordingLive.handle_event(
          "save_storage_settings",
          %{"storage_settings" => %{"storage_id" => storage_id, "budget_mode" => "install_default"}},
          viewer_socket
        )

      assert Phoenix.Flash.get(denied_viewer.assigns.flash, :error) =~ "Not authorized"

      # Manager attempting budget below pinned_bytes (512 MiB) + 32 MiB = 570,425,344 B is refused
      manager_socket =
        ["settings.recording.manage"]
        |> scope_with_permissions()
        |> mounted_with_runtime(installed_open_runtime(), deps)

      {:noreply, refused_floor} =
        RecordingLive.handle_event(
          "save_storage_settings",
          %{
            "storage_settings" => %{
              "storage_id" => storage_id,
              "budget_mode" => "custom",
              "budget_bytes" => "104857600",
              "reserve_mode" => "install_default",
              "reserve_bytes" => ""
            }
          },
          manager_socket
        )

      refused_doc = refused_floor |> render_mounted() |> LazyHTML.from_fragment()

      assert refused_doc
             |> LazyHTML.query("#storage-settings-error-budget-bytes")
             |> LazyHTML.text() =~ "pinned_bytes=536870912"

      # Manager saving valid custom budget & reserve increments revision to rev 3 (pending sync)
      {:noreply, saved_socket} =
        RecordingLive.handle_event(
          "save_storage_settings",
          %{
            "storage_settings" => %{
              "storage_id" => storage_id,
              "budget_mode" => "custom",
              "budget_bytes" => "21474836480",
              "reserve_mode" => "custom",
              "reserve_bytes" => "134217728"
            }
          },
          manager_socket
        )

      assert Phoenix.Flash.get(saved_socket.assigns.flash, :info) =~ "revision 3"
      saved_doc = saved_socket |> render_mounted() |> LazyHTML.from_fragment()

      updated_row =
        saved_doc |> LazyHTML.query("#storage-settings-row-#{storage_id}") |> LazyHTML.text() |> normalize_ws()

      assert updated_row =~ "custom: 20 GiB"
      assert updated_row =~ "custom: 128 MiB"
      assert updated_row =~ "rev 3"
      assert updated_row =~ "pending"
    end
  end

  describe "E.3 / R.10 live Health tab (?tab=health): CNPG backlog, per-storage window, quarantine, gaps, and alerts" do
    test "renders RecordingHealth.summary/1 across backlog, per-storage capacity, quarantine/dispositions, 24h gaps, and alerts" do
      viewer_scope = scope_with_permissions(["settings.recording.view"])
      storage_id = "00000000-0000-4000-8000-000000000601"
      camera_id = "00000000-0000-4000-8000-000000000602"
      now = ~U[2026-11-16 20:00:00Z]
      now_us = DateTime.to_unix(now, :microsecond)

      settings =
        struct(RecordingArchiveSettings.default_settings(),
          archive_enabled: true
        )

      catalog_entries = [
        %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000611",
          camera_source_id: camera_id,
          storage_id: storage_id,
          block_key: String.duplicate("a", 64),
          local_state: :present,
          archive_state: :awaiting_binding,
          media_bytes: 16_777_216,
          sealed_at: ~U[2026-11-16 18:00:00Z]
        },
        %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000612",
          camera_source_id: camera_id,
          storage_id: storage_id,
          block_key: String.duplicate("b", 64),
          local_state: :present,
          archive_state: :failed_retryable,
          media_bytes: 8_388_608,
          sealed_at: ~U[2026-11-16 19:30:00Z]
        },
        %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000613",
          camera_source_id: camera_id,
          storage_id: storage_id,
          block_key: String.duplicate("c", 64),
          local_state: :present,
          archive_state: :failed_terminal,
          archive_last_error_class: "archive_receipt_conflict",
          media_bytes: 8_388_608,
          sealed_at: ~U[2026-11-16 19:45:00Z]
        },
        %RecordingCatalogEntry{
          id: "00000000-0000-4000-8000-000000000614",
          storage_id: storage_id,
          block_key: String.duplicate("d", 64),
          local_state: :quarantined,
          quarantine_reason: :unattributable,
          quarantined_bytes: 4_194_304,
          archive_state: :not_required,
          local_state_at: ~U[2026-11-16 19:50:00Z]
        }
      ]

      gaps = [
        %RecordingGap{
          id: "00000000-0000-4000-8000-000000000621",
          camera_source_id: camera_id,
          reason: :nvr_refused,
          detail_class: "nvr_spool_budget_exhausted",
          time_basis: :received,
          start_us: now_us - 600_000_000,
          end_us: nil
        },
        %RecordingGap{
          id: "00000000-0000-4000-8000-000000000622",
          camera_source_id: camera_id,
          reason: :handover_overflow,
          time_basis: :received,
          start_us: now_us - 3_600_000_000,
          end_us: now_us - 3_598_000_000
        }
      ]

      dispositions = [
        %RecordingDisposition{
          operation_id: "00000000-0000-4000-8000-000000000631",
          storage_id: storage_id,
          block_key: String.duplicate("e", 64),
          copy: :local,
          reason: :budget,
          step: :verified_absent,
          inserted_at: ~U[2026-11-16 19:10:00Z]
        },
        %RecordingDisposition{
          operation_id: "00000000-0000-4000-8000-000000000632",
          storage_id: storage_id,
          block_key: String.duplicate("f", 64),
          copy: :archive,
          reason: :object_retention,
          step: :failed,
          error_class: "provider_timeout",
          inserted_at: ~U[2026-11-16 19:20:00Z]
        }
      ]

      alerts = [
        %{
          check_id: "nvr.#{storage_id}.archive_backlog_age",
          entity_type: :core,
          state: :unhealthy,
          severity: :warning,
          reason: "Oldest unarchived block exceeds 1 hour",
          metadata: %{},
          recorded_at: ~U[2026-11-16 19:55:00Z]
        }
      ]

      {:ok, health_summary} =
        RecordingHealth.summary(
          scope: viewer_scope,
          now: now,
          member_by_storage_id: %{storage_id => "nvr-0"},
          loaders: %{
            settings_loader: fn -> {:ok, settings} end,
            bindings_loader: fn -> {:ok, []} end,
            all_receipts_loader: fn -> {:ok, []} end,
            catalog_loader: fn -> {:ok, catalog_entries} end,
            holds_loader: fn -> {:ok, []} end,
            blocks_loader: fn -> {:ok, []} end,
            policies_loader: fn ->
              {:ok,
               [
                 %CameraRecordingPolicy{
                   id: "00000000-0000-4000-8000-000000000641",
                   camera_source_id: camera_id,
                   mode: :continuous,
                   nvr_member: "nvr-0",
                   storage: :local_and_archive,
                   stream_profile: %{metadata: %{"observed_bitrate_bps" => 1_000_000}}
                 }
               ]}
            end,
            storage_settings_loader: fn -> {:ok, []} end,
            local_storage_bindings_loader: fn -> {:ok, []} end,
            gaps_loader: fn -> {:ok, gaps} end,
            dispositions_loader: fn -> {:ok, dispositions} end,
            alerts_loader: fn -> {:ok, alerts} end
          }
        )

      socket =
        viewer_scope
        |> mounted_with_runtime(installed_open_runtime(), %{
          load_recording_health: fn _ -> health_summary end
        })
        |> assign(:active_tab, "health")

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      # 1. Backlog card: 3 unarchived (32 MiB), oldest 2 hours, awaiting_binding=1,
      #    failed_retryable=1, failed_terminal=1 highlighted
      assert doc |> LazyHTML.query("#health-backlog-unarchived") |> LazyHTML.text() =~ "3 blocks (32 MiB)"
      assert doc |> LazyHTML.query("#health-backlog-oldest-age") |> LazyHTML.text() =~ "2 hours"
      assert doc |> LazyHTML.query("#health-backlog-awaiting-binding") |> LazyHTML.text() =~ "1"
      assert doc |> LazyHTML.query("#health-backlog-failed-retryable") |> LazyHTML.text() =~ "1"
      assert doc |> LazyHTML.query("#health-failed-terminal-badge") |> LazyHTML.text() =~ "Action required"

      # 2. Storage capacity card: window, assigned continuous cameras, and honest unknown NVR status label
      member_text =
        doc |> LazyHTML.query("#health-storage-member-#{storage_id}") |> LazyHTML.text() |> normalize_ws()

      assert member_text =~ "Local storage holds about"
      assert member_text =~ "Assigned continuous cameras: 1"
      assert member_text =~ "unknown until NVR /v1/status reports"

      # 3. Reconciliation, quarantine & dispositions card
      assert doc |> LazyHTML.query("#health-reconciler-status") |> LazyHTML.text() =~
               "awaiting reconciler"

      assert doc |> LazyHTML.query("#health-quarantined-summary") |> LazyHTML.text() =~
               "1 entries (4 MiB)"

      assert doc |> LazyHTML.query("#health-quarantined-list") |> LazyHTML.text() =~ "unattributable"

      disp_text =
        doc |> LazyHTML.query("#health-dispositions-24h-summary") |> LazyHTML.text() |> normalize_ws()

      assert disp_text =~ "2 steps (1 verified absent)"
      assert disp_text =~ "Failures (24h): 1"

      # 4. 24h RecordingGaps by reason + open gaps + active alerts
      assert doc |> LazyHTML.query("#health-gaps-total-badge") |> LazyHTML.text() =~ "24h total: 2"
      assert doc |> LazyHTML.query("#health-open-gaps-badge") |> LazyHTML.text() =~ "Open gaps: 1"
      assert doc |> LazyHTML.query("#health-gap-reason-nvr_refused") |> LazyHTML.text() =~ "1"
      assert doc |> LazyHTML.query("#health-gap-reason-handover_overflow") |> LazyHTML.text() =~ "1"
      assert doc |> LazyHTML.query("#health-open-gaps-list") |> LazyHTML.text() =~ "nvr_spool_budget_exhausted"
      assert doc |> LazyHTML.query("#health-active-alerts-list") |> LazyHTML.text() =~ "archive_backlog_age"
    end

    test "renders live NVR /v1/status disk usage, free bytes, block count, and ok/degraded ledger state with unreachable fallback" do
      now = ~U[2026-11-16 18:00:00Z]
      sid_ok = "00000000-0000-4000-8000-000000000651"
      sid_degraded = "00000000-0000-4000-8000-000000000652"
      sid_offline = "00000000-0000-4000-8000-000000000653"

      viewer_scope = scope_with_permissions(["settings.recording.view"])

      live_statuses = %{
        sid_ok => %{
          storage_id: sid_ok,
          recovery: %{state: :ready, generation: "00000000-0000-4000-8000-000000000099"},
          inventory: :ready,
          capacity: %{
            used_bytes: 21_474_836_480,
            max_spool_bytes: 85_899_345_920,
            available_bytes: 64_424_509_440,
            reserve_bytes: 1_073_741_824,
            reserved_bytes: 33_554_432,
            reservations: 2,
            blocks: 148,
            max_blocks: 10_000
          },
          max_sessions: 16,
          archive_busy: false,
          release: "1.2.3"
        },
        sid_degraded => %{
          storage_id: sid_degraded,
          recovery: %{state: :ready, generation: "00000000-0000-4000-8000-000000000099"},
          inventory: :mismatch,
          capacity: %{
            used_bytes: 79_456_894_976,
            max_spool_bytes: 85_899_345_920,
            available_bytes: 6_442_450_944,
            reserve_bytes: 1_073_741_824,
            reserved_bytes: 0,
            reservations: 0,
            blocks: 512,
            max_blocks: 10_000
          },
          max_sessions: 16,
          archive_busy: false,
          release: "1.2.3"
        }
      }

      runtime = %{
        recovery_gate: %{state: :open, generation: "00000000-0000-4000-8000-000000000099"},
        core_elx: %{
          reachability: :reachable,
          node: :"core-elx@example.internal",
          supervisor: :enabled,
          nvr_installation: :installed,
          members: [
            %{member: "nvr-0", storage_id: sid_ok},
            %{member: "nvr-1", storage_id: sid_degraded},
            %{member: "nvr-2", storage_id: sid_offline}
          ]
        }
      }

      socket =
        viewer_scope
        |> mounted_with_runtime(runtime, %{
          fetch_nvr_member_statuses: fn _runtime -> live_statuses end,
          load_recording_health: fn scope, opts ->
            {:ok, summary} =
              RecordingHealth.summary(
                Keyword.merge(
                  [
                    scope: scope,
                    now: now,
                    loaders: %{
                      settings_loader: fn -> {:ok, %RecordingArchiveSettings{archive_enabled: false}} end,
                      bindings_loader: fn -> {:ok, []} end,
                      all_receipts_loader: fn -> {:ok, []} end,
                      catalog_loader: fn -> {:ok, []} end,
                      holds_loader: fn -> {:ok, []} end,
                      blocks_loader: fn -> {:ok, []} end,
                      policies_loader: fn -> {:ok, []} end,
                      storage_settings_loader: fn -> {:ok, []} end,
                      local_storage_bindings_loader: fn -> {:ok, []} end,
                      gaps_loader: fn -> {:ok, []} end,
                      dispositions_loader: fn -> {:ok, []} end,
                      alerts_loader: fn -> {:ok, []} end
                    }
                  ],
                  opts
                )
              )

            summary
          end
        })
        |> assign(:active_tab, "health")

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      # 1. Healthy live NVR member: spool used / budget + %, free bytes, blocks, active writers, ledger ok
      ok_card = doc |> LazyHTML.query("#health-storage-member-#{sid_ok}") |> LazyHTML.text() |> normalize_ws()
      assert ok_card =~ "Spool used: 20 GiB / 80 GiB"
      assert ok_card =~ "25%"
      assert ok_card =~ "Free: 60 GiB (reserve 1 GiB)"
      assert ok_card =~ "Ledger blocks: 148 / 10000"
      assert ok_card =~ "Active writers: 2"
      assert ok_card =~ "Disk & ledger: ok"
      refute ok_card =~ "unknown until NVR /v1/status reports"
      assert Enum.count(LazyHTML.query(doc, "#health-storage-member-spool-#{sid_ok}")) == 1

      # 2. Degraded (mismatch) live NVR member: high watermark + degraded badge
      degraded_card =
        doc |> LazyHTML.query("#health-storage-member-#{sid_degraded}") |> LazyHTML.text() |> normalize_ws()

      assert degraded_card =~ "Spool used: 74 GiB / 80 GiB"
      assert degraded_card =~ "92.5%"
      assert degraded_card =~ "Free: 6 GiB"
      assert degraded_card =~ "Ledger blocks: 512 / 10000"
      assert degraded_card =~ "Disk & ledger: degraded (mismatch)"
      refute degraded_card =~ "unknown until NVR /v1/status reports"

      # 3. Unreachable member falls back gracefully to unknown until NVR /v1/status reports
      offline_card =
        doc |> LazyHTML.query("#health-storage-member-#{sid_offline}") |> LazyHTML.text() |> normalize_ws()

      assert offline_card =~ "Disk & ledger: unknown until NVR /v1/status reports"
      assert Enum.empty?(LazyHTML.query(doc, "#health-storage-member-live-#{sid_offline}"))
    end
  end

  describe "R.10 Health & Cameras operator reconciliation UI" do
    test "renders reservation breakdown and enforces operate + hold RBAC on dispositions" do
      now = ~U[2026-11-16 18:00:00Z]
      storage_id = "00000000-0000-4000-8000-000000000701"
      camera_id = "00000000-0000-4000-8000-000000000702"
      profile_id = "00000000-0000-4000-8000-000000000703"
      binding_id = "00000000-0000-4000-8000-000000000704"
      quarantined_id = "00000000-0000-4000-8000-000000000705"
      missing_held_id = "00000000-0000-4000-8000-000000000706"

      quarantined_key = String.duplicate("a7", 32)
      missing_key = String.duplicate("b8", 32)

      quarantined_entry = %RecordingCatalogEntry{
        id: quarantined_id,
        storage_id: storage_id,
        block_key: quarantined_key,
        quarantined_bytes: 8_388_608,
        local_state: :quarantined,
        quarantine_reason: :unattributable,
        quarantine_receipt: %{"source" => "historical_reconcile"},
        quarantine_evidence: %{"reason" => "historical_freeze_no_core_reservation"},
        operator_disposition_state: :awaiting_operator,
        archive_state: :not_required,
        local_state_at: ~U[2026-11-16 17:15:00Z],
        inserted_at: ~U[2026-11-16 17:15:00Z]
      }

      missing_held_entry = %RecordingCatalogEntry{
        id: missing_held_id,
        recording_block_id: "00000000-0000-4000-8000-000000000707",
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        storage_id: storage_id,
        block_key: missing_key,
        archive_binding_id: binding_id,
        timeline_start_us: 1_763_310_000_000_000,
        timeline_end_us: 1_763_310_060_000_000,
        media_bytes: 16_777_216,
        local_state: :present,
        archive_state: :missing,
        inserted_at: ~U[2026-11-16 17:00:00Z]
      }

      active_hold = %RecordingHold{
        id: "00000000-0000-4000-8000-000000000708",
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        start_us: 1_763_310_000_000_000,
        end_us: 1_763_310_060_000_000,
        kind: :legal,
        state: :accepted,
        reason: "Synthetic legal hold covering missing archive entry"
      }

      blocks = [
        %RecordingBlock{
          id: "00000000-0000-4000-8000-000000000711",
          storage_id: storage_id,
          block_key: String.duplicate("11", 32),
          state: :open_local,
          reconciliation_state: :unresolved
        },
        %RecordingBlock{
          id: "00000000-0000-4000-8000-000000000712",
          storage_id: storage_id,
          block_key: String.duplicate("22", 32),
          state: :open_local,
          reconciliation_state: :adopted
        },
        %RecordingBlock{
          id: "00000000-0000-4000-8000-000000000713",
          storage_id: storage_id,
          block_key: String.duplicate("33", 32),
          state: :open_local,
          reconciliation_state: :block_absent
        },
        %RecordingBlock{
          id: "00000000-0000-4000-8000-000000000714",
          storage_id: storage_id,
          block_key: String.duplicate("44", 32),
          state: :open_local,
          reconciliation_state: :unrecoverable_journal
        }
      ]

      {:ok, health_summary} =
        RecordingHealth.summary(
          scope: scope_with_permissions(["settings.recording.view"]),
          now: now,
          loaders: %{
            settings_loader: fn -> {:ok, RecordingArchiveSettings.default_settings()} end,
            bindings_loader: fn ->
              {:ok,
               [
                 %ArchiveBinding{
                   id: binding_id,
                   provisioning_ref: "operator:primary",
                   generation: 1,
                   endpoint: "https://objects.example.com",
                   region: "example-1",
                   bucket: "synthetic-archive",
                   namespace: "recordings/v1"
                 }
               ]}
            end,
            all_receipts_loader: fn -> {:ok, []} end,
            catalog_loader: fn -> {:ok, [quarantined_entry, missing_held_entry]} end,
            holds_loader: fn -> {:ok, [active_hold]} end,
            blocks_loader: fn -> {:ok, blocks} end,
            policies_loader: fn -> {:ok, []} end,
            storage_settings_loader: fn -> {:ok, []} end,
            local_storage_bindings_loader: fn -> {:ok, []} end,
            gaps_loader: fn -> {:ok, []} end,
            dispositions_loader: fn -> {:ok, []} end,
            alerts_loader: fn -> {:ok, []} end
          }
        )

      action_log = start_supervised!({Agent, fn -> [] end}, id: :unit_r10_action_log)

      deps = %{
        load_recording_health: fn _ -> health_summary end,
        request_quarantine_delete: fn s, id, params ->
          CameraRecordingSettings.request_quarantine_delete(s, id, params,
            action_fn: fn target_id, attrs ->
              Agent.update(action_log, &[{:delete, target_id, attrs} | &1])
              {:ok, %{entry: quarantined_entry, disposition: %{id: "disp-del"}}}
            end
          )
        end,
        request_quarantine_export: fn s, id, params ->
          CameraRecordingSettings.request_quarantine_export(s, id, params,
            action_fn: fn target_id, attrs ->
              Agent.update(action_log, &[{:export, target_id, attrs} | &1])
              {:ok, %{entry: quarantined_entry, disposition: %{id: "disp-exp"}}}
            end
          )
        end,
        accept_missing_archive_loss: fn s, id, params ->
          CameraRecordingSettings.accept_missing_archive_loss(s, id, params,
            action_fn: fn target_id, attrs ->
              Agent.update(action_log, &[{:accept_loss, target_id, attrs, s.permissions} | &1])
              {:ok, %{entry: missing_held_entry, disposition: %{id: "disp-loss"}}}
            end
          )
        end
      }

      # 1. Manager (lacks settings.recording.operate) sees reservation breakdown + quarantined rows
      #    read-only and is denied on operator actions
      manager_socket =
        ["settings.recording.manage"]
        |> scope_with_permissions()
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "health")

      manager_doc = manager_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert manager_doc |> LazyHTML.query("#health-reservations-unresolved") |> LazyHTML.text() =~ "1"
      assert manager_doc |> LazyHTML.query("#health-reservations-adopted") |> LazyHTML.text() =~ "1"
      assert manager_doc |> LazyHTML.query("#health-reservations-block-absent") |> LazyHTML.text() =~ "1"
      assert manager_doc |> LazyHTML.query("#health-reservations-unrecoverable-journal") |> LazyHTML.text() =~ "1"

      q_row_text =
        manager_doc
        |> LazyHTML.query("#health-quarantined-entry-#{quarantined_id}")
        |> LazyHTML.text()
        |> normalize_ws()

      assert q_row_text =~ storage_id
      assert q_row_text =~ String.slice(quarantined_key, 0, 16)
      assert q_row_text =~ "unattributable"
      assert q_row_text =~ "historical_freeze_no_core_reservation"
      assert q_row_text =~ "awaiting_operator"

      assert manager_doc |> LazyHTML.query("#request-quarantine-export-#{quarantined_id}") |> Enum.count() == 0
      assert manager_doc |> LazyHTML.query("#quarantine-delete-disclosure-#{quarantined_id}") |> Enum.count() == 0
      assert manager_doc |> LazyHTML.query("#accept-missing-loss-btn-#{missing_held_id}") |> Enum.count() == 0

      for {event, payload} <- [
            {"request_quarantine_delete", %{"delete" => %{"id" => quarantined_id, "confirm" => "true"}}},
            {"request_quarantine_export", %{"id" => quarantined_id}},
            {"accept_missing_archive_loss", %{"id" => missing_held_id}}
          ] do
        {:noreply, denied} = RecordingLive.handle_event(event, payload, manager_socket)
        assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "settings.recording.operate"
      end

      assert Agent.get(action_log, & &1) == []

      # 2. Operator WITHOUT devices.cameras.recordings.hold can export/delete quarantined blocks
      #    (with explicit confirmation required on delete) and is blocked from accepting loss on a held entry
      operator_socket =
        ["settings.recording.operate"]
        |> scope_with_permissions()
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "health")

      operator_doc = operator_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert operator_doc |> LazyHTML.query("#request-quarantine-export-#{quarantined_id}") |> Enum.count() == 1
      assert operator_doc |> LazyHTML.query("#quarantine-delete-disclosure-#{quarantined_id}") |> Enum.count() == 1
      assert operator_doc |> LazyHTML.query("#rearchive-missing-entry-#{missing_held_id}") |> Enum.count() == 1
      assert operator_doc |> LazyHTML.query("#accept-missing-loss-btn-#{missing_held_id}") |> Enum.count() == 0
      assert operator_doc |> LazyHTML.query("#accept-missing-loss-hold-required-#{missing_held_id}") |> Enum.count() == 1

      # Unconfirmed delete is rejected before calling Core
      {:noreply, unconfirmed} =
        RecordingLive.handle_event(
          "request_quarantine_delete",
          %{"delete" => %{"id" => quarantined_id, "confirm" => "false"}},
          operator_socket
        )

      assert Phoenix.Flash.get(unconfirmed.assigns.flash, :error) =~ "Explicit confirmation"
      assert Agent.get(action_log, & &1) == []

      # Confirmed delete + export intent succeed
      {:noreply, exported} =
        RecordingLive.handle_event("request_quarantine_export", %{"id" => quarantined_id}, operator_socket)

      assert Phoenix.Flash.get(exported.assigns.flash, :info) =~ "export / preserve intent"

      {:noreply, deleted} =
        RecordingLive.handle_event(
          "request_quarantine_delete",
          %{"delete" => %{"id" => quarantined_id, "confirm" => "true", "note" => "Verified synthetic orphan"}},
          operator_socket
        )

      assert Phoenix.Flash.get(deleted.assigns.flash, :info) =~ "delete intent"

      # Held missing-archive loss is denied without devices.cameras.recordings.hold
      {:noreply, held_denied} =
        RecordingLive.handle_event(
          "accept_missing_archive_loss",
          %{"id" => missing_held_id},
          operator_socket
        )

      assert Phoenix.Flash.get(held_denied.assigns.flash, :error) =~
               "devices.cameras.recordings.hold"

      # 3. Operator WITH devices.cameras.recordings.hold can accept loss on the held missing entry
      hold_operator_socket =
        ["settings.recording.operate", "devices.cameras.recordings.hold"]
        |> scope_with_permissions()
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "health")

      hold_doc = hold_operator_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert hold_doc |> LazyHTML.query("#accept-missing-loss-btn-#{missing_held_id}") |> Enum.count() == 1

      {:noreply, accepted_loss} =
        RecordingLive.handle_event(
          "accept_missing_archive_loss",
          %{"id" => missing_held_id},
          hold_operator_socket
        )

      assert Phoenix.Flash.get(accepted_loss.assigns.flash, :info) =~
               "Accepted missing archive copy loss"
    end

    test "cameras tab surfaces reconciliation_state labels on uncataloged RecordingBlock rows" do
      scope = scope_with_permissions(["settings.recording.view", "devices.view"])
      camera_id = "00000000-0000-4000-8000-000000000720"
      profile_id = "00000000-0000-4000-8000-000000000721"
      storage_id = "00000000-0000-4000-8000-000000000722"

      unresolved_block = %RecordingBlock{
        id: "00000000-0000-4000-8000-000000000731",
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        storage_id: storage_id,
        block_key: String.duplicate("c1", 32),
        state: :open_local,
        reconciliation_state: :unresolved,
        inserted_at: ~U[2026-11-16 17:50:00Z]
      }

      absent_block = %RecordingBlock{
        id: "00000000-0000-4000-8000-000000000732",
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        storage_id: storage_id,
        block_key: String.duplicate("c2", 32),
        state: :open_local,
        reconciliation_state: :block_absent,
        reconciliation_detail: %{"detail_class" => "nvr_reported_absent"},
        inserted_at: ~U[2026-11-16 17:40:00Z]
      }

      unrecoverable_block = %RecordingBlock{
        id: "00000000-0000-4000-8000-000000000733",
        camera_source_id: camera_id,
        stream_profile_id: profile_id,
        storage_id: storage_id,
        block_key: String.duplicate("c3", 32),
        state: :open_local,
        reconciliation_state: :unrecoverable_journal,
        reconciliation_detail: %{"detail_class" => "corrupt_journal_tail"},
        inserted_at: ~U[2026-11-16 17:30:00Z]
      }

      deps = %{
        list_camera_sources: fn _ ->
          {:ok,
           [
             %{
               id: camera_id,
               display_name: "Synthetic Recon Cam",
               device_uid: "sr:cam-recon-1",
               vendor_camera_id: "cam-recon-1"
             }
           ]}
        end,
        list_relay_profiles: fn _s, ^camera_id ->
          [%{id: profile_id, camera_source_id: camera_id, profile_name: "main", codec_hint: "h264", relay_eligible: true}]
        end,
        list_camera_blocks_page: fn s, ^camera_id, opts ->
          CameraRecordingSettings.list_camera_blocks_page(
            s,
            camera_id,
            opts ++
              [
                loaders: %{
                  blocks_page_loader: fn _cam, _page_opts ->
                    {:ok, [unresolved_block, absent_block, unrecoverable_block]}
                  end,
                  receipts_for_blocks_loader: fn _blocks -> %{} end,
                  catalog_for_blocks_loader: fn _blocks -> {:ok, %{}} end
                }
              ]
          )
        end
      }

      socket =
        scope
        |> mounted_with_runtime(installed_open_runtime(), deps)
        |> assign(:active_tab, "cameras")

      {:noreply, selected} =
        RecordingLive.handle_event("select_camera_context", %{"camera_source_id" => camera_id}, socket)

      doc = selected |> render_mounted() |> LazyHTML.from_fragment()

      assert doc
             |> LazyHTML.query("#block-core-state-#{unresolved_block.id}")
             |> LazyHTML.text()
             |> normalize_ws() == "Core reservation (unresolved)"

      assert doc
             |> LazyHTML.query("#block-core-state-#{absent_block.id}")
             |> LazyHTML.text()
             |> normalize_ws() == "Resolved: block absent"

      assert doc
             |> LazyHTML.query("#block-core-state-#{unrecoverable_block.id}")
             |> LazyHTML.text()
             |> normalize_ws() == "Resolved: unrecoverable journal"

      table_text = doc |> LazyHTML.query("#camera-recording-blocks-stream") |> LazyHTML.text() |> normalize_ws()
      assert table_text =~ "No local block (reconciled)"
      assert table_text =~ "Detail: nvr_reported_absent"
      assert table_text =~ "Unrecoverable journal"
      assert table_text =~ "Detail: corrupt_journal_tail"
    end
  end

  describe "Policy tab UX polish" do
    test "renders NVR member select, auto-selects stream profile, and calms unmeasured what-if" do
      manager_scope = scope_with_permissions(["settings.recording.manage", "devices.view"])
      cam_id = "00000000-0000-4000-8000-000000000801"
      prof_id = "00000000-0000-4000-8000-000000000802"
      member_sid = "00000000-0000-4000-8000-000000000803"

      unmeasured_profile = %{
        id: prof_id,
        camera_source_id: cam_id,
        profile_name: "High",
        codec_hint: "h264",
        relay_eligible: true,
        metadata: %{}
      }

      legacy_policy = %CameraRecordingPolicy{
        id: "00000000-0000-4000-8000-000000000809",
        camera_source_id: "00000000-0000-4000-8000-000000000808",
        stream_profile_id: "00000000-0000-4000-8000-000000000807",
        mode: :continuous,
        nvr_member: "nvr-legacy",
        storage: :local_only,
        policy_revision: 1
      }

      runtime =
        put_in(installed_open_runtime(), [:core_elx, :members], [
          %{member: "nvr-0", storage_id: member_sid}
        ])

      confirmed_local_settings =
        struct(RecordingArchiveSettings.default_settings(),
          local_only_full_policy: :overwrite_oldest
        )

      deps = %{
        load_archive_settings_view: fn _ ->
          %{default_overview() | settings: confirmed_local_settings}
        end,
        list_camera_sources: fn _ ->
          {:ok,
           [
             %{
               id: cam_id,
               display_name: "Synthetic Unmeasured Cam",
               device_uid: "sr:cam-unmeasured-01",
               vendor_camera_id: "cam-unmeasured-01"
             }
           ]}
        end,
        list_relay_profiles: fn _s, ^cam_id -> [unmeasured_profile] end,
        list_policies: fn _ -> [legacy_policy] end,
        what_if_policy_preview: &db_free_what_if_preview/3
      }

      socket = mounted_with_runtime(manager_scope, runtime, deps)

      # Configured runtime member surfaces on ?tab=recorders and ?tab=health before any blocks exist
      recorders_doc = socket |> render_mounted() |> LazyHTML.from_fragment()
      assert recorders_doc |> LazyHTML.query("#storage-settings-row-#{member_sid}") |> LazyHTML.text() =~ "nvr-0"

      health_doc =
        socket
        |> assign(:active_tab, "health")
        |> render_mounted()
        |> LazyHTML.from_fragment()

      assert health_doc |> LazyHTML.query("#health-storage-member-#{member_sid}") |> LazyHTML.text() =~ "nvr-0"

      # Switch to ?tab=policy: <select id="policy-nvr-member-select"> exists, zero text input
      policy_socket = assign(socket, :active_tab, "policy")
      policy_doc = policy_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert policy_doc |> LazyHTML.query("#policy-nvr-member-input") |> Enum.count() == 0
      assert policy_doc |> LazyHTML.query("select#policy-nvr-member-select") |> Enum.count() == 1

      member_select_text =
        policy_doc
        |> LazyHTML.query("#policy-nvr-member-select")
        |> LazyHTML.text()
        |> normalize_ws()

      assert member_select_text =~ "nvr-0 (00000000...)"
      assert member_select_text =~ "nvr-legacy"

      # Picking a camera auto-selects its first relay-eligible stream profile into policy_form
      {:noreply, cam_selected} =
        RecordingLive.handle_event(
          "preview_policy",
          %{"policy" => %{"camera_source_id" => cam_id}},
          policy_socket
        )

      assert cam_selected.assigns.policy_form["stream_profile_id"] == prof_id

      cam_doc = cam_selected |> render_mounted() |> LazyHTML.from_fragment()

      assert cam_doc
             |> LazyHTML.query("#policy-profile-select option[value='#{prof_id}'][selected]")
             |> Enum.count() == 1

      # Switching mode to continuous auto-selects nvr-0 and renders calm unmeasured What-If state
      {:noreply, cont_selected} =
        RecordingLive.handle_event(
          "preview_policy",
          %{"policy" => %{"camera_source_id" => cam_id, "mode" => "continuous"}},
          cam_selected
        )

      assert cont_selected.assigns.policy_form["nvr_member"] == "nvr-0"

      cont_doc = cont_selected |> render_mounted() |> LazyHTML.from_fragment()

      assert cont_doc |> LazyHTML.query("#policy-unmeasured-bitrate-note") |> Enum.count() == 1
      assert cont_doc |> LazyHTML.query("#policy-what-if-warnings") |> Enum.count() == 0

      local_window_text =
        cont_doc |> LazyHTML.query("#what-if-local-window") |> LazyHTML.text() |> normalize_ws()

      assert local_window_text =~ "Unmeasured"
      assert local_window_text =~ "Unknown until recorded"
      refute local_window_text =~ "0 minutes"
      refute local_window_text =~ "budget binds"

      tp_text =
        cont_doc |> LazyHTML.query("#what-if-archive-throughput") |> LazyHTML.text() |> normalize_ws()

      assert tp_text =~ "Pending first recording"
      refute tp_text =~ "Needed: 0 B/s"

      blocks_text =
        cont_doc |> LazyHTML.query("#what-if-blocks-per-day") |> LazyHTML.text() |> normalize_ws()

      assert blocks_text =~ "Unknown until recorded"
      refute blocks_text =~ "0 blocks/day"
    end
  end

  describe "Stage F SaaS storage entitlements, Cloud-managed credentials, and timeline UX addenda" do
    test "hosted install before first entitlement shows waiting banner while self-hosted stays unaffected" do
      scope = scope_with_permissions(["settings.recording.manage"])

      waiting_ent =
        CameraRecordingSettings.normalize_entitlement_view(%{
          hosted?: true,
          applied?: false,
          waiting_for_entitlement?: true,
          archive_jobs_held?: true
        })

      waiting_overview = %{default_overview() | entitlement: waiting_ent}

      hosted_socket =
        mounted_with_runtime(scope, installed_open_runtime(), %{
          load_archive_settings_view: fn _ -> waiting_overview end
        })

      recorders_doc = hosted_socket |> render_mounted() |> LazyHTML.from_fragment()
      banner = LazyHTML.query(recorders_doc, "#retention-waiting-entitlement-banner")
      assert Enum.count(banner) == 1

      assert LazyHTML.text(banner) =~
               "Waiting for a storage entitlement — archive jobs are held while recording continues locally"

      {:noreply, ret_socket} =
        RecordingLive.handle_params(
          %{"tab" => "retention"},
          "/settings/recording?tab=retention",
          hosted_socket
        )

      ret_doc = ret_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert ret_doc |> LazyHTML.query("#retention-waiting-entitlement-banner") |> Enum.count() == 1

      # Self-hosted install has no waiting banner and keeps unlimited archive retention available
      self_hosted_socket = mounted_with_runtime(scope, installed_open_runtime())

      {:noreply, sh_ret} =
        RecordingLive.handle_params(
          %{"tab" => "retention"},
          "/settings/recording?tab=retention",
          self_hosted_socket
        )

      sh_doc = sh_ret |> render_mounted() |> LazyHTML.from_fragment()
      assert sh_doc |> LazyHTML.query("#retention-waiting-entitlement-banner") |> Enum.count() == 0

      assert sh_doc
             |> LazyHTML.query("#retention-archive-mode-select option[value='unlimited']")
             |> Enum.count() == 1

      assert LazyHTML.attribute(
               LazyHTML.query(sh_doc, "#retention-object-budget-mode-select"),
               "disabled"
             ) == []
    end

    test "applied entitlement bounds retention settings, shows configured 400 / effective 365 days, and renders pending decrease banner" do
      scope = scope_with_permissions(["settings.recording.manage"])
      alloc_bytes = 100 * 1_073_741_824
      cap_bytes = 150 * 1_073_741_824
      pending_alloc = 50 * 1_073_741_824
      effective_at = ~U[2026-11-18 12:00:00Z]

      applied_ent =
        CameraRecordingSettings.normalize_entitlement_view(%{
          hosted?: true,
          applied?: true,
          waiting_for_entitlement?: false,
          applied_revision: 7,
          recordings: %{
            enabled: true,
            allocation_bytes: alloc_bytes,
            overage_mode: :metered,
            overage_cap_bytes: cap_bytes,
            hard_limit_bytes: cap_bytes,
            capacity_policy: :reap_oldest,
            retention_max_days: 365,
            retention_default_days: 30,
            max_recording_cameras: 2
          },
          pending: %{
            "effective_at" => "2026-11-18T12:00:00Z",
            "allocation_bytes" => pending_alloc,
            "retention" => %{"max_days" => 90}
          },
          pending_projection: %{
            effective_at: effective_at,
            allocation_bytes: pending_alloc,
            retention_max_days: 90,
            projected_effective_days: 16.0,
            projected_bytes_to_delete: 32_212_254_720
          }
        })

      stored_record = %RecordingArchiveSettings{
        id: "deployment",
        archive_enabled: true,
        archive_retention_mode: :limited,
        archive_retention_days: 400,
        object_budget_mode: :unlimited,
        object_high_water_percent: 90,
        object_low_water_percent: 80
      }

      base_ov = default_overview()

      overview = %{
        base_ov
        | record: stored_record,
          settings:
            Map.merge(base_ov.settings, %{
              archive_retention_mode: :limited,
              archive_retention_days: 400
            }),
          entitlement: applied_ent,
          storage_mode: :local_and_archive,
          object_retention_enforced?: true,
          selected_retention_label: "Cloud archive retention",
          retention_form: CameraRecordingSettings.retention_form_from_settings(stored_record, applied_ent)
      }

      socket =
        mounted_with_runtime(scope, installed_open_runtime(), %{
          load_archive_settings_view: fn _ -> overview end,
          save_retention_settings: fn s, params ->
            CameraRecordingSettings.save_retention_settings(s, params,
              entitlement: applied_ent,
              loaders: %{
                settings_loader: fn -> {:ok, stored_record} end,
                entitlement_loader: fn -> {:ok, applied_ent} end
              },
              save_fn: fn attrs -> {:ok, Map.merge(stored_record, attrs)} end
            )
          end
        })

      {:noreply, ret_socket} =
        RecordingLive.handle_params(
          %{"tab" => "retention"},
          "/settings/recording?tab=retention",
          socket
        )

      doc = ret_socket |> render_mounted() |> LazyHTML.from_fragment()

      # Plan budget & capacity policy are read-only ("Set by plan"), while watermarks stay editable
      assert doc |> LazyHTML.query("#retention-plan-budget-badge") |> LazyHTML.text() =~
               "Set by plan"

      budget_summary =
        doc |> LazyHTML.query("#retention-plan-budget-summary") |> LazyHTML.text() |> normalize_ws()

      assert budget_summary =~ "100 GiB"
      assert budget_summary =~ "150 GiB"
      assert budget_summary =~ "reap_oldest"
      assert budget_summary =~ "Set by plan"

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#retention-object-budget-mode-select"),
               "disabled"
             ) == [""]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#retention-object-budget-bytes-input"),
               "disabled"
             ) == [""]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#retention-object-capacity-policy-select"),
               "disabled"
             ) == [""]

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#retention-object-high-water-input"),
               "disabled"
             ) == []

      assert LazyHTML.attribute(
               LazyHTML.query(doc, "#retention-object-low-water-input"),
               "disabled"
             ) == []

      # Archive retention hides unlimited, shows "limited by your plan" and exact spec string
      assert doc
             |> LazyHTML.query("#retention-archive-mode-select option[value='unlimited']")
             |> Enum.count() == 0

      assert doc
             |> LazyHTML.query("#retention-archive-plan-limit-note")
             |> LazyHTML.text() =~ "limited by your plan"

      assert doc
             |> LazyHTML.query("#retention-archive-effective-plan-cap")
             |> LazyHTML.text()
             |> normalize_ws() == "configured 400 days, effective 365 days (plan maximum)"

      # Pending decrease banner shows new allocation, effective time, and projected retention & deletion
      pending_banner =
        doc
        |> LazyHTML.query("#retention-pending-entitlement-banner")
        |> LazyHTML.text()
        |> normalize_ws()

      assert pending_banner =~ "50 GiB"
      assert pending_banner =~ "90 days"
      assert pending_banner =~ "about 16 days"
      assert pending_banner =~ "30 GiB"
      assert doc |> LazyHTML.query("#retention-pending-effective-at") |> Enum.count() == 1

      # Saving > 365 days is refused with "limited by your plan"
      {:noreply, refused_socket} =
        RecordingLive.handle_event(
          "save_retention_settings",
          %{
            "retention" => %{
              "archive_retention_mode" => "limited",
              "archive_retention_days" => "366"
            }
          },
          ret_socket
        )

      assert refused_socket.assigns.retention_errors[:archive_retention_days] =~
               "limited by your plan"
    end

    test "applied entitlement bounds per-camera overrides and continuous camera count, and marks Cloud credentials read-only" do
      scope =
        scope_with_permissions([
          "settings.recording.manage",
          "settings.credentials.manage",
          "devices.view"
        ])

      applied_ent =
        CameraRecordingSettings.normalize_entitlement_view(%{
          hosted?: true,
          applied?: true,
          recordings: %{
            enabled: true,
            allocation_bytes: 50 * 1_073_741_824,
            hard_limit_bytes: 50 * 1_073_741_824,
            capacity_policy: :stop_archiving,
            retention_max_days: 365,
            max_recording_cameras: 1
          }
        })

      existing_pol = %CameraRecordingPolicy{
        id: "00000000-0000-4000-8000-000000000081",
        camera_source_id: "00000000-0000-4000-8000-000000000061",
        stream_profile_id: "00000000-0000-4000-8000-000000000071",
        mode: :continuous,
        nvr_member: "nvr-0",
        storage: :local_and_archive,
        archive_retention_override_mode: :limited,
        archive_retention_days_override: 400,
        policy_revision: 1
      }

      cloud_binding = %ArchiveBinding{
        id: "00000000-0000-4000-8000-000000000091",
        provisioning_ref: "cloud:managed-bucket",
        generation: 1,
        endpoint: "https://objects.example.com",
        region: "example-1",
        bucket: "synthetic-cloud-bucket",
        namespace: "recordings/v1",
        destination_sha256: String.duplicate("a", 64)
      }

      cloud_cred = %{
        id: "00000000-0000-4000-8000-000000000092",
        name: "Cloud Archive Writer",
        description: "Delivered by ServiceRadar Cloud",
        managed_by: :control_plane
      }

      base_ov = default_overview()

      overview = %{
        base_ov
        | entitlement: applied_ent,
          storage_mode: :local_and_archive,
          active_binding_id: cloud_binding.id,
          active_binding_managed_by_cloud?: true,
          writer_managed_by_cloud?: true,
          selected_writer_label: "Cloud Archive Writer",
          form:
            Map.merge(base_ov.form, %{
              "active_archive_binding_id" => cloud_binding.id,
              "archive_enabled" => "true",
              "writer_credential_secret_id" => cloud_cred.id
            })
      }

      cam2_id = "00000000-0000-4000-8000-000000000062"
      prof2_id = "00000000-0000-4000-8000-000000000072"

      socket =
        mounted_with_runtime(scope, installed_open_runtime(), %{
          load_archive_settings_view: fn _ -> overview end,
          list_archive_bindings: fn _ -> [cloud_binding] end,
          list_enabled_s3_credentials: fn _ -> [cloud_cred] end,
          list_policies: fn _ -> [existing_pol] end,
          save_policy: fn s, params ->
            CameraRecordingSettings.save_policy(s, params,
              entitlement: applied_ent,
              policies: [existing_pol]
            )
          end
        })

      # Archive tab renders Cloud-managed binding & writer credential read-only
      {:noreply, arch_socket} =
        RecordingLive.handle_params(
          %{"tab" => "archive"},
          "/settings/recording?tab=archive",
          socket
        )

      arch_doc = arch_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert arch_doc
             |> LazyHTML.query("#active-binding-cloud-managed-badge")
             |> LazyHTML.text() =~ "Managed by ServiceRadar Cloud"

      assert LazyHTML.attribute(
               LazyHTML.query(arch_doc, "#active-archive-binding-select"),
               "disabled"
             ) == [""]

      assert arch_doc
             |> LazyHTML.query("#writer-credential-cloud-managed-badge")
             |> LazyHTML.text() =~ "Managed by ServiceRadar Cloud"

      assert arch_doc
             |> LazyHTML.query("#writer-credential-disabled-select")
             |> Enum.count() == 1

      assert arch_doc
             |> LazyHTML.query("#archive-credential-cloud-badge-#{cloud_cred.id}")
             |> LazyHTML.text() =~ "Managed by ServiceRadar Cloud"

      # Policy tab renders camera limit badge, capped override display, and refuses camera limit / >365d override
      {:noreply, pol_socket} =
        RecordingLive.handle_params(
          %{"tab" => "policy"},
          "/settings/recording?tab=policy",
          socket
        )

      pol_doc = pol_socket |> render_mounted() |> LazyHTML.from_fragment()

      assert pol_doc
             |> LazyHTML.query("#policy-camera-limit-badge")
             |> LazyHTML.text()
             |> normalize_ws() == "1 / 1 continuous cameras (limited by your plan)"

      assert pol_doc
             |> LazyHTML.query("#recording-policy-row-#{existing_pol.id}")
             |> LazyHTML.text() =~ "configured 400 days, effective 365 days (plan maximum)"

      assert pol_doc
             |> LazyHTML.query("#policy-override-mode-select option[value='unlimited']")
             |> Enum.count() == 0

      {:noreply, cam_limit_refused} =
        RecordingLive.handle_event(
          "save_policy",
          %{
            "policy" => %{
              "camera_source_id" => cam2_id,
              "stream_profile_id" => prof2_id,
              "mode" => "continuous",
              "nvr_member" => "nvr-0",
              "storage" => "local_and_archive",
              "archive_retention_override_mode" => "inherit"
            }
          },
          pol_socket
        )

      assert cam_limit_refused.assigns.policy_errors[:mode] =~ "limited by your plan"
    end

    test "timeline workspace renders datetime-local hold inputs, jump picker, and empty-state explanation when no blocks are playable" do
      source = %{
        id: "00000000-0000-4000-8000-000000000061",
        display_name: "Synthetic Yard Camera",
        device_uid: "sr:yard-01"
      }

      hold_form =
        Phoenix.Component.to_form(
          %{
            "kind" => "investigation",
            "start_at" => "2026-11-16T14:45:00",
            "end_at" => "2026-11-16T15:00:00",
            "start_us" => "1794847500000000",
            "end_us" => "1794848400000000",
            "reason" => "",
            "preset" => "15m"
          },
          as: :hold
        )

      doc =
        (&RecordingsComponents.recordings/1)
        |> render_component(
          source: source,
          items: [],
          mode: :timeline,
          timezone: "America/Chicago",
          can_view_recording_settings: true,
          can_manage_holds: true,
          timeline_coverage: %{
            blocks: [],
            buckets: [],
            gaps: [],
            scheduled_continuous?: true
          },
          timeline_jump_at: "2026-11-16T15:00:00",
          timeline_playlist_path: nil,
          timeline_holds: [],
          hold_form: hold_form
        )
        |> LazyHTML.from_fragment()

      # #262: Blank <video> hidden and clear empty state rendered
      assert doc |> LazyHTML.query("#camera-timeline-empty-state") |> LazyHTML.text() =~
               "No playable footage in selected window"

      # A continuous policy with no recorder running says so, instead of implying recording.
      assert doc |> LazyHTML.query("#camera-timeline-recorder-state") |> LazyHTML.text() |> normalize_ws() ==
               "Continuous policy set: not recording yet"

      assert doc |> LazyHTML.query("#camera-timeline-not-recording") |> LazyHTML.text() =~
               "no recorder is running for it"

      render_timeline = fn coverage, archive_playback_available, timeline_source ->
        (&RecordingsComponents.recordings/1)
        |> render_component(
          source: source,
          items: [],
          mode: :timeline,
          timezone: "America/Chicago",
          can_view_recording_settings: true,
          can_manage_holds: true,
          timeline_source: timeline_source,
          timeline_coverage: Map.merge(%{blocks: [], buckets: [], gaps: [], scheduled_continuous?: true}, coverage),
          archive_playback_available: archive_playback_available,
          timeline_jump_at: "2026-11-16T15:00:00",
          timeline_playlist_path: nil,
          timeline_holds: [],
          hold_form: hold_form
        )
        |> LazyHTML.from_fragment()
      end

      recording = render_timeline.(%{continuous_recording_active?: true}, false, "auto")

      assert recording |> LazyHTML.query("#camera-timeline-recorder-state") |> LazyHTML.text() |> normalize_ws() ==
               "Recording"

      assert recording |> LazyHTML.query("#camera-timeline-not-recording") |> Enum.count() == 0

      archived = %{id: "00000000-0000-4000-8000-000000000611", local_state: :reclaimed, archive_state: :verified}

      missing_no_archive = %{
        id: "00000000-0000-4000-8000-000000000612",
        local_state: :missing,
        archive_state: :not_required
      }

      deleted_block = %{id: "00000000-0000-4000-8000-000000000613", local_state: :reclaimed, archive_state: :deleted}
      local_and_archived = %{id: "00000000-0000-4000-8000-000000000614", local_state: :present, archive_state: :verified}

      archive_only = render_timeline.(%{blocks: [archived]}, false, "auto")

      assert archive_only |> LazyHTML.query("#camera-timeline-archive-only") |> LazyHTML.text() |> normalize_ws() =~
               "Archive copies cannot be played yet"

      assert %{blocks: [archived]}
             |> render_timeline.(true, "auto")
             |> LazyHTML.query("#camera-timeline-archive-only")
             |> Enum.count() == 0

      assert %{blocks: [archived]}
             |> render_timeline.(false, "local")
             |> LazyHTML.query("#camera-timeline-archive-only")
             |> Enum.count() == 0

      assert %{blocks: [local_and_archived]}
             |> render_timeline.(false, "archive")
             |> LazyHTML.query("#camera-timeline-archive-only")
             |> Enum.count() == 1

      assert %{blocks: [local_and_archived]}
             |> render_timeline.(false, "auto")
             |> LazyHTML.query("#camera-timeline-archive-only")
             |> Enum.count() == 0

      for unarchived <- [missing_no_archive, deleted_block], mode <- ["auto", "archive", "local"] do
        rendered = render_timeline.(%{blocks: [unarchived]}, false, mode)

        assert rendered |> LazyHTML.query("#camera-timeline-archive-only") |> Enum.count() == 0

        assert rendered |> LazyHTML.query("#camera-timeline-empty-state") |> LazyHTML.text() =~
                 "No playable footage in selected window"
      end

      [video_class] = LazyHTML.attribute(LazyHTML.query(doc, "#camera-timeline-player"), "class")
      assert video_class =~ "hidden"

      # #261: Human datetime-local hold inputs + presets + jump form, zero raw microsecond prompts
      html_text = LazyHTML.text(doc)
      refute html_text =~ "Start (us UTC)"
      refute html_text =~ "End (us UTC)"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#timeline-hold-start-at"), "type") == [
               "datetime-local"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#timeline-hold-end-at"), "type") == [
               "datetime-local"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#camera-timeline-jump-at"), "type") == [
               "datetime-local"
             ]

      for preset <- ["window", "15m", "1h", "24h"] do
        assert doc |> LazyHTML.query("#timeline-hold-preset-#{preset}") |> Enum.count() == 1
      end
    end

    test "health tab renders Vantage ML workers, queue lag, Ramp 1 -> Ramp 2 routing, and handles heartbeat PubSub updates" do
      scope = scope_with_permissions(["settings.recording.view"])

      initial_vw = %{
        workers: [],
        online_count: 0,
        stale_count: 0,
        queue_lag: %{accessible?: true, pending_count: 3, dispatched_count: 0, oldest_pending_age_seconds: 45},
        routing_mode: :ramp_1_fallback,
        pipelines: [
          %{
            pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
            version: "1.0.0",
            runner: "external_worker",
            capability: "vantage.alpr.v1",
            fallback_runner: "camera_vlm",
            source_mode: "recorded_block",
            active_route: :ramp_1_fallback,
            worker_count: 0
          }
        ]
      }

      :persistent_term.put({__MODULE__, :vw_summary}, initial_vw)

      on_exit(fn -> :persistent_term.erase({__MODULE__, :vw_summary}) end)

      socket =
        mounted_with_runtime(scope, installed_open_runtime(), %{
          load_vantage_worker_summary: fn _scope -> :persistent_term.get({__MODULE__, :vw_summary}) end
        })

      {:noreply, socket} =
        RecordingLive.handle_params(%{"tab" => "health"}, "http://localhost/settings/recording?tab=health", socket)

      html = render_mounted(socket)

      assert html =~ "health-vantage-workers-card"
      assert html =~ "Ramp 1: camera_vlm active"
      assert html =~ "45s"

      updated_vw = %{
        workers: [
          %{
            worker_id: "alpr-node-01",
            worker_kind: "external_rust",
            capabilities: ["vantage.alpr.v1"],
            supported_source_modes: ["recorded_block"],
            execution_backend: "onnx",
            architecture: "arm64",
            model_id: "fast-alpr",
            model_version: "1.0.0",
            active_jobs: 1,
            max_concurrency: 4,
            saturated?: false,
            health: "ready",
            expires_at: ~U[2026-11-25 12:00:30Z],
            online?: true,
            stale?: false
          }
        ],
        online_count: 1,
        stale_count: 0,
        queue_lag: %{accessible?: true, pending_count: 0, dispatched_count: 1, oldest_pending_age_seconds: nil},
        routing_mode: :ramp_2,
        pipelines: [
          %{
            pipeline_id: "io.serviceradar.vantage-alpr.vehicle-plate",
            version: "1.0.0",
            runner: "external_worker",
            capability: "vantage.alpr.v1",
            fallback_runner: "camera_vlm",
            source_mode: "recorded_block",
            active_route: :ramp_2,
            worker_count: 1
          }
        ]
      }

      :persistent_term.put({__MODULE__, :vw_summary}, updated_vw)

      {:noreply, refreshed_socket} =
        RecordingLive.handle_info({:vantage_worker_heartbeat, %{worker_id: "alpr-node-01"}}, socket)

      refreshed_html = render_mounted(refreshed_socket)

      assert refreshed_html =~ "Ramp 2: vantage.worker.v1 active"
      assert refreshed_html =~ "alpr-node-01"
      assert refreshed_html =~ "1/4"
    end
  end

  defp base_socket(scope) do
    path = "/settings/recording"
    view = Catalog.view_for_path(path)
    category = Catalog.category_for_view(view)

    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      router: ServiceRadarWebNGWeb.Router,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
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

  defp mounted_with_runtime(scope, runtime, extra_deps \\ %{}) do
    default_test_deps = %{
      runtime_status: fn -> runtime end,
      authorize_current: &scope_authorize_current/2,
      authorize_current_any: &scope_authorize_current_any/2,
      list_archive_bindings: fn _ -> [] end,
      list_enabled_s3_credentials: fn _ -> [] end,
      load_archive_settings_view: fn _ -> default_overview() end,
      load_retention_usage_summary: fn _ -> CameraRecordingSettings.default_usage_summary() end,
      list_camera_sources: fn _ -> {:ok, []} end,
      list_policies: fn _ -> [] end,
      recording_now: fn _ -> MapSet.new() end,
      what_if_policy_preview: &db_free_what_if_preview/3,
      list_storage_settings: fn _ -> [] end,
      load_recording_health: fn _ -> CameraRecordingSettings.default_health_summary() end,
      load_vantage_worker_summary: fn _ -> ServiceRadarWebNG.CameraVantageWorkers.default_summary() end
    }

    socket =
      assign(
        %{base_socket(scope) | transport_pid: self()},
        :recording_deps,
        Map.merge(default_test_deps, extra_deps)
      )

    {:ok, mounted} = RecordingLive.mount(%{}, %{}, socket)
    mounted
  end

  defp db_free_what_if_preview(scope, policy_form, opts) do
    settings = Keyword.get(opts, :settings, RecordingArchiveSettings.default_settings())

    CameraRecordingSettings.what_if_policy_preview(
      scope,
      policy_form,
      opts ++
        [
          loaders: %{
            settings_loader: fn -> {:ok, settings} end,
            policies_loader: fn -> {:ok, []} end,
            catalog_loader: fn -> {:ok, []} end,
            holds_loader: fn -> {:ok, []} end,
            all_receipts_loader: fn -> {:ok, []} end,
            storage_settings_loader: fn -> {:ok, []} end
          }
        ]
    )
  end

  defp render_mounted(%Socket{} = socket) do
    socket.assigns
    |> RecordingLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp scope_with_permissions(perms, user_id \\ "00000000-0000-4000-8000-000000000022") do
    %Scope{
      user: %{
        id: user_id,
        email: "operator@example.com",
        timezone: "Etc/UTC"
      },
      permissions: MapSet.new(perms)
    }
  end

  defp scope_authorize_current(%Scope{} = scope, perm) when is_binary(perm) do
    if MapSet.member?(scope.permissions, perm),
      do: {:ok, scope},
      else: {:error, :permission_revoked}
  end

  defp scope_authorize_current_any(%Scope{} = scope, perms) when is_list(perms) do
    if Enum.any?(perms, &MapSet.member?(scope.permissions, &1)),
      do: {:ok, scope},
      else: {:error, :permission_revoked}
  end

  defp default_overview do
    CameraRecordingSettings.default_archive_settings_view()
  end

  defp normalize_ws(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp installed_open_runtime do
    %{
      recovery_gate: %{state: :open, generation: "00000000-0000-4000-8000-000000000011"},
      core_elx: %{
        reachability: :reachable,
        node: :"core-elx@example.internal",
        supervisor: :enabled,
        nvr_installation: :installed,
        members: []
      }
    }
  end
end
