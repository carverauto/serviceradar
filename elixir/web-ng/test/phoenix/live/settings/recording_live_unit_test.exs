defmodule ServiceRadarWebNGWeb.Settings.RecordingLiveUnitTest do
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveDestination
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

      # Admin/manager visiting ?tab=archive and ?tab=cameras still sees not-installed notice
      # and never sees empty destination or block lists as if none existed
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
        RecordingLive.handle_params(%{"tab" => "archive"}, "/settings/recording?tab=archive", manager_socket)

      archive_doc = archive_socket |> render_mounted() |> LazyHTML.from_fragment()
      assert archive_doc |> LazyHTML.query("#archive-not-installed-notice") |> Enum.count() == 1
      assert archive_doc |> LazyHTML.query("#archive-bindings-empty") |> Enum.count() == 0
      assert archive_doc |> LazyHTML.query("#archive-bindings-card") |> Enum.count() == 0

      {:noreply, cameras_socket} =
        RecordingLive.handle_params(%{"tab" => "cameras"}, "/settings/recording?tab=cameras", manager_socket)

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

    test "archive tab renders unqualified bindings, split-permission disabled credential selector, disabled-credential warning, and zero secret inputs" do
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
               %{
                 id: "deployment",
                 active_archive_binding_id: binding.id,
                 writer_credential_secret_id: writer_secret_id,
                 reader_credential_secret_id: nil,
                 archive_enabled: true
               }}
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
        |> assign(:credential_issue, settings_view.credential_issue)

      doc = socket |> render_mounted() |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#archive-destinations-list") |> LazyHTML.text() =~
               "https://objects.example.com"

      assert doc |> LazyHTML.query("#archive-destinations-list") |> LazyHTML.text() =~
               "unqualified"

      assert doc |> LazyHTML.query("input[type='password']") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#writer-credential-disabled-select[disabled]") |> Enum.count() == 1

      assert doc |> LazyHTML.query("#writer-credential-disabled-select") |> LazyHTML.text() =~
               "Synthetic archive writer (disabled)"

      assert doc |> LazyHTML.query("#archive-missing-credentials-permission-note") |> LazyHTML.text() =~
               "settings.credentials.manage"

      assert doc |> LazyHTML.query("#archive-credential-unavailable-banner") |> LazyHTML.text() =~
               "disabled"

      assert doc
             |> LazyHTML.query("#archive-credentials-inventory-link")
             |> LazyHTML.attribute("href") == ["/settings/networks/credentials"]
    end

    test "policy, retention, and health tabs render explicit Stage B blocked panels naming aligned prerequisites" do
      socket =
        mounted_with_runtime(
          scope_with_permissions(["settings.recording.view"]),
          installed_open_runtime()
        )

      {:noreply, policy_socket} =
        RecordingLive.handle_params(%{"tab" => "policy"}, "/settings/recording?tab=policy", socket)

      policy_html = render_mounted(policy_socket)
      assert policy_html =~ "recording-policy-blocked-panel"
      assert policy_html =~ "CameraRecordingPolicy"

      {:noreply, retention_socket} =
        RecordingLive.handle_params(
          %{"tab" => "retention"},
          "/settings/recording?tab=retention",
          socket
        )

      retention_html = render_mounted(retention_socket)
      assert retention_html =~ "recording-retention-blocked-panel"
      assert retention_html =~ "max_local_age_seconds"
      assert retention_html =~ "86,400 s"
      assert retention_html =~ "RecordingHold"
      assert retention_html =~ "local_only_full_policy"
      assert retention_html =~ "Local only: no object storage configured"

      {:noreply, health_socket} =
        RecordingLive.handle_params(%{"tab" => "health"}, "/settings/recording?tab=health", socket)

      health_html = render_mounted(health_socket)
      assert health_html =~ "recording-health-blocked-panel"
      assert health_html =~ "metrics.timeseries.recording.*"
      assert health_html =~ "EventWriter"
      assert health_html =~ "NVRReconcileJob"
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

      # Invalid endpoints must fail on :endpoint specifically
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

      # Valid generation 1 registration
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

      # Changing bucket registers generation 2 with a distinct destination_sha256 while preserving gen 1
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

      # Mid-session permission revocation blocks further mutations
      revoked_socket = assign(gen2_socket, :current_scope, scope_with_permissions(["settings.recording.view"]))

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

    test "save_archive_settings enforces split-permission credential rules, disabled secret rejection, and active binding/toggle" do
      binding_id = "00000000-0000-4000-8000-000000000031"
      writer_id = "00000000-0000-4000-8000-000000000041"
      disabled_writer_id = "00000000-0000-4000-8000-000000000042"
      existing_writer_id = "00000000-0000-4000-8000-000000000040"

      persisted_state =
        start_supervised!(
          {Agent,
           fn ->
             %{
               id: "deployment",
               active_archive_binding_id: nil,
               writer_credential_secret_id: existing_writer_id,
               reader_credential_secret_id: nil,
               archive_enabled: false
             }
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

          ^disabled_writer_id ->
            {:ok,
             %{
               id: disabled_writer_id,
               name: "Disabled writer",
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
        list_camera_sources: fn _ -> {:ok, []} end,
        save_archive_settings: fn s, params, can_manage_creds? ->
          CameraRecordingSettings.save_archive_settings(s, params, can_manage_creds?,
            loaders: loaders,
            save_fn: fn attrs ->
              Agent.update(saved_attrs_agent, fn _ -> attrs end)
              updated = Map.merge(Agent.get(persisted_state, & &1), attrs)
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
      assert Agent.get(persisted_state, & &1.writer_credential_secret_id) == existing_writer_id

      # Split-duty operator tampering with credential param is rejected by real CameraRecordingSettings
      {:noreply, rejected_split} =
        RecordingLive.handle_event(
          "save_archive_settings",
          %{
            "settings" => %{
              "active_archive_binding_id" => binding_id,
              "archive_enabled" => "true",
              "writer_credential_secret_id" => writer_id
            }
          },
          split_socket
        )

      assert Phoenix.Flash.get(rejected_split.assigns.flash, :error) =~
               "settings.credentials.manage"

      # 2. Full operator WITH settings.credentials.manage cannot select a disabled credential
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
              "writer_credential_secret_id" => disabled_writer_id,
              "reader_credential_secret_id" => ""
            }
          },
          full_socket
        )

      assert Phoenix.Flash.get(rejected_disabled.assigns.flash, :error) =~ "disabled"

      # 3. Full operator WITH settings.credentials.manage can bind active writer credential
      {:noreply, ok_full} =
        RecordingLive.handle_event(
          "save_archive_settings",
          %{
            "settings" => %{
              "active_archive_binding_id" => binding_id,
              "archive_enabled" => "true",
              "writer_credential_secret_id" => writer_id,
              "reader_credential_secret_id" => ""
            }
          },
          full_socket
        )

      assert Phoenix.Flash.get(ok_full.assigns.flash, :info) =~ "Archive settings saved"

      assert Agent.get(saved_attrs_agent, & &1) == %{
               active_archive_binding_id: binding_id,
               archive_enabled: true,
               writer_credential_secret_id: writer_id,
               reader_credential_secret_id: nil
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
          %{id: camera_id, display_name: "Synthetic Gate Camera", device_uid: "sr:cam-01", vendor_camera_id: "cam-01"}
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

      # Filtering by a profile with 0 rows on page 1 while next_cursor != nil must NOT
      # show the camera-wide empty message above "Load older blocks"
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
  end

  describe "CameraLive.Show and RecordingsComponents links & source labels" do
    test "CameraLive.Show renders Recording & storage link only when user has a recording settings permission" do
      source_id = "00000000-0000-4000-8000-000000000051"

      unpermitted = scope_with_permissions(["devices.view", "devices.cameras.view"])
      {:ok, unpermitted_socket} = CameraShowLive.mount(%{"camera_source_id" => source_id}, %{}, base_socket(unpermitted))

      unpermitted_html =
        unpermitted_socket.assigns |> CameraShowLive.render() |> Safe.to_iodata() |> IO.iodata_to_binary()

      refute unpermitted_html =~ "camera-recording-settings-link"

      permitted = scope_with_permissions(["devices.view", "devices.cameras.view", "settings.recording.view"])
      {:ok, permitted_socket} = CameraShowLive.mount(%{"camera_source_id" => source_id}, %{}, base_socket(permitted))

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
      list_camera_sources: fn _ -> {:ok, []} end
    }

    socket =
      assign(%{base_socket(scope) | transport_pid: self()}, :recording_deps, Map.merge(default_test_deps, extra_deps))

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
    %{
      record: nil,
      storage_mode: :local_only,
      form: CameraRecordingSettings.default_settings_form(),
      active_binding_id: nil,
      selected_writer_label: "None selected",
      selected_reader_label: "Use writer credential (reader role)",
      credential_issue: nil
    }
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
