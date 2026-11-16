defmodule ServiceRadarWebNGWeb.Settings.RecordingLiveUnitTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
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
        list_camera_sources: fn _ -> flunk("disconnected mount must not read cameras") end
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

    test "policy and health tabs remain Stage B blocked while retention tab is live without a Blocked badge" do
      socket =
        mounted_with_runtime(
          scope_with_permissions(["settings.recording.view"]),
          installed_open_runtime()
        )

      tabs_doc = socket |> render_mounted() |> LazyHTML.from_fragment()
      refute tabs_doc |> LazyHTML.query("#recording-tab-retention") |> LazyHTML.text() =~ "Blocked"
      assert tabs_doc |> LazyHTML.query("#recording-tab-policy") |> LazyHTML.text() =~ "Blocked"
      assert tabs_doc |> LazyHTML.query("#recording-tab-health") |> LazyHTML.text() =~ "Blocked"

      {:noreply, policy_socket} =
        RecordingLive.handle_params(%{"tab" => "policy"}, "/settings/recording?tab=policy", socket)

      policy_html = render_mounted(policy_socket)
      assert policy_html =~ "recording-policy-blocked-panel"
      assert policy_html =~ "CameraRecordingPolicy"

      {:noreply, health_socket} =
        RecordingLive.handle_params(%{"tab" => "health"}, "/settings/recording?tab=health", socket)

      health_html = render_mounted(health_socket)
      assert health_html =~ "recording-health-blocked-panel"
      assert health_html =~ "metrics.timeseries.recording.*"
      assert health_html =~ "EventWriter"
      assert health_html =~ "NVRReconcileJob"
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
      list_camera_sources: fn _ -> {:ok, []} end
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
        nvr_installation: :installed
      }
    }
  end
end
