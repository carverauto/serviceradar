defmodule ServiceRadarWebNGWeb.DeviceLiveTest do
  # Writes to shared tables; keep serial to avoid deadlocks in CNPG-backed tests.
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ServiceRadar.Camera.Source, as: CameraSource
  alias ServiceRadar.Camera.StreamProfile, as: CameraStreamProfile
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.EndpointInventoryArtifact
  alias ServiceRadar.Inventory.EndpointInventoryArtifactContent
  alias ServiceRadar.Inventory.EndpointInventoryPackage
  alias ServiceRadar.Inventory.EndpointInventoryScan
  alias ServiceRadar.Inventory.EndpointPackage
  alias ServiceRadar.Inventory.EndpointVulnerabilityMatch
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem
  alias ServiceRadar.Inventory.VulnerabilityAdvisory
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub
  alias ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponents
  alias ServiceRadarWebNGWeb.DeviceLive.Show
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics
  alias ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents
  alias ServiceRadarWebNGWeb.NorthboundActionComponents

  @edge_saturation_profile_source Path.expand(
                                    "../../../../../rust/anomaly-addon/src/addon.rs",
                                    __DIR__
                                  )
  @external_resource @edge_saturation_profile_source

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: ServiceRadarWebNG.Accounts.Scope.for_user(user)
    }
  end

  test "renders devices from ocsf_devices", %{conn: conn} do
    uid = "test-device-live-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    assert html =~ uid
    assert html =~ "test-host"
    assert html =~ "in:devices"
  end

  test "device list and details render device tags", %{conn: conn} do
    uid = "test-device-tags-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "tagged-host",
        is_available: true,
        tags: %{"env" => "prod", "team" => "ops"},
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    assert html =~ "Tags"
    assert html =~ "env=prod"
    assert html =~ "team=ops"

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    summary_html = render_until(view, "tagged-host", 5_000)
    assert summary_html =~ "env=prod"
    assert summary_html =~ "team=ops"
  end

  test "device list reset control restores the first-visit query and keeps Run working", %{
    conn: conn
  } do
    {:ok, view, html} =
      live(conn, ~p"/devices?#{%{q: "in:devices hostname:edge-1 include_inactive:true", limit: 20}}")

    assert html =~ "hostname:edge-1"

    view
    |> element(~s(button[aria-label="Reset SRQL filters"]))
    |> render_click()

    path = assert_patch(view)
    params = path |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()

    assert params["q"] =~ "in:devices"
    refute params["q"] =~ "hostname:edge-1"
    refute Map.has_key?(params, "cursor")
    refute Map.has_key?(params, "page")

    html = render(view)
    refute html =~ "hostname:edge-1"

    view
    |> element(~s(button[aria-label="Toggle query builder"]))
    |> render_click()

    assert has_element?(view, ~s([phx-click="srql_builder_apply"]))

    view
    |> form("#srql-query-bar", %{q: "in:devices include_inactive:true"})
    |> render_submit()

    path = assert_patch(view)
    params = path |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()
    assert params["q"] =~ "in:devices"
    assert params["q"] =~ "include_inactive:true"
  end

  test "device list SRQL submit routes catalog entity changes and drops stale filters", %{
    conn: conn
  } do
    {:ok, view, _html} =
      live(conn, ~p"/devices?#{%{q: "in:devices include_inactive:true", limit: 20}}")

    view
    |> form("#srql-query-bar", %{q: "in:bmp_events include_inactive:true router_ip:192.0.2.1"})
    |> render_submit()

    assert_redirect(
      view,
      ~p"/observability/bmp?#{%{q: "in:bmp_events router_ip:192.0.2.1", limit: 20}}"
    )
  end

  test "device list SRQL submit routes WiFi catalog entities to WiFi inventory", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, ~p"/devices?#{%{q: "in:devices include_inactive:true", limit: 20}}")

    view
    |> form("#srql-query-bar", %{q: "in:wifi_sites site_code:ZZC"})
    |> render_submit()

    assert_redirect(view, ~p"/devices/wifi?#{%{q: "in:wifi_sites site_code:ZZC", limit: 20}}")
  end

  test "renders WiFi inventory view", %{conn: conn} do
    {:ok, _view, html} =
      live(conn, ~p"/devices/wifi?#{%{q: "in:wifi_sites limit:10", limit: 10}}")

    assert html =~ "WiFi Inventory"
    assert html =~ "WiFi Sites"
    assert html =~ "in:wifi_sites"
  end

  test "device list status uses per-agent availability fallback", %{conn: conn} do
    unique = System.unique_integer([:positive])
    uid = "test-device-agent-availability-#{unique}"
    hostname = "agent-available-host-#{unique}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: hostname,
        is_available: false,
        availability_source_agent_id: "agent-live-#{unique}",
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    Repo.insert_all("device_agent_availability", [
      %{
        id: Ecto.UUID.bingenerate(),
        device_uid: uid,
        agent_id: "agent-live-#{unique}",
        agent_name: "live-agent",
        is_available: true,
        checked_at: now,
        response_time_ms: 8,
        open_ports: [],
        sweep_modes_results: %{"icmp" => "success"},
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, view, _html} =
      live(conn, ~p"/devices?#{%{q: "in:devices hostname:#{hostname} limit:10"}}")

    html = render_until(view, "Online", 5_000)

    assert html =~ hostname
    assert html =~ "Online"
    refute html =~ "Offline"
    refute html =~ "Source: any fresh agent"
    refute html =~ "Manual source:"
    refute html =~ "agent-live-#{unique}"
  end

  test "device list marks only registered agent devices with bolt", %{conn: conn} do
    unique = System.unique_integer([:positive])
    uid = "test-device-source-agent-#{unique}"
    hostname = "source-agent-host-#{unique}"
    agent_uid = "test-device-real-agent-#{unique}"
    agent_hostname = "real-agent-host-#{unique}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: hostname,
        agent_id: "collector-agent-#{unique}",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: agent_uid,
        type_id: 1,
        type: "Server",
        hostname: agent_hostname,
        agent_id: "registered-agent-#{unique}",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    Repo.insert_all("ocsf_agents", [
      %{
        uid: "registered-agent-#{unique}",
        name: "Registered Agent #{unique}",
        type_id: 0,
        device_uid: agent_uid,
        host: agent_hostname,
        capabilities: ["icmp"],
        status: "connected",
        is_healthy: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z],
        created_time: ~U[2100-01-01 00:00:00Z],
        modified_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} =
      live(conn, ~p"/devices?#{%{q: "in:devices hostname:#{hostname} limit:10"}}")

    html = render_until(view, hostname, 5_000)

    assert html =~ hostname
    assert source_row = table_row_for(html, hostname)
    refute source_row =~ "hero-bolt"

    {:ok, agent_view, _html} =
      live(conn, ~p"/devices?#{%{q: "in:devices hostname:#{agent_hostname} limit:10"}}")

    agent_html = render_until_row_contains(agent_view, agent_hostname, "hero-bolt", 5_000)

    assert agent_html =~ agent_hostname
    assert agent_row = table_row_for(agent_html, agent_hostname)
    assert agent_row =~ "hero-bolt"
  end

  test "device details header shows the Agent pill only for registered agent devices", %{
    conn: conn
  } do
    unique = System.unique_integer([:positive])
    plain_uid = "test-show-plain-#{unique}"
    plain_hostname = "show-plain-host-#{unique}"
    agent_uid = "test-show-agent-#{unique}"
    agent_hostname = "show-agent-host-#{unique}"
    agent_name = "Show Agent #{unique}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: plain_uid,
        type_id: 1,
        type: "Server",
        hostname: plain_hostname,
        # A populated collector agent_id must NOT mark the device as an agent
        # host; only the ocsf_agents device_uid linkage counts.
        agent_id: "collector-agent-#{unique}",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: agent_uid,
        type_id: 1,
        type: "Server",
        hostname: agent_hostname,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    Repo.insert_all("ocsf_agents", [
      %{
        uid: "show-agent-#{unique}",
        name: agent_name,
        type_id: 0,
        device_uid: agent_uid,
        host: agent_hostname,
        capabilities: ["icmp"],
        status: "connected",
        is_healthy: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z],
        created_time: ~U[2100-01-01 00:00:00Z],
        modified_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, agent_view, _html} = live(conn, ~p"/devices/#{agent_uid}")
    agent_html = render_until(agent_view, "device-agent-pill", 5_000)

    assert agent_html =~ agent_hostname
    assert agent_html =~ ~s(data-testid="device-agent-pill")
    # The summary identity card surfaces the registered agent label.
    assert agent_html =~ agent_name

    {:ok, plain_view, _html} = live(conn, ~p"/devices/#{plain_uid}")
    plain_html = render_until(plain_view, plain_hostname, 5_000)

    assert plain_html =~ plain_hostname
    refute plain_html =~ ~s(data-testid="device-agent-pill")
  end

  test "navigates to the device details page after adding a device", %{conn: conn} do
    unique = System.unique_integer([:positive])
    ip = "203.0.113.#{rem(unique, 250) + 1}"
    expected_uid = manual_device_uid(ip)

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")

    view
    |> element("button[phx-click='open_add_device_modal']", "Add Device")
    |> render_click()

    view
    |> form("#add-device-form", %{
      "device" => %{
        "hostname" => "manual-device-#{unique}.example",
        "ip" => ip,
        "type" => "server",
        "tags" => "source=test"
      }
    })
    |> render_submit()

    assert_redirect(view, ~p"/devices/#{expected_uid}")
  end

  test "renders out of service state in device list and details", %{conn: conn} do
    uid = "test-device-inactive-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "inactive-host",
        is_available: true,
        is_active: false,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, list_view, _list_html} = live(conn, ~p"/devices?limit=10")
    list_html = render_until(list_view, "inactive-host", 10_000)

    assert list_html =~ "inactive-host"
    assert list_html =~ "Out of service"

    {:ok, details_view, _details_html} = live(conn, ~p"/devices/#{uid}")
    details_html = render_until(details_view, "Out of service")

    assert details_html =~ "Out of service"
    assert details_html =~ "In Service"
    assert details_html =~ "No"
  end

  test "disables Run Action when no provider-neutral integrations are configured", %{conn: conn} do
    uid = "test-device-run-task-disabled-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "run-task-disabled-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")

    view
    |> element("input[phx-click='toggle_device_select'][phx-value-uid='#{uid}']")
    |> render_click()

    html = render_until(view, "No launchable action integrations are configured")

    assert html =~ "Run Action"
    assert html =~ "disabled"
  end

  test "launches selected devices through the provider-neutral action modal", %{conn: conn} do
    action = northbound_action(:device)
    with_northbound_stubs(device_actions: [action])

    uid = "test-device-run-task-launch-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "run-task-launch-host",
        ip: "192.0.2.55",
        is_available: true,
        metadata: %{},
        discovery_sources: ["snmp"],
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")
    assert_receive {:northbound_device_actions, _scope}, 1_000

    view
    |> element("input[phx-click='toggle_device_select'][phx-value-uid='#{uid}']")
    |> render_click()

    html =
      view
      |> element("button[phx-click='run_action_for_selection']")
      |> render_click()

    assert html =~ "Disable Switch Port"
    assert html =~ "Change ticket or operator reason"
    refute html =~ "AWX"
    refute html =~ "raw extra_vars"

    view
    |> form("#northbound_action_modal-form", %{
      "action" => %{
        "action_id" => action.id,
        "input" => %{"reason" => "maintenance window"}
      }
    })
    |> render_submit()

    assert_receive {:northbound_create_and_dispatch, attrs, opts}, 1_000

    assert attrs.descriptor_id == action.descriptor_id
    assert attrs.targets == [%{kind: "device", device_uid: uid}]
    assert attrs.input_values == %{"reason" => "maintenance window"}
    assert attrs.metadata["ui_surface"] == "devices"
    assert opts[:actor].email
  end

  test "provider-neutral action targets every selected device", %{conn: conn} do
    action = northbound_action(:device)
    with_northbound_stubs(device_actions: [action])

    suffix = System.unique_integer([:positive])
    first_uid = "test-run-action-first-#{suffix}"
    plain_uid = "test-run-task-plain-#{suffix}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: first_uid,
        type_id: 0,
        hostname: "awx-host",
        ip: "192.0.2.60",
        is_available: true,
        metadata: %{},
        discovery_sources: ["snmp"],
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: plain_uid,
        type_id: 0,
        hostname: "plain-host",
        ip: "192.0.2.61",
        is_available: true,
        metadata: %{},
        discovery_sources: ["snmp"],
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")
    assert_receive {:northbound_device_actions, _scope}, 1_000

    for uid <- [first_uid, plain_uid] do
      view
      |> element("input[phx-click='toggle_device_select'][phx-value-uid='#{uid}']")
      |> render_click()
    end

    html =
      view
      |> element("button[phx-click='run_action_for_selection']")
      |> render_click()

    refute html =~ "AWX-managed"
    refute html =~ "will be skipped"

    view
    |> form("#northbound_action_modal-form", %{
      "action" => %{
        "action_id" => action.id,
        "input" => %{"reason" => "mixed selection"}
      }
    })
    |> render_submit()

    assert_receive {:northbound_create_and_dispatch, attrs, _opts}, 1_000

    assert MapSet.new(attrs.targets) ==
             MapSet.new([
               %{kind: "device", device_uid: first_uid},
               %{kind: "device", device_uid: plain_uid}
             ])
  end

  test "bulk Ansible launch navigates to the canonical reviewed launch route", %{conn: conn} do
    uid = "test-canonical-ansible-launch-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "canonical-launch-host",
        ip: "192.0.2.62",
        is_available: true,
        metadata: %{},
        discovery_sources: ["snmp"],
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")

    view
    |> element("input[phx-click='toggle_device_select'][phx-value-uid='#{uid}']")
    |> render_click()

    view
    |> element("button[phx-click='launch_ansible_for_selection']")
    |> render_click()

    assert_redirect(view, ~p"/ansible/launch?#{%{devices: uid}}")
  end

  test "northbound action modal renders schema-driven input controls" do
    action =
      northbound_action(:device,
        input_schema: %{
          "type" => "object",
          "required" => ["reason"],
          "properties" => %{
            "reason" => %{
              "type" => "string",
              "title" => "Reason",
              "description" => "Change ticket or operator reason",
              "x-order" => 1
            },
            "mode" => %{
              "type" => "string",
              "enum" => ["audit", "enforce"],
              "default" => "audit",
              "x-order" => 2
            },
            "dry_run" => %{"type" => "boolean", "default" => true, "x-order" => 3},
            "limit" => %{"type" => "integer", "default" => 10, "x-order" => 4},
            "extra_vars" => %{"type" => "object", "x-order" => 5}
          }
        }
      )

    html =
      render_component(&NorthboundActionComponents.northbound_action_modal/1,
        id: "northbound_action_modal",
        title: "Run Action",
        subtitle: "Create an action invocation",
        form: to_form(ServiceRadarWebNG.Northbound.ActionForm.default_params(action), as: :action),
        actions: [action],
        action: action,
        error: nil,
        close_event: "close",
        change_event: "change",
        submit_event: "submit"
      )

    assert html =~ ~s(name="action[input][reason]")
    assert html =~ "Change ticket or operator reason"
    assert html =~ ~s(name="action[input][mode]")
    assert html =~ ~s(<option value="audit" selected)
    assert html =~ ~s(type="checkbox")
    assert html =~ ~s(name="action[input][dry_run]")
    assert html =~ ~s(type="number")
    assert html =~ ~s(name="action[input][limit]")
    assert html =~ ~s(name="action[input][extra_vars]")
  end

  test "northbound action history hides nil-like summaries and explains empty state" do
    html =
      render_component(&NorthboundActionComponents.northbound_action_history/1,
        title: "Action History",
        subtitle: "Recent actions",
        entries: [
          %{
            invocation_id: "018f2fd1-f0ff-7cf0-9dc0-000000000999",
            action_label: "Sample Device Lookup",
            provider_name: "Sample Northbound NMS",
            state: :succeeded,
            target_status: :succeeded,
            target_kind: :device,
            device_uid: "sr:b195e",
            inserted_at: ~U[2026-05-17 00:17:02Z],
            target_result: %{"summary" => "nil"},
            result_summary: %{"message" => "null"},
            redacted_input_values: %{"include_neighbors" => false}
          }
        ],
        error: nil,
        notice: nil,
        empty_message: "No action invocations have been recorded yet."
      )

    assert html =~ "Sample Device Lookup"
    assert html =~ "Include Neighbors: No"
    refute html =~ "nil"
    refute html =~ "null"

    empty_html =
      render_component(&NorthboundActionComponents.northbound_action_history/1,
        entries: [],
        error: nil,
        notice: nil,
        empty_message: "No action invocations have been recorded yet."
      )

    assert empty_html =~ "Newly launched actions appear here"
  end

  @tag :web_ng_shared_fixture_db
  test "northbound action history explains long-running progress" do
    html =
      render_component(&NorthboundActionComponents.northbound_action_history/1,
        title: "Action History",
        subtitle: "Recent actions",
        entries: [
          %{
            invocation_id: "018f2fd1-f0ff-7cf0-9dc0-000000000998",
            action_label: "Sample Device Lookup",
            provider_name: "Sample Northbound NMS",
            state: :polling,
            target_status: :result_fetching,
            target_kind: :device,
            device_uid: "sr:b195e",
            inserted_at: ~U[2026-05-17 00:17:02Z],
            next_poll_at: ~U[2026-05-17 00:17:32Z],
            poll_attempt_count: 2,
            target_result: %{},
            result_summary: %{},
            redacted_input_values: %{"execution_mode" => "deferred"}
          }
        ],
        error: nil,
        notice: nil,
        empty_message: "No action invocations have been recorded yet.",
        timezone: "America/Chicago"
      )

    assert html =~ "Result fetching"
    assert html =~ "Fetching external action results"
    assert html =~ "next poll"
    assert html =~ "poll 2"

    next_poll_time =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#northbound-action-018f2fd1-f0ff-7cf0-9dc0-000000000998-next-poll-at")

    assert LazyHTML.attribute(next_poll_time, "datetime") == ["2026-05-17T00:17:32Z"]
    assert LazyHTML.attribute(next_poll_time, "data-user-time-zone") == ["America/Chicago"]
  end

  test "device details SRQL bar submits explicit device searches", %{conn: conn} do
    uid = "test-device-srql-submit-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "pve04.local",
        ip: "192.168.2.10",
        is_available: true,
        metadata: %{"proxmox_candidate" => true},
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")

    view
    |> form("#srql-query-bar", %{q: "in:devices metadata.proxmox_candidate:true"})
    |> render_submit()

    assert_redirect(
      view,
      ~p"/devices?#{%{q: "in:devices metadata.proxmox_candidate:true", limit: 50}}"
    )
  end

  test "device details SRQL bar submits shortcut device searches", %{conn: conn} do
    uid = "test-device-srql-shortcut-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "pve04.local",
        ip: "192.168.2.10",
        is_available: true,
        metadata: %{"proxmox_candidate" => true},
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")

    view
    |> form("#srql-query-bar", %{q: "192.168.2.10"})
    |> render_submit()

    assert_redirect(view, ~p"/devices?#{%{q: ~s(in:devices ip:"192.168.2.10"), limit: 50}}")
  end

  test "shows query-wide matching count in the device results header", %{conn: conn} do
    previous_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :device_live_srql_test_pid)

    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)
    Application.put_env(:serviceradar_web_ng, :device_live_srql_test_pid, self())

    on_exit(fn ->
      restore_env(:srql_module, previous_srql_module)
      restore_env(:device_live_srql_test_pid, previous_test_pid)
    end)

    query = ~s|in:devices vendor_name:"Ubiquiti" sort:last_seen:desc limit:20|

    {:ok, view, _html} = live(conn, ~p"/devices?#{%{q: query, limit: "20"}}")

    assert_receive {:srql_query, ~s|in:devices vendor_name:"Ubiquiti" stats:"count() as total"|},
                   1_000

    assert render(view) =~ "42 total"
  end

  test "shows active fingerprint tab when active banner evidence exists", %{conn: conn} do
    uid = insert_active_fingerprint_device!()

    {:ok, view, html} = live(conn, ~p"/devices/#{uid}?tab=active-fingerprint")

    assert has_element?(
             view,
             "button[phx-click='switch_tab'][phx-value-tab='active-fingerprint']"
           )

    assert html =~ "Active OS fingerprint"
    assert html =~ "Banner-grab matches"
    assert html =~ "Ubuntu Linux"
    assert html =~ "OpenSSH"
    assert html =~ "Postfix"
    assert html =~ "ntpsec"
    assert html =~ "SMTP"
    assert html =~ "NTP"
  end

  test "hides and rejects active fingerprint tab without banner-grab permission", %{conn: _conn} do
    uid = insert_active_fingerprint_device!()
    viewer = AshTestHelpers.viewer_user_fixture()
    conn = log_in_user(build_conn(), viewer)

    {:ok, view, html} = live(conn, ~p"/devices/#{uid}")

    refute has_element?(
             view,
             "button[phx-click='switch_tab'][phx-value-tab='active-fingerprint']"
           )

    refute html =~ "Active OS fingerprint"

    html = render_click(view, "switch_tab", %{"tab" => "active-fingerprint"})

    refute html =~ "Active OS fingerprint"
    refute html =~ "Banner-grab matches"
  end

  test "shows advisory when managed-device count exceeds configured limit", %{conn: conn} do
    previous_limit = Application.get_env(:serviceradar_web_ng, :managed_device_limit)
    Application.put_env(:serviceradar_web_ng, :managed_device_limit, 1)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :managed_device_limit, previous_limit)
    end)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: "advisory-device-#{System.unique_integer([:positive])}",
        type_id: 0,
        hostname: "advisory-host-1",
        is_available: true,
        is_managed: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: "advisory-device-#{System.unique_integer([:positive])}",
        type_id: 0,
        hostname: "advisory-host-2",
        is_available: true,
        is_managed: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")

    assert html =~ "Managed device advisory limit exceeded"
    assert html =~ "configured advisory limit of 1"
    assert html =~ "using 2 managed devices"
  end

  test "does not show advisory when managed-device count stays within configured limit", %{
    conn: conn
  } do
    previous_limit = Application.get_env(:serviceradar_web_ng, :managed_device_limit)
    Application.put_env(:serviceradar_web_ng, :managed_device_limit, 2)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :managed_device_limit, previous_limit)
    end)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: "within-limit-device-#{System.unique_integer([:positive])}",
        type_id: 0,
        hostname: "within-limit-host",
        is_available: true,
        is_managed: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")

    refute html =~ "Managed device advisory limit exceeded"
  end

  test "renders fallback sysmon label when profile data is missing", %{conn: conn} do
    uid = "test-device-sysmon-missing-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    # Ensure the device is considered to have sysmon metrics so the label renders.
    Repo.insert_all("cpu_metrics", [
      %{
        timestamp: now,
        gateway_id: "test-gw",
        core_id: 0,
        usage_percent: 12.3,
        device_id: uid,
        created_at: now
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")
    # Badge should not render when no sysmon profile is assigned
    refute has_element?(view, "[data-testid='sysmon-profile-label']")
  end

  test "auto-refreshes devices list when a device is created", %{conn: conn, scope: scope} do
    uid = "test-device-pubsub-#{System.unique_integer([:positive])}"
    hostname = "pubsub-host-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")
    refute render(view) =~ hostname

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: uid, hostname: hostname, ip: "10.10.10.10"})
      |> Ash.create(scope: scope)

    assert render(view) =~ hostname
  end

  test "shows deleted badge and restore action for deleted devices", %{conn: conn, user: user} do
    promote_user!(user, :admin)
    uid = "test-device-deleted-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "deleted-host",
        is_available: false,
        deleted_at: ~U[2100-01-01 00:00:00Z],
        deleted_by: "system",
        deleted_reason: "test",
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")
    assert html =~ "Deleted"
    assert html =~ "Restore"
  end

  test "renders missing-row state instead of crashing for unknown device uid", %{conn: conn} do
    uid = "missing-device-#{System.unique_integer([:positive])}"

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")

    assert html =~ "No device row returned for this query."
    assert html =~ uid
  end

  test "hides SSH action when remote access SSH is disabled", %{conn: conn} do
    with_remote_access_ssh_enabled(false)

    uid = "test-device-ssh-disabled-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "linux-ssh-disabled",
        metadata: %{"operating_system" => "Ubuntu Linux"},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")
    refute html =~ "/devices/#{uid}/remote-access/ssh"
  end

  test "hides SSH action for Windows-family devices", %{conn: conn} do
    with_remote_access_ssh_enabled(true)

    uid = "test-device-ssh-windows-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "windows-ce-panel",
        metadata: %{"operating_system" => "Windows CE"},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")
    refute html =~ "/devices/#{uid}/remote-access/ssh"
  end

  test "shows SSH action for SSH-capable devices when enabled", %{conn: conn} do
    with_remote_access_ssh_enabled(true)

    uid = "test-device-ssh-linux-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "linux-ssh-enabled",
        metadata: %{"operating_system" => "Ubuntu Linux"},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")
    assert html =~ "/devices/#{uid}/remote-access/ssh"
  end

  test "hides Enable RDP action for non-Windows devices", %{conn: conn} do
    with_remote_access_rdp_enabled(true)

    uid = "test-device-rdp-linux-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "linux-rdp-hidden",
        metadata: %{"operating_system" => "Ubuntu Linux"},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")
    refute html =~ "Enable RDP"
    refute html =~ "/settings/networks/desktop-targets/new"
  end

  test "shows Enable RDP action for Windows devices", %{conn: conn} do
    with_remote_access_rdp_enabled(true)

    uid = "test-device-rdp-windows-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "windows-rdp-enabled",
        metadata: %{"operating_system" => "Microsoft Windows Server 2022"},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")
    assert html =~ "Enable RDP"
    assert html =~ "/settings/networks/desktop-targets/new"
  end

  test "shows RDP action instead of Enable RDP for an authorized exact device target", %{conn: conn} do
    with_remote_access_rdp_enabled(true)

    uid = "test-device-rdp-target-#{System.unique_integer([:positive])}"

    with_remote_access_desktop_targets([
      %{
        id: "rdp-target-exact",
        enabled: true,
        label: "Authorized Windows target",
        device_uid: uid,
        target_kind: "inventory_device",
        target_host: "windows-rdp-target.example.test",
        target_port: 3389,
        agent_id: "agent-rdp-target",
        gateway_id: "gateway-platform",
        credential_custody_mode: "user_present"
      }
    ])

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        type: "Server",
        hostname: "windows-rdp-target",
        metadata: %{"operating_system" => "Microsoft Windows Server 2022"},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")

    assert has_element?(view, "#device-rdp-launch-action[href='/devices/#{uid}/remote-access/rdp']")
    refute has_element?(view, "#device-rdp-enable-action")
  end

  test "auto-refreshes device details when the viewed device is updated", %{
    conn: conn,
    scope: scope
  } do
    uid = "test-device-show-pubsub-#{System.unique_integer([:positive])}"
    initial_hostname = "show-pubsub-initial-#{System.unique_integer([:positive])}"
    updated_hostname = "show-pubsub-updated-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: initial_hostname,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    assert render(view) =~ initial_hostname

    {:ok, device} = Device.get_by_uid(uid, true, scope: scope)

    {:ok, _updated} =
      device
      |> Ash.Changeset.for_update(:update, %{hostname: updated_hostname})
      |> Ash.update(scope: scope)

    _ = :sys.get_state(view.pid)
    assert render(view) =~ updated_hostname
  end

  test "include_deleted query surfaces deleted devices in the list", %{conn: conn, user: user} do
    promote_user!(user, :admin)
    uid = "test-device-deleted-list-#{System.unique_integer([:positive])}"
    hostname = "deleted-host-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: hostname,
        is_available: false,
        deleted_at: ~U[2100-01-01 00:00:00Z],
        deleted_by: "system",
        deleted_reason: "test",
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    refute html =~ hostname

    {:ok, _lv, html} = live(conn, ~p"/devices?q=in:devices%20include_deleted:true&limit=10")
    assert html =~ "in:devices include_deleted:true"
  end

  test "renders SNMP credential override form in edit mode", %{conn: conn} do
    uid = "test-device-snmp-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host-snmp",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")

    view
    |> element("[phx-click='toggle_edit']")
    |> render_click()

    html = render(view)
    assert html =~ "SNMP Credentials Override"
    assert html =~ "Save SNMP Credentials"
  end

  test "renders SNMP system metadata on device details", %{conn: conn} do
    uid = "test-device-snmp-system-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 12,
        hostname: "farm01",
        ip: "192.168.1.1",
        owner: %{"name" => "Network Operations"},
        metadata: %{
          "sys_name" => "farm01",
          "sys_location" => "MDF Rack A",
          "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
          "sys_contact" => "Network Operations"
        },
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "CPU", 10_000)

    assert html =~ "SNMP Name"
    assert html =~ "farm01"
    assert html =~ "SNMP Owner"
    assert html =~ "Network Operations"
    assert html =~ "SNMP Location"
    assert html =~ "MDF Rack A"
    assert html =~ "SNMP Description"
    assert html =~ "Ubiquiti UniFi UDM-Pro"
    assert html =~ "min-w-0 flex-1 break-words whitespace-normal"
  end

  test "prefers snmp_* metadata aliases for SNMP panel fields", %{conn: conn} do
    uid = "test-device-snmp-aliases-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 12,
        hostname: "farm01",
        ip: "192.168.1.1",
        metadata: %{
          "snmp_name" => "farm01-snmp",
          "sys_name" => "farm01-sys",
          "snmp_owner" => "NOC Team",
          "snmp_location" => "Datacenter B",
          "snmp_description" => "Ubiquiti UniFi UDM-Pro-Max 4.4.6"
        },
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "CPU")

    assert html =~ "farm01-snmp"
    assert html =~ "NOC Team"
    assert html =~ "Datacenter B"
    assert html =~ "UDM-Pro-Max 4.4.6"
    refute html =~ "farm01-sys"
  end

  test "renders SNMP panel labels even when SNMP metadata values are missing", %{conn: conn} do
    uid = "test-device-snmp-empty-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "host-no-snmp",
        ip: "192.168.50.10",
        metadata: %{},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "CPU", 10_000)

    assert html =~ "SNMP Name"
    assert html =~ "SNMP Owner"
    assert html =~ "SNMP Location"
    assert html =~ "SNMP Description"
  end

  test "renders curated device metadata without dumping internal keys", %{conn: conn} do
    uid = "test-device-curated-metadata-#{System.unique_integer([:positive])}"

    metadata = %{
      "integration_type" => "armis",
      "source_device_id" => "42",
      "sync_service_id" => "agent-dusk01",
      "controller_name" => "Dusk UniFi",
      "controller_url" => "https://unifi.example.local",
      "unifi_api_names" => "tonka01",
      "unifi_api_urls" => "https://192.168.10.1/proxy/network/integration/v1",
      "mikrotik_api_names" => "edge-mikrotik",
      "mikrotik_api_urls" => "http://192.168.6.167/rest",
      "proxmox_candidate_probe_enabled" => true,
      "sys_name" => "aruba-24g-02",
      "sys_location" => "Minnetonka, MN",
      "sys_contact" => "support@example.test",
      "sys_object_id" => ".1.3.6.1.4.1.11.2.3.7.11.153",
      "uptime" => 168_519_247,
      "sys_descr" => "HP J9727A 2920-24G-PoE+ Switch",
      "device_role" => "gateway",
      "bridge_port_count" => 8,
      "type" => "Tablet",
      "category" => "OT",
      "risk_score" => "7",
      "is_active" => false,
      "source_tags" => "managed,ot",
      "boundary_names" => "All OT Boundaries",
      "serial_numbers" => "SN-123",
      "purdue_level" => "2.5",
      "visibility" => "Full",
      "site" => %{"name" => "Plant 7"},
      "network_interfaces" => [%{"name" => "eth0"}, %{"name" => "eth1"}],
      "netbox_device_id" => "nb-123",
      "tenant_name" => "Manufacturing",
      "rack_name" => "MDF-A",
      "asset_tag" => "asset-7799",
      "classification_source" => "unifi",
      "classification_confidence" => 0.94,
      "classification_reason" => "matched UniFi gateway role",
      "alt_ip:10.0.0.1" => true,
      "alt_ip:192.168.10.1" => true,
      "alt_mac:0eea1432d277" => true,
      "_alias_last_seen_at" => "2026-05-16T18:00:00Z",
      "debug_unifi_payload" => %{"raw" => "payload"},
      "device_id" => "raw-integration-id"
    }

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 12,
        hostname: "metadata-host",
        ip: "192.168.1.20",
        metadata: metadata,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "Dusk UniFi", 10_000)

    curated_html =
      render_component(&VisibilityComponents.metadata_summary_section/1,
        device_row: %{"metadata" => metadata}
      )

    assert html =~ "Metadata"
    assert html =~ "UniFi"
    assert html =~ "Armis"
    assert html =~ "NetBox"
    assert html =~ "SNMP"
    assert html =~ "Dusk UniFi"
    assert html =~ "gateway"
    assert html =~ "Tablet"
    refute curated_html =~ "Proxmox"
    refute curated_html =~ "Candidate probe"
    assert html =~ "aruba-24g-02"
    assert html =~ "Minnetonka, MN"
    assert html =~ ".1.3.6.1.4.1.11.2.3.7.11.153"
    assert html =~ "19d 12h"
    assert html =~ "All OT Boundaries"
    assert html =~ "Risk Score"
    assert html =~ "7 / 10"
    assert html =~ "In Service"
    assert html =~ "SN-123"
    assert html =~ "Plant 7"
    assert html =~ "nb-123"
    assert html =~ "Manufacturing"
    assert html =~ "MDF-A"
    assert html =~ "matched UniFi gateway role"

    refute curated_html =~ "Additional metadata keys"
    refute curated_html =~ "Other Metadata"
    refute curated_html =~ "MikroTik"
    refute curated_html =~ "tonka01"
    refute curated_html =~ "edge-mikrotik"
    refute curated_html =~ "10.0.0.1"
    refute curated_html =~ "192.168.10.1"
    refute curated_html =~ "0eea1432d277"
    refute curated_html =~ "Integration Details"
    refute curated_html =~ "asset-7799"
    refute curated_html =~ "_alias_last_seen_at"
    refute curated_html =~ "debug_unifi_payload"
    refute curated_html =~ "raw-integration-id"
  end

  test "device details lists every discovery source a merged device was seen through", %{
    conn: conn
  } do
    uid = "test-device-multi-source-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 1,
        hostname: "multi-source-host",
        ip: "192.168.7.42",
        agent_id: "agent-multi-src",
        discovery_sources: ["agent", "awx", "sweep", "hypervisor_enrichment"],
        metadata: %{
          "integration_type" => "hypervisor",
          "query_label" => "prod-inventory",
          "sync_service_id" => "awx-prod",
          "source_device_id" => "77",
          "provider" => "proxmox",
          "scan_available_count" => 3,
          "scan_availability_percent" => "100"
        },
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "Discovery Sources", 10_000)

    # Every merged discovery source is enumerated, not just one canonical source.
    assert html =~ "Discovery Sources"
    assert html =~ "Agent"
    assert html =~ "AWX / Ansible"
    assert html =~ "Sweep"
    assert html =~ "Hypervisor Enrichment"

    # The compact chip section is a summary, not a stack of cards; the old
    # generic filler subtitle must be gone.
    refute html =~ "Discovered through this source."

    # Each source's curated metadata is surfaced on the chip's hover tooltip.
    assert html =~ "agent-multi-src"
    assert html =~ "prod-inventory"
    assert html =~ "awx-prod"
    assert html =~ "proxmox"
  end

  test "discovery sources section renders a compact chip per source with curated metadata on hover" do
    html =
      render_component(
        &DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "agent_id" => "agent-abc",
          # `sweep` carries no scoped metadata here, so it renders as a plain
          # chip (no tooltip / filler), while the others get a hover summary.
          "discovery_sources" => ["agent", "armis", "netbox", "sweep"],
          "metadata" => %{
            "armis_device_id" => "42",
            "armis_risk_level" => "High",
            "netbox_device_id" => "nb-9"
          }
        }
      )

    assert html =~ "Discovery Sources"

    # Every source still appears as a chip.
    assert html =~ "Agent"
    assert html =~ "Armis"
    assert html =~ "NetBox"
    assert html =~ "Sweep"

    # Compact chip markup replaced the big per-source cards + generic filler.
    assert html =~ "rounded-full"
    refute html =~ "Discovered through this source."

    # Sources with metadata expose it via a hover tooltip (data-tip), not a card.
    assert html =~ "data-tip"
    assert html =~ "agent-abc"
    assert html =~ "High"
    assert html =~ "nb-9"
  end

  test "discovery sources section is empty when no sources are present" do
    html =
      render_component(
        &DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{"metadata" => %{}}
      )

    refute html =~ "Discovery Sources"
  end

  test "metadata summary renders Proxmox only for device-level candidate evidence" do
    generic_html =
      render_component(&Show.metadata_summary_section/1,
        device_row: %{
          "metadata" => %{
            "source" => "snmp",
            "sys_name" => "tonka01",
            "proxmox_candidate_probe_enabled" => "true"
          }
        }
      )

    refute generic_html =~ "Proxmox"
    refute generic_html =~ "Candidate probe"

    candidate_html =
      render_component(&Show.metadata_summary_section/1,
        device_row: %{
          "metadata" => %{
            "source" => "proxmox-candidate",
            "proxmox_candidate" => "true",
            "proxmox_candidate_evidence" => "pve_web_fingerprint",
            "proxmox_candidate_service" => "pve-web-ui",
            "proxmox_candidate_port" => "8006",
            "proxmox_candidate_title" => "pve01"
          }
        }
      )

    assert candidate_html =~ "Proxmox"
    assert candidate_html =~ "Candidate"
    assert candidate_html =~ "pve_web_fingerprint"
    assert candidate_html =~ "pve-web-ui"
    assert candidate_html =~ "8006"
    assert candidate_html =~ "pve01"
  end

  test "process listeners tab renders agent-host local process snapshots" do
    html =
      render_component(&VisibilityComponents.process_listeners_tab_content/1,
        device_row: %{
          "agent_device" => true,
          "agent_labels" => ["agent-1"],
          "metadata" => %{
            "local_processes" =>
              Jason.encode!(%{
                "fingerprint" => "snapshot-1",
                "observed_at_unix_nano" => 1_779_963_904_000_000_123,
                "entries" => [
                  %{
                    "local_ip" => "127.0.0.1",
                    "local_port" => 5432,
                    "transport_protocol" => "tcp",
                    "pid" => 4242,
                    "tgid" => 4242,
                    "uid" => 26,
                    "gid" => 26,
                    "comm" => "postgres",
                    "redacted_cmdline" => ["postgres", "--config=redacted"],
                    "container_id" => "container-abc123456"
                  }
                ]
              })
          }
        }
      )

    assert html =~ "Process Listeners"
    assert html =~ "snapshot-1"
    assert html =~ "1 sockets"
    assert html =~ "127.0.0.1:5432"
    assert html =~ "TCP"
    assert html =~ "postgres"
    assert html =~ "4242"
    assert html =~ "26/26"
    # Container ids render truncated to 12 chars (process_listener_container/1).
    assert html =~ "container-ab"
    assert html =~ "--config=redacted"
  end

  test "keeps SNMP fallback-derived classification out of noisy list badges", %{conn: conn} do
    uid = "test-device-snmp-fallback-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 12,
        type: "Router",
        hostname: "fallback-router",
        ip: "192.168.60.1",
        vendor_name: "Ubiquiti",
        model: "UDM-Pro-Max 4.4.6",
        metadata: %{
          "sys_descr" => "Ubiquiti UniFi UDM-Pro-Max 4.4.6 Linux 4.19.152 al324",
          "sys_object_id" => "1.3.6.1.4.1.8072.3.2.10"
        },
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _list_view, list_html} = live(conn, ~p"/devices?limit=10")
    assert list_html =~ "fallback-router"
    refute list_html =~ "SNMP Fallback"
    refute list_html =~ "Fallback"

    {:ok, _details_view, details_html} = live(conn, ~p"/devices/#{uid}")
    assert details_html =~ "Classification"
    assert details_html =~ "SNMP fallback-derived"
  end

  test "renders sysmon cpu header gauge and process/memory/disk sections", %{conn: conn} do
    uid = "test-device-sysmon-metrics-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host-sysmon",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    Repo.insert_all("timeseries_metrics", [
      timeseries_metric_row(now, uid, "cpu.usage_percent", "sysmon.cpu", 42.4, "%"),
      timeseries_metric_row(now, uid, "memory.used_percent", "sysmon.memory", 33.3, "%"),
      timeseries_metric_row(now, uid, "disk.used_percent", "sysmon.disk", 50.0, "%"),
      timeseries_metric_row(now, uid, "process.count", "sysmon.process", 1.0, "{process}"),
      timeseries_metric_row(now, uid, "process.cpu_usage", "sysmon.process", 12.3, "%",
        tags: %{"pid" => "4242", "name" => "nginx", "status" => "Running"}
      ),
      timeseries_metric_row(now, uid, "process.memory_usage", "sysmon.process", 1_048_576, "By",
        tags: %{"pid" => "4242", "name" => "nginx", "status" => "Running"}
      )
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "CPU", 10_000)

    assert html =~ "CPU"
    assert html =~ "42.4%"
    assert html =~ "Memory"
    assert html =~ "Disk"
    assert html =~ "Process Count"
    assert html =~ "avg observed processes"
    assert html =~ "Processes"
    assert html =~ "CPU Trend"
    assert html =~ "nginx"
  end

  test "renders sysmon sections using host_id fallback when device_id is skewed", %{conn: conn} do
    unique = System.unique_integer([:positive])
    uid = "sr:test-device-sysmon-host-fallback-#{unique}"
    host_id = "sysmon-host-fallback-#{unique}"
    skewed_device_id = "sr:collapsed-sysmon-#{unique}"
    gateway_id = "test-gw-host-fallback-#{unique}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: host_id,
        agent_id: host_id,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    Repo.insert_all("timeseries_metrics", [
      timeseries_metric_row(now, skewed_device_id, "cpu.usage_percent", "sysmon.cpu", 57.8, "%",
        gateway_id: gateway_id,
        agent_id: host_id
      ),
      timeseries_metric_row(now, skewed_device_id, "memory.used_percent", "sysmon.memory", 33.3, "%",
        gateway_id: gateway_id,
        agent_id: host_id
      ),
      timeseries_metric_row(now, skewed_device_id, "disk.used_percent", "sysmon.disk", 50.0, "%",
        gateway_id: gateway_id,
        agent_id: host_id
      ),
      timeseries_metric_row(now, skewed_device_id, "process.count", "sysmon.process", 1.0, "{process}",
        gateway_id: gateway_id,
        agent_id: host_id
      ),
      timeseries_metric_row(now, skewed_device_id, "process.cpu_usage", "sysmon.process", 19.6, "%",
        gateway_id: gateway_id,
        agent_id: host_id,
        tags: %{"pid" => "5252", "name" => "beam.smp", "status" => "Running"}
      ),
      timeseries_metric_row(now, skewed_device_id, "process.memory_usage", "sysmon.process", 2_097_152, "By",
        gateway_id: gateway_id,
        agent_id: host_id,
        tags: %{"pid" => "5252", "name" => "beam.smp", "status" => "Running"}
      )
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "CPU", 10_000)

    assert html =~ "57.8%"
    assert html =~ "Memory"
    assert html =~ "Disk"
    assert html =~ "Processes"
    assert html =~ "beam.smp"
  end

  test "renders device anomaly and capacity section using identity fallback", %{conn: conn} do
    unique = System.unique_integer([:positive])
    uid = "sr:test-device-anomaly-fallback-#{unique}"
    hostname = "anomaly-fallback-host-#{unique}"
    agent_id = "agent-anomaly-fallback-#{unique}"
    previous_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    previous_responder = Application.get_env(:serviceradar_web_ng, :device_live_srql_responder)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :device_live_srql_test_pid)

    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)
    Application.put_env(:serviceradar_web_ng, :device_live_srql_test_pid, self())

    Application.put_env(:serviceradar_web_ng, :device_live_srql_responder, fn query, _opts ->
      cond do
        String.contains?(query, "in:devices") ->
          {:ok,
           %{
             "results" => [
               %{
                 "uid" => uid,
                 "hostname" => hostname,
                 "agent_id" => agent_id,
                 "is_available" => true
               }
             ],
             "pagination" => %{}
           }}

        String.contains?(query, "in:events") and
          String.contains?(query, "source_type:anomaly_detection") and
            String.contains?(query, ~s|source_device_uid:"#{uid}"|) ->
          {:ok,
           %{
             "results" => [
               %{
                 "time" => "2026-06-13T12:00:00Z",
                 "message" => "breach pending confirmation at 3/5 consecutive anomalous slots",
                 "metric_class" => "cpu",
                 "metric_name" => "cpu.usage_percent",
                 "source_type" => "anomaly_detection",
                 "severity" => "High",
                 "metadata" => %{
                   "finding_info" => %{"title" => "CPU saturation anomaly"},
                   "source_identity" => %{
                     "metric_name" => "cpu.usage_percent",
                     "series_key" => "sysmon:#{uid}:cpu.usage_percent",
                     "interface_uid" => "eth0",
                     "if_index" => 2
                   },
                   "anomaly" => %{"value" => 97.4, "score" => 4.8}
                 }
               }
             ],
             "pagination" => %{}
           }}

        String.contains?(query, "in:events") and String.contains?(query, ~s|agent_id:"#{agent_id}"|) ->
          {:ok,
           %{
             "results" => [
               %{
                 "time" => "2026-06-13T12:05:00Z",
                 "message" => "Unexpected connection to K8s API Server from container",
                 "metric_class" => nil,
                 "source_type" => "falco",
                 "severity" => "Low"
               }
             ],
             "pagination" => %{}
           }}

        String.contains?(query, "in:capacity_forecasts") and
            String.contains?(query, ~s|resource_id:"#{uid}"|) ->
          {:ok,
           %{
             "results" => [
               %{
                 "resource_label" => "Filesystem /",
                 "resource_id" => uid,
                 "metric_name" => "disk.used_percent",
                 "status" => "projected",
                 "current_value" => 72.5,
                 "projected_value" => 91.2,
                 "projected_exhaustion_at" => "2026-06-20T00:00:00Z",
                 "horizon_seconds" => 604_800,
                 "exhaustion_threshold" => 95.0,
                 "confidence" => 0.82
               }
             ],
             "pagination" => %{}
           }}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}}}
      end
    end)

    on_exit(fn ->
      restore_env(:srql_module, previous_srql_module)
      restore_env(:device_live_srql_responder, previous_responder)
      restore_env(:device_live_srql_test_pid, previous_test_pid)
    end)

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "Anomaly &amp; Capacity", 10_000)
    queries = drain_srql_queries()

    assert html =~ "CPU saturation anomaly"
    assert html =~ "breach pending confirmation"
    assert html =~ "cpu.usage_percent"
    assert html =~ "eth0 / ifIndex 2"
    assert html =~ "value 97.40"
    assert html =~ "score 4.80"
    refute html =~ "Unexpected connection to K8s API Server"
    assert html =~ "Filesystem /"
    assert html =~ "threshold 95.00%"
    assert html =~ "headroom 22.50%"
    assert html =~ "open_anomaly_capacity_detail"
    assert html =~ "device source_device_uid=#{uid}"
    assert html =~ "device resource_id=#{uid}"
    assert html =~ "active"
    assert Enum.any?(queries, &String.contains?(&1, ~s|source_device_uid:"#{uid}"|))
    assert Enum.any?(queries, &String.contains?(&1, ~s|resource_id:"#{uid}"|))
    refute Enum.any?(queries, &String.contains?(&1, "agent_id:"))
    refute Enum.any?(queries, &String.contains?(&1, "host_id:"))
    refute Enum.any?(queries, &String.contains?(&1, "resource_key:"))
  end

  test "keeps device anomaly and capacity section visible when no rows exist", %{conn: conn} do
    unique = System.unique_integer([:positive])
    uid = "sr:test-device-anomaly-empty-#{unique}"
    hostname = "anomaly-empty-host-#{unique}"
    previous_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)
    previous_responder = Application.get_env(:serviceradar_web_ng, :device_live_srql_responder)

    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    Application.put_env(:serviceradar_web_ng, :device_live_srql_responder, fn query, _opts ->
      if String.contains?(query, "in:devices") do
        {:ok,
         %{
           "results" => [
             %{
               "uid" => uid,
               "hostname" => hostname,
               "is_available" => true
             }
           ],
           "pagination" => %{}
         }}
      else
        {:ok, %{"results" => [], "pagination" => %{}}}
      end
    end)

    on_exit(fn ->
      restore_env(:srql_module, previous_srql_module)
      restore_env(:device_live_srql_responder, previous_responder)
    end)

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_until(view, "Anomaly &amp; Capacity", 10_000)

    assert html =~ "No anomaly findings found for this device in the last 7 days."
    assert html =~ "No capacity forecasts found for this device yet."
    assert html =~ "normal"
  end

  test "sysmon metric sections carry section-level anomaly annotations and selected finding marker" do
    peak_dt = ~U[2026-06-19 12:03:00Z]

    section = %{
      key: "cpu",
      panels: [
        %{
          id: "cpu",
          assigns: %{series_points: [{"usage_percent", []}]}
        }
      ]
    }

    row = %{
      "time" => "2026-06-19T12:05:00Z",
      "severity" => "High",
      "metric_name" => "cpu.usage_percent",
      "message" => "CPU saturation anomaly",
      "metadata" => %{
        "finding_info" => %{
          "dimensions" => %{
            "episode_peak_at_unix_nano" => DateTime.to_unix(peak_dt, :nanosecond)
          }
        },
        "source_identity" => %{"series_key" => "sysmon.cpu:host:CPU1"}
      }
    }

    [%{panels: [%{assigns: assigns}]}] =
      SysmonMetrics.annotate_metric_sections([section], %{anomaly_rows: [row]}, row)

    assert [
             %{
               dt: selected_dt,
               label: "Selected peak: CPU saturation anomaly",
               severity: "High",
               series: nil
             },
             %{
               dt: row_dt,
               label: "Peak: CPU saturation anomaly",
               severity: "High",
               series: nil
             }
           ] = assigns.annotations

    assert DateTime.compare(selected_dt, peak_dt) == :eq
    assert DateTime.compare(row_dt, peak_dt) == :eq
  end

  test "sysmon anomaly annotations remain visible when panel has no matching series and fall back to finding time" do
    section = %{
      key: "cpu",
      panels: [
        %{
          id: "cpu",
          assigns: %{series_points: [{"avg", []}]}
        }
      ]
    }

    row = %{
      "time" => "2026-06-19T12:05:00Z",
      "severity" => "warning",
      "metric_name" => "cpu.usage_percent",
      "message" => "CPU saturation anomaly",
      "metadata" => %{
        "source_identity" => %{"series_key" => "sysmon.cpu:host:CPU1"}
      }
    }

    [%{panels: [%{assigns: assigns}]}] =
      SysmonMetrics.annotate_metric_sections([section], %{anomaly_rows: [row]})

    assert [
             %{
               dt: ~U[2026-06-19 12:05:00Z],
               label: "CPU saturation anomaly",
               series: nil
             }
           ] = assigns.annotations
  end

  test "sysmon percent metric sections carry saturation gate reference lines" do
    previous_responder = Application.get_env(:serviceradar_web_ng, :device_live_srql_responder)

    Application.put_env(:serviceradar_web_ng, :device_live_srql_responder, fn query, _opts ->
      value =
        cond do
          query =~ ~s|metric_name:"cpu.usage_percent"| -> 42.0
          query =~ ~s|metric_name:"memory.used_percent"| -> 67.0
          query =~ ~s|metric_name:"disk.used_percent"| -> 73.0
          query =~ ~s|metric_name:"process.count"| -> 22.0
          true -> flunk("unexpected sysmon metric query: #{query}")
        end

      {:ok,
       %{
         "results" => [
           %{
             "timestamp" => "2026-06-19T12:00:00Z",
             "value" => value
           }
         ],
         "pagination" => %{}
       }}
    end)

    on_exit(fn ->
      restore_env(:device_live_srql_responder, previous_responder)
    end)

    sections =
      SysmonMetrics.load_metric_sections(
        __MODULE__.RecordingSRQLStub,
        [~s|device_id:"sr:test"|],
        :scope
      )

    edge_gate_floors = edge_addon_saturation_gate_floors()

    assert_panel_reference_line(
      sections,
      "cpu",
      Map.fetch!(edge_gate_floors, "cpu"),
      expected_saturation_gate_label("CPU", Map.fetch!(edge_gate_floors, "cpu"))
    )

    assert_panel_reference_line(
      sections,
      "memory",
      Map.fetch!(edge_gate_floors, "memory"),
      expected_saturation_gate_label("Memory", Map.fetch!(edge_gate_floors, "memory"))
    )

    assert_panel_reference_line(
      sections,
      "disk",
      Map.fetch!(edge_gate_floors, "disk"),
      expected_saturation_gate_label("Disk", Map.fetch!(edge_gate_floors, "disk"))
    )

    process_count = Enum.find(sections, &(&1.key == "process-count"))
    assert process_count
    assert [%{assigns: process_assigns}] = process_count.panels
    refute Map.has_key?(process_assigns, :reference_lines)
  end

  test "logs sysmon process metric SRQL failures" do
    Application.put_env(:serviceradar_web_ng, :device_live_srql_responder, fn query, _opts ->
      assert query =~ "in:timeseries_metrics"
      assert query =~ ~s|metric_type:"sysmon.process"|
      {:error, :boom}
    end)

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :device_live_srql_responder)
    end)

    log =
      capture_log([level: :warning], fn ->
        assert [] =
                 SysmonMetrics.load_process_metrics(
                   __MODULE__.RecordingSRQLStub,
                   [~s|device_id:"missing"|],
                   :scope
                 )
      end)

    assert log =~ "Failed to load sysmon process timeseries"
    assert log =~ ":boom"
  end

  test "logs sysmon presence probe SRQL failures" do
    Application.put_env(:serviceradar_web_ng, :device_live_srql_responder, fn query, _opts ->
      assert query =~ "time:last_24h"
      {:error, :boom}
    end)

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :device_live_srql_responder)
    end)

    log =
      capture_log([level: :warning], fn ->
        assert [] =
                 SysmonMetrics.resolve_sysmon_filter_tokens(
                   __MODULE__.RecordingSRQLStub,
                   %{device_uid: "missing"},
                   :scope
                 )
      end)

    assert log =~ "Failed sysmon sysmon.cpu/cpu.usage_percent presence probe"
    assert log =~ ":boom"
  end

  test "renders endpoint software inventory on device details", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    uid = "sr:test-device-endpoint-inventory-#{unique}"
    agent_id = "agent-endpoint-inventory-#{unique}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "endpoint-inventory-#{unique}",
        is_available: true,
        risk_level: "High",
        risk_level_id: 3,
        risk_score: 87,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    {:ok, scan} =
      EndpointInventoryScan
      |> Ash.Changeset.for_create(
        :create,
        %{
          device_uid: uid,
          agent_id: agent_id,
          scan_id: "scan-#{unique}",
          collector_name: "serviceradar-endpoint-inventory",
          collector_version: "test",
          state: "scanned",
          coverage_state: "complete",
          package_count: 2,
          enabled_sources: ["dpkg", "rpm"],
          manager_counts: %{"dpkg" => 1, "rpm" => 1},
          source_summaries: [
            %{"source" => "dpkg", "state" => "scanned", "package_count" => 1},
            %{"source" => "rpm", "state" => "scanned", "package_count" => 1}
          ],
          artifact_count: 1,
          current: true,
          last_successful_scan_at: now,
          last_scan_at: now,
          last_changed_scan_at: now,
          ingested_at: now,
          package_set_hash: "sha256:package-set-#{unique}",
          artifact_hash: "sha256:artifact-#{unique}",
          hash_algorithm: "sha256-v1",
          upload_reason: "changed",
          unchanged_scan_count: 0,
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, endpoint_package} =
      EndpointPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          coordinate_key: "pkg:deb/zlib-sr-#{unique}@1.24.0-#{unique}?arch=amd64",
          purl_canonical: "pkg:deb/zlib-sr-#{unique}@1.24.0-#{unique}?arch=amd64",
          package_manager: "dpkg",
          name: "zlib-sr-#{unique}",
          version: "1.24.0-#{unique}",
          architecture: "amd64",
          ecosystem: "deb",
          source_scope: "host",
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, package_row} =
      EndpointInventoryPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          scan_ref: scan.id,
          endpoint_package_ref: endpoint_package.id,
          device_uid: uid,
          agent_id: agent_id,
          name: "zlib-sr-#{unique}",
          version: "1.24.0-#{unique}",
          architecture: "amd64",
          package_manager: "dpkg",
          ecosystem: "deb",
          purl: "pkg:deb/zlib-sr-#{unique}@1.24.0-#{unique}?arch=amd64",
          purl_canonical: "pkg:deb/zlib-sr-#{unique}@1.24.0-#{unique}?arch=amd64",
          cpes: ["cpe:2.3:a:zlib-sr:zlib-sr:1.24.0:*:*:*:*:*:*:*"],
          source: "dpkg",
          current: true,
          evidence: %{},
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, advisory} =
      VulnerabilityAdvisory
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          provider: "fixture",
          feed_key: "cisa-kev",
          source_object_id: "CVE-2026-#{unique}",
          advisory_id: "CVE-2026-#{unique}",
          cve_id: "CVE-2026-#{unique}",
          title: "zlib-sr fixture vulnerability",
          severity: "critical",
          cvss_score: 9.8,
          kev: true,
          exploit_available: true,
          affected_coordinates: [
            %{
              "type" => "purl",
              "value" => "pkg:deb/zlib-sr-#{unique}@1.24.0-#{unique}?arch=amd64",
              "version_ranges" => [%{"fixed_version" => "1.24.1-#{unique}"}]
            }
          ],
          references: ["https://example.test/CVE-2026-#{unique}"],
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _match} =
      EndpointVulnerabilityMatch
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          device_uid: uid,
          agent_id: agent_id,
          scan_ref: scan.id,
          inventory_package_ref: package_row.id,
          endpoint_package_ref: endpoint_package.id,
          advisory_ref: advisory.id,
          provider: "fixture",
          feed_key: "cisa-kev",
          advisory_id: "CVE-2026-#{unique}",
          cve_id: "CVE-2026-#{unique}",
          coordinate_type: "purl",
          coordinate_value: "pkg:deb/zlib-sr-#{unique}@1.24.0-#{unique}?arch=amd64",
          version_evidence: %{"installed_version" => "1.24.0-#{unique}"},
          confidence: "high",
          status: "active",
          severity: "critical",
          cvss_score: 9.8,
          fixed_version: "1.24.1-#{unique}",
          kev: true,
          exploit_available: true,
          evidence: %{
            "package" => %{
              "name" => "zlib-sr-#{unique}",
              "version" => "1.24.0-#{unique}",
              "package_manager" => "dpkg",
              "purl_canonical" => "pkg:deb/zlib-sr-#{unique}@1.24.0-#{unique}?arch=amd64"
            }
          },
          first_seen_at: now,
          last_seen_at: now,
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, rpm_endpoint_package} =
      EndpointPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          coordinate_key: "pkg:rpm/rpm-sr-#{unique}@3.0.13-#{unique}?arch=x86_64",
          purl_canonical: "pkg:rpm/rpm-sr-#{unique}@3.0.13-#{unique}?arch=x86_64",
          package_manager: "rpm",
          name: "rpm-sr-#{unique}",
          version: "3.0.13-#{unique}",
          architecture: "x86_64",
          ecosystem: "rpm",
          source_scope: "host",
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _rpm_package_row} =
      EndpointInventoryPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          scan_ref: scan.id,
          endpoint_package_ref: rpm_endpoint_package.id,
          device_uid: uid,
          agent_id: agent_id,
          name: "rpm-sr-#{unique}",
          version: "3.0.13-#{unique}",
          architecture: "x86_64",
          package_manager: "rpm",
          ecosystem: "rpm",
          purl: "pkg:rpm/rpm-sr-#{unique}@3.0.13-#{unique}?arch=x86_64",
          purl_canonical: "pkg:rpm/rpm-sr-#{unique}@3.0.13-#{unique}?arch=x86_64",
          cpes: ["cpe:2.3:a:rpm-sr:rpm-sr:3.0.13:*:*:*:*:*:*:*"],
          source: "rpm",
          current: true,
          evidence: %{},
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, content} =
      EndpointInventoryArtifactContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          artifact_hash: "sha256:artifact-#{unique}",
          object_key: "endpoint-inventory/by-hash/#{unique}.cdx.json",
          content_type: "application/vnd.cyclonedx+json",
          format: "CycloneDX",
          spec_version: "1.6",
          sha256: "artifact-#{unique}",
          size_bytes: 4096,
          first_uploaded_at: now,
          last_referenced_at: now,
          reference_count: 1,
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _artifact} =
      EndpointInventoryArtifact
      |> Ash.Changeset.for_create(
        :create,
        %{
          scan_ref: scan.id,
          artifact_content_ref: content.id,
          agent_id: agent_id,
          device_uid: uid,
          artifact_hash: "sha256:artifact-#{unique}",
          object_key: "endpoint-inventory/by-hash/#{unique}.cdx.json",
          content_type: "application/vnd.cyclonedx+json",
          format: "CycloneDX",
          spec_version: "1.6",
          sha256: "artifact-#{unique}",
          size_bytes: 4096,
          uploaded_at: now,
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}?tab=software")
    html = render_until(view, "Endpoint Software", 10_000)

    assert html =~ "Endpoint Software"
    assert html =~ "Software"
    assert html =~ "Live Query"
    assert html =~ "Cohort Query"
    assert html =~ "Source Diagnostics"
    assert html =~ "Package Managers"
    assert html =~ "endpoint_inventory_query"
    assert html =~ "endpoint_inventory_cohort_query"
    assert html =~ "endpoint-inventory-package-filter"
    assert html =~ "Vulnerability Matches"
    assert html =~ "CVE-2026-#{unique}"
    assert html =~ "1.24.1-#{unique}"
    assert html =~ "cisa-kev"
    assert html =~ "KEV"
    assert html =~ "scanned"
    assert html =~ "complete"
    assert html =~ agent_id
    assert html =~ "serviceradar-endpoint-inventory test"
    assert html =~ "Showing 2 of 2 loaded rows"
    assert html =~ "zlib-sr-#{unique}"
    assert html =~ "rpm-sr-#{unique}"
    assert html =~ "1.24.0-#{unique}"
    assert html =~ "3.0.13-#{unique}"
    assert html =~ "dpkg"
    assert html =~ "rpm"
    assert html =~ "pkg:deb/zlib-sr"
    assert html =~ "High"
    assert html =~ "87"
    assert html =~ "endpoint-inventory/by-hash/#{unique}.cdx.json"

    filtered_html =
      view
      |> form("#endpoint-inventory-package-filter", %{
        "endpoint_inventory_filter" => %{"package_manager" => "rpm"}
      })
      |> render_change()

    assert filtered_html =~ "Filtered"
    assert filtered_html =~ "Showing 1 of 2 loaded rows"
    assert filtered_html =~ "rpm-sr-#{unique}"
    refute filtered_html =~ "zlib-sr-#{unique}</td>"

    no_match_html =
      view
      |> form("#endpoint-inventory-package-filter", %{
        "endpoint_inventory_filter" => %{"q" => "does-not-match-#{unique}"}
      })
      |> render_change()

    assert no_match_html =~ "No package rows match the current filters."
  end

  test "groups NVD and KEV rows for the same CVE into one Software-tab card", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])
    uid = "sr:test-device-cve-priority-#{unique}"
    agent_id = "agent-cve-priority-#{unique}"
    now = DateTime.truncate(DateTime.utc_now(), :second)
    cve_id = "CVE-2026-#{unique}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "cve-priority-#{unique}",
        is_available: true,
        risk_level: "Critical",
        risk_level_id: 4,
        risk_score: 90,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    {:ok, scan} =
      EndpointInventoryScan
      |> Ash.Changeset.for_create(
        :create,
        %{
          device_uid: uid,
          agent_id: agent_id,
          scan_id: "scan-cve-priority-#{unique}",
          collector_name: "serviceradar-endpoint-inventory",
          collector_version: "test",
          state: "scanned",
          coverage_state: "complete",
          package_count: 1,
          enabled_sources: ["dpkg"],
          manager_counts: %{"dpkg" => 1},
          source_summaries: [%{"source" => "dpkg", "state" => "scanned", "package_count" => 1}],
          current: true,
          last_successful_scan_at: now,
          last_scan_at: now,
          ingested_at: now,
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, endpoint_package} =
      EndpointPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          coordinate_key: "pkg:deb/openssl-#{unique}@3.0.13",
          purl_canonical: "pkg:deb/openssl-#{unique}@3.0.13",
          package_manager: "dpkg",
          name: "openssl-#{unique}",
          version: "3.0.13",
          architecture: "amd64",
          ecosystem: "deb",
          source_scope: "host",
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, package_row} =
      EndpointInventoryPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          scan_ref: scan.id,
          endpoint_package_ref: endpoint_package.id,
          device_uid: uid,
          agent_id: agent_id,
          name: "openssl-#{unique}",
          version: "3.0.13",
          architecture: "amd64",
          package_manager: "dpkg",
          ecosystem: "deb",
          purl: "pkg:deb/openssl-#{unique}@3.0.13",
          purl_canonical: "pkg:deb/openssl-#{unique}@3.0.13",
          cpes: ["cpe:2.3:a:openssl:openssl:3.0.13:*:*:*:*:*:*:*"],
          source: "dpkg",
          current: true,
          evidence: %{},
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, nvd_advisory} =
      VulnerabilityAdvisory
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          provider: "nvd",
          feed_key: "nist-nvd2",
          source_object_id: "#{cve_id}-nvd",
          advisory_id: cve_id,
          cve_id: cve_id,
          title: cve_id,
          description: "OpenSSL overflow for grouping test",
          severity: "high",
          cvss_score: 7.5,
          kev: false,
          exploit_available: false,
          affected_coordinates: [],
          references: ["https://example.test/#{cve_id}"],
          metadata: %{}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, kev_advisory} =
      VulnerabilityAdvisory
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          provider: "cisa",
          feed_key: "cisa-kev",
          source_object_id: "#{cve_id}-kev",
          advisory_id: cve_id,
          cve_id: cve_id,
          title: "OpenSSL KEV",
          description: "Known exploited",
          kev: true,
          exploit_available: true,
          affected_coordinates: [],
          references: [],
          metadata: %{"priority" => %{"due_date" => "2024-02-01"}}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _nvd_match} =
      EndpointVulnerabilityMatch
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          device_uid: uid,
          agent_id: agent_id,
          scan_ref: scan.id,
          inventory_package_ref: package_row.id,
          endpoint_package_ref: endpoint_package.id,
          advisory_ref: nvd_advisory.id,
          provider: "nvd",
          feed_key: "nist-nvd2",
          advisory_id: cve_id,
          cve_id: cve_id,
          coordinate_type: "cpe",
          coordinate_value: "cpe:2.3:a:openssl:openssl:*:*:*:*:*:*:*:*",
          version_evidence: %{"installed_version" => "3.0.13"},
          confidence: "medium",
          status: "active",
          severity: "high",
          cvss_score: 7.5,
          fixed_version: "3.0.14",
          kev: false,
          exploit_available: false,
          evidence: %{
            "package" => %{"name" => "openssl-#{unique}", "version" => "3.0.13"}
          },
          first_seen_at: now,
          last_seen_at: now,
          metadata: %{"description" => "OpenSSL overflow for grouping test"}
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _kev_match} =
      EndpointVulnerabilityMatch
      |> Ash.Changeset.for_create(
        :upsert,
        %{
          device_uid: uid,
          agent_id: agent_id,
          scan_ref: scan.id,
          inventory_package_ref: package_row.id,
          endpoint_package_ref: endpoint_package.id,
          advisory_ref: kev_advisory.id,
          provider: "cisa",
          feed_key: "cisa-kev",
          advisory_id: cve_id,
          cve_id: cve_id,
          coordinate_type: "vendor_product",
          coordinate_value: "openssl",
          version_evidence: %{"installed_version" => "3.0.13"},
          confidence: "low",
          status: "active",
          kev: true,
          exploit_available: true,
          evidence: %{
            "package" => %{"name" => "openssl-#{unique}", "version" => "3.0.13"}
          },
          first_seen_at: now,
          last_seen_at: now,
          metadata: %{
            "match_kind" => "name",
            "priority" => %{"due_date" => "2024-02-01"}
          }
        }
      )
      |> Ash.create(scope: scope)

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}?tab=software")
    html = render_until(view, "Vulnerability Matches", 10_000)

    assert html =~ cve_id
    assert html =~ "KEV"
    assert html =~ "7.5"
    assert length(Regex.scan(~r/data-testid="cve-finding"/, html)) == 1

    modal_html =
      view
      |> element("tr[phx-click=endpoint_inventory_open_package]", "openssl-#{unique}")
      |> render_click()

    assert modal_html =~ cve_id
    assert modal_html =~ "KEV"
    assert modal_html =~ "OpenSSL overflow for grouping test"
    assert modal_html =~ "3.0.14"
    assert modal_html =~ "2024-02-01"
    assert modal_html =~ "cpe:2.3:a:openssl:openssl"
    refute modal_html =~ "2 CVEs"
    # Table row + modal card, still one CVE.
    assert length(Regex.scan(~r/data-testid="cve-finding"/, modal_html)) == 2
  end

  test "renders endpoint software empty and unhealthy scan states on device details", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])
    now = DateTime.truncate(DateTime.utc_now(), :second)
    grace_window_at = DateTime.add(now, -25 * 60 * 60, :second)
    stale_at = DateTime.add(now, -27 * 60 * 60, :second)

    scenarios = [
      %{
        suffix: "no-agent",
        agent?: false,
        scan: nil,
        title: "No enrolled endpoint inventory agent",
        detail: "cannot run until this device is associated with an enrolled agent",
        empty: "No enrolled endpoint inventory agent or package inventory is available for this device."
      },
      %{
        suffix: "no-scan",
        scan: nil,
        title: "No endpoint inventory scan yet",
        detail: "no endpoint inventory scan has been ingested",
        empty: "Endpoint inventory is available for this device, but no scan has reported yet."
      },
      %{
        suffix: "disabled",
        scan: %{
          state: "disabled",
          coverage_state: "disabled",
          package_count: 0,
          last_scan_at: now,
          last_successful_scan_at: nil,
          source_summaries: []
        },
        title: "Endpoint inventory is disabled",
        detail: "collector is disabled",
        empty: "Endpoint inventory is disabled for this device."
      },
      %{
        suffix: "failed",
        scan: %{
          state: "scan_failed",
          coverage_state: "failed",
          package_count: 0,
          last_scan_at: now,
          last_successful_scan_at: nil,
          source_summaries: [
            %{"source" => "dpkg", "state" => "failed", "reason" => "dpkg exited 2"}
          ]
        },
        title: "Latest endpoint inventory scan failed",
        detail: "dpkg exited 2",
        empty: "The latest endpoint inventory scan failed before package rows were accepted."
      },
      %{
        suffix: "partial",
        scan: %{
          state: "scanned",
          coverage_state: "partial",
          package_count: 0,
          last_scan_at: now,
          last_successful_scan_at: now,
          source_summaries: [
            %{"source" => "rpm", "state" => "partial", "reason" => "rpm output truncated"}
          ]
        },
        title: "Latest endpoint inventory scan is partial",
        detail: "rpm output truncated",
        empty: "The latest endpoint inventory scan is partial and produced no current package rows."
      },
      %{
        suffix: "grace-window",
        scan: %{
          state: "scanned",
          coverage_state: "complete",
          package_count: 0,
          last_scan_at: grace_window_at,
          last_successful_scan_at: grace_window_at,
          source_summaries: [%{"source" => "dpkg", "state" => "complete", "package_count" => 0}]
        },
        title: "Scan completed with no package rows",
        detail: "reported complete coverage",
        empty: "The latest endpoint inventory scan completed, but it did not report current package rows."
      },
      %{
        suffix: "stale",
        scan: %{
          state: "scanned",
          coverage_state: "complete",
          package_count: 0,
          last_scan_at: stale_at,
          last_successful_scan_at: stale_at,
          source_summaries: [%{"source" => "dpkg", "state" => "complete", "package_count" => 0}]
        },
        title: "Latest successful scan is stale",
        detail: "older than 26 hours",
        empty: "No current package rows are available and the latest successful scan is stale."
      },
      %{
        suffix: "complete-empty",
        scan: %{
          state: "scanned",
          coverage_state: "complete",
          package_count: 0,
          last_scan_at: now,
          last_successful_scan_at: now,
          source_summaries: [%{"source" => "dpkg", "state" => "complete", "package_count" => 0}]
        },
        title: "Scan completed with no package rows",
        detail: "reported complete coverage",
        empty: "The latest endpoint inventory scan completed, but it did not report current package rows."
      }
    ]

    for scenario <- scenarios do
      uid = "sr:test-device-endpoint-state-#{scenario.suffix}-#{unique}"
      agent_id = "agent-endpoint-state-#{scenario.suffix}-#{unique}"
      agent_id_value = if Map.get(scenario, :agent?, true), do: agent_id

      Repo.insert_all("ocsf_devices", [
        %{
          uid: uid,
          type_id: 0,
          hostname: "endpoint-state-#{scenario.suffix}-#{unique}",
          agent_id: agent_id_value,
          is_available: true,
          first_seen_time: now,
          last_seen_time: now
        }
      ])

      if is_map(scenario.scan) do
        insert_endpoint_inventory_scan!(scope, %{
          device_uid: uid,
          agent_id: agent_id,
          scan_id: "scan-#{scenario.suffix}-#{unique}",
          state: scenario.scan.state,
          coverage_state: scenario.scan.coverage_state,
          package_count: scenario.scan.package_count,
          last_scan_at: scenario.scan.last_scan_at,
          last_successful_scan_at: scenario.scan.last_successful_scan_at,
          source_summaries: scenario.scan.source_summaries
        })
      end

      {:ok, view, _html} = live(conn, ~p"/devices/#{uid}?tab=software")
      html = render_until(view, scenario.title, 10_000)

      assert html =~ "Endpoint Software"
      assert html =~ scenario.title
      assert html =~ scenario.detail
      assert html =~ scenario.empty
    end
  end

  test "renders Proxmox virtualization inventory on device details", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    uid = "test-device-proxmox-#{unique}"
    node_name = "pve-live-#{unique}"
    observed_at = DateTime.utc_now()
    source_scope = proxmox_v3_source_scope(unique)
    host_identity = proxmox_v3_identity!(source_scope, "node", node_name)
    guest_identity = proxmox_v3_identity!(source_scope, "qemu", unique)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: node_name,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(host_identity, %{
          provider: "proxmox",
          device_uid: uid,
          name: node_name,
          status: "online",
          cpu_ratio: 0.42,
          memory_used_bytes: 1_073_741_824,
          memory_total_bytes: 4_294_967_296,
          observed_at: observed_at
        })
      )
      |> Ash.create(scope: scope)

    {:ok, _datastore} =
      VirtualizationDatastore
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "proxmox",
          provider_ref: proxmox_v3_child_ref!(host_identity, "datastore", [node_name, "local-zfs"]),
          host_id: host.id,
          name: "local-zfs",
          storage_type: "zfspool",
          active: true,
          enabled: true,
          used_bytes: 2_147_483_648,
          total_bytes: 8_589_934_592,
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _disk} =
      VirtualizationHostDisk
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "proxmox",
          provider_ref: proxmox_v3_child_ref!(host_identity, "disk", [node_name, "sda"]),
          host_id: host.id,
          device_uid: uid,
          path: "/dev/sda",
          disk_type: "ssd",
          model: "Samsung PM893",
          health: "PASSED",
          size_bytes: 1_000_204_886_016,
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _interface} =
      VirtualizationNetworkInterface
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "proxmox",
          provider_ref: proxmox_v3_child_ref!(host_identity, "interface", [node_name, "vmbr0"]),
          host_id: host.id,
          device_uid: uid,
          name: "vmbr0",
          interface_type: "bridge",
          active: true,
          address: "192.0.2.10",
          bridge_ports: "eno1",
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _ceph} =
      VirtualizationStorageSystem
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "proxmox",
          provider_ref: proxmox_v3_child_ref!(host_identity, "storage", [node_name, "ceph"]),
          host_id: host.id,
          name: "Ceph",
          storage_system_type: "ceph",
          health: "HEALTH_OK",
          status: "online",
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(guest_identity, %{
          provider: "proxmox",
          host_id: host.id,
          name: "guest-#{unique}",
          guest_type: "vm",
          vmid: unique,
          status: "running",
          observed_at: observed_at
        })
      )
      |> Ash.create(scope: scope)

    {:ok, view, html} = live(conn, ~p"/devices/#{uid}")

    assert html =~ "Virtualization"
    assert html =~ "Proxmox"
    assert html =~ "local-zfs"
    assert html =~ "zfspool"
    assert html =~ "Samsung PM893"
    assert html =~ "vmbr0"
    assert html =~ "eno1"
    assert html =~ "Ceph"
    assert html =~ "HEALTH_OK"
    assert html =~ "1 running"
    assert html =~ "Open PVE shell"

    assert has_element?(
             view,
             "a[href='/devices/#{uid}/proxmox-console']",
             "Open PVE shell"
           )

    refute html =~ "target_kind="
    refute html =~ "console_mode="
  end

  test "guest device links back to its parent hypervisor node", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    host_uid = "test-device-pve-node-#{unique}"
    guest_uid = "test-device-pve-guest-#{unique}"
    node_name = "pve-node-#{unique}"
    observed_at = DateTime.utc_now()
    source_scope = proxmox_v3_source_scope(unique)
    host_identity = proxmox_v3_identity!(source_scope, "node", node_name)
    guest_identity = proxmox_v3_identity!(source_scope, "qemu", unique)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: host_uid,
        type_id: 0,
        hostname: node_name,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: guest_uid,
        type_id: 1,
        hostname: "guest-vm-#{unique}",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(host_identity, %{
          provider: "proxmox",
          device_uid: host_uid,
          name: node_name,
          status: "online",
          observed_at: observed_at
        })
      )
      |> Ash.create(scope: scope)

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(guest_identity, %{
          provider: "proxmox",
          host_id: host.id,
          device_uid: guest_uid,
          name: "guest-vm-#{unique}",
          guest_type: "vm",
          vmid: unique,
          status: "running",
          observed_at: observed_at
        })
      )
      |> Ash.create(scope: scope)

    {:ok, view, _html} = live(conn, ~p"/devices/#{guest_uid}")
    html = render_until(view, "Hypervisor", 10_000)

    assert html =~ "Hypervisor"
    assert html =~ node_name
    assert html =~ ~p"/devices/#{host_uid}"
    assert html =~ "Open node"
    assert html =~ "Open console"

    assert has_element?(
             view,
             "a[href='/devices/#{guest_uid}/proxmox-console']",
             "Open console"
           )
  end

  test "PVE node Guests tab reliably renders the node's guests", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    host_uid = "test-device-pve-guests-tab-#{unique}"
    node_name = "pve-guests-tab-#{unique}"
    observed_at = DateTime.utc_now()
    source_scope = proxmox_v3_source_scope(unique)
    host_identity = proxmox_v3_identity!(source_scope, "node", node_name)
    guest_identity = proxmox_v3_identity!(source_scope, "qemu", unique)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: host_uid,
        type_id: 0,
        hostname: node_name,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(host_identity, %{
          provider: "proxmox",
          device_uid: host_uid,
          name: node_name,
          status: "online",
          observed_at: observed_at
        })
      )
      |> Ash.create(scope: scope)

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(guest_identity, %{
          provider: "proxmox",
          host_id: host.id,
          name: "guest-node-#{unique}",
          guest_type: "vm",
          vmid: unique,
          status: "running",
          observed_at: observed_at
        })
      )
      |> Ash.create(scope: scope)

    {:ok, view, _html} = live(conn, ~p"/devices/#{host_uid}?tab=guests")
    html = render_until(view, "guest-node-#{unique}", 10_000)

    assert html =~ "Guests"
    assert html =~ "guest-node-#{unique}"
    assert html =~ "running"
  end

  test "renders provider-neutral virtualization inventory on device details", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])
    uid = "test-device-vsphere-#{unique}"
    observed_at = DateTime.utc_now()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "esxi-live-#{unique}",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "vsphere",
          provider_ref: "vsphere:host:esxi-live-#{unique}",
          device_uid: uid,
          name: "esxi-live-#{unique}",
          status: "connected",
          cpu_ratio: 0.27,
          memory_used_bytes: 8_589_934_592,
          memory_total_bytes: 34_359_738_368,
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _datastore} =
      VirtualizationDatastore
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "vsphere",
          provider_ref: "vsphere:datastore:ds-#{unique}",
          host_id: host.id,
          name: "vsanDatastore",
          storage_type: "vsan",
          active: true,
          enabled: true,
          used_bytes: 4_294_967_296,
          total_bytes: 17_179_869_184,
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "vsphere",
          provider_ref: "vsphere:vm:#{unique}",
          host_id: host.id,
          name: "vsphere-guest-#{unique}",
          guest_type: "vm",
          status: "running",
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _view, html} = live(conn, ~p"/devices/#{uid}")

    assert html =~ "Virtualization"
    assert html =~ "vSphere"
    assert html =~ "vsanDatastore"
    assert html =~ "vsan"
    assert html =~ "1 running"
    refute html =~ "Open PVE shell"
    refute html =~ "proxmox-console"
  end

  test "renders guest network identity on virtualized device details", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    host_uid = "test-device-guest-host-#{unique}"
    guest_uid = "test-device-guest-vm-#{unique}"
    observed_at = DateTime.utc_now()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: host_uid,
        type_id: 0,
        hostname: "esxi-guest-host-#{unique}",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: guest_uid,
        type_id: 0,
        hostname: "app-vm-#{unique}",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "vsphere",
          provider_ref: "vsphere:host:guest-network-#{unique}",
          device_uid: host_uid,
          name: "esxi-guest-host-#{unique}",
          status: "connected",
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "vsphere",
          provider_ref: "vsphere:vm:guest-network-#{unique}",
          host_id: host.id,
          device_uid: guest_uid,
          name: "app-vm-#{unique}",
          guest_type: "vm",
          status: "running",
          disk_used_bytes: 0,
          disk_total_bytes: 1_073_741_824,
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _interface} =
      VirtualizationNetworkInterface
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "vsphere",
          provider_ref: "vsphere:guest-nic:#{unique}:4000",
          host_id: host.id,
          guest_id: guest.id,
          guest_provider_ref: guest.provider_ref,
          device_uid: guest_uid,
          name: "ens192",
          interface_type: "vmxnet3",
          active: true,
          bridge_ports: "VM Network",
          mac_address: "00:50:56:aa:bb:cc",
          ip_addresses: ["192.0.2.77/24", "2001:db8::77/64"],
          source: "guest_tools",
          observed_at: observed_at
        }
      )
      |> Ash.create(scope: scope)

    {:ok, _view, html} = live(conn, ~p"/devices/#{guest_uid}")

    assert html =~ "Virtualization"
    assert html =~ "vSphere"
    assert html =~ "ens192"
    assert html =~ "vmxnet3"
    assert html =~ "192.0.2.77/24 +1"
    assert html =~ "VM Network"
    assert html =~ "Usage unavailable"
    assert html =~ "provisioned 1.0 GB"
  end

  describe "device show page interfaces tab" do
    setup %{conn: conn} do
      device_uid = "test-device-interfaces-#{System.unique_integer([:positive])}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host-interfaces",
          ip: "192.168.1.55",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      {:ok, conn: conn, device_uid: device_uid}
    end

    test "shows interfaces tab empty state for devices targeted by discovery", %{
      conn: conn,
      device_uid: device_uid,
      scope: scope
    } do
      {:ok, job} =
        MapperJob
        |> Ash.Changeset.for_create(:create, %{name: "mapper-empty-state"})
        |> Ash.create(scope: scope)

      {:ok, _seed} =
        MapperSeed
        |> Ash.Changeset.for_create(:create, %{seed: "192.168.1.0/24", mapper_job_id: job.id})
        |> Ash.create(scope: scope)

      {:ok, _job} =
        job
        |> Ash.Changeset.for_update(:record_run, %{
          last_run_at: DateTime.utc_now(),
          last_run_status: :error,
          last_run_interface_count: 0,
          last_run_error: "mapper timeout"
        })
        |> Ash.update(scope: scope)

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      assert has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='interfaces']")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      assert html =~ "No interface data yet."
      assert html =~ "mapper timeout"
      assert html =~ job.name
    end

    test "renders interfaces table on interfaces tab", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      # Click on interfaces tab
      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      assert html =~ "eth0"
      assert html =~ "Primary Ethernet"
    end

    test "shows human-readable interface types", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      # ethernetCsmacd should be displayed as "Ethernet"
      assert html =~ "Ethernet"
      # softwareLoopback should be displayed as "Loopback"
      assert html =~ "Loopback"
    end

    test "shows status badges for interfaces", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Should have status badges
      assert has_element?(view, ".badge")
    end

    test "can select interfaces with checkboxes", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Should have checkboxes for selection
      assert has_element?(view, "input[type=checkbox]")
    end

    test "launches selected interfaces through northbound action modal", %{
      conn: conn,
      device_uid: device_uid
    } do
      action = northbound_action(:interface)
      with_northbound_stubs(interface_actions: [action])
      insert_test_interfaces!(device_uid)

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      assert_receive {:northbound_interface_actions, _scope}, 1_000

      interface_uid = "#{device_uid}-eth0"
      assert render_until(view, interface_uid, 10_000) =~ interface_uid

      view
      |> element("input[phx-click='toggle_interface_select'][phx-value-uid='#{interface_uid}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='run_action_for_interface_selection']")
        |> render_click()

      assert html =~ "Disable Switch Port"

      html =
        view
        |> form("#northbound_interface_action_modal-form", %{
          "action" => %{
            "action_id" => action.id,
            "input" => %{"reason" => "port remediation"}
          }
        })
        |> render_submit()

      assert_receive {:northbound_create_and_dispatch, attrs, opts}, 1_000
      assert html =~ "Action dispatched. Watch Action History for results."

      html =
        view
        |> element("button[phx-click='switch_tab'][phx-value-tab='details']")
        |> render_click()

      assert html =~ "Action dispatched for 1 interface"
      assert html =~ "Results update in Action History"

      assert attrs.descriptor_id == action.descriptor_id

      assert attrs.targets == [
               %{kind: "interface", device_uid: device_uid, interface_uid: interface_uid}
             ]

      assert attrs.input_values == %{"reason" => "port remediation"}
      assert attrs.metadata["ui_surface"] == "device_interfaces"
      assert opts[:actor].email
    end

    test "can toggle interface favorite", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Click favorite star for first interface
      view
      |> element("button[phx-click='toggle_interface_favorite'][phx-value-uid='#{device_uid}-eth0']")
      |> render_click()

      # Should show favorited state (star icon changes)
      html = render(view)
      assert html =~ "hero-star"
    end

    test "shows flows tab when device-scoped flows exist", %{conn: conn, device_uid: device_uid} do
      insert_test_flow!(device_uid, "192.168.1.55")
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      assert has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='flows']")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='flows']")
      |> render_click()

      assert has_element?(view, "a.btn.btn-ghost.btn-xs", "Details")
      html = render_until(view, "bidirectional")
      assert html =~ "DNS"
      assert html =~ "bidirectional"
    end

    test "hides flows tab when no scoped flows exist", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")
      refute has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='flows']")
    end

    test "device flows and /flows details show consistent persisted enrichment", %{
      conn: conn,
      device_uid: device_uid
    } do
      device_ip = "192.168.1.55"
      insert_test_flow!(device_uid, device_ip)

      {:ok, device_view, _html} = live(conn, ~p"/devices/#{device_uid}")

      device_view
      |> element("button[phx-click='switch_tab'][phx-value-tab='flows']")
      |> render_click()

      device_html = render_until(device_view, "bidirectional")
      assert device_html =~ "DNS"
      assert device_html =~ "bidirectional"

      q =
        "in:flows time:last_24h src_endpoint_ip:#{device_ip} dst_endpoint_ip:8.8.8.8 src_endpoint_port:52344 dst_endpoint_port:53 protocol_num:17 sort:time:desc limit:1"

      assert {:error, {:redirect, %{to: redirect_to}}} =
               live(conn, ~p"/flows?#{%{q: q, open: "first", limit: 50}}")

      {:ok, flows_view, _flows_html} = live(conn, redirect_to)
      flows_html = render_until(flows_view, "DNS")

      assert flows_html =~ "DNS"
    end

    test "logs tab shows immediate empty state while device logs load asynchronously", %{
      conn: conn
    } do
      previous_srql_module = Application.get_env(:serviceradar_web_ng, :srql_module)

      previous_log_delay =
        Application.get_env(:serviceradar_web_ng, :device_live_log_query_delay_ms)

      Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)
      Application.put_env(:serviceradar_web_ng, :device_live_log_query_delay_ms, 250)

      on_exit(fn ->
        restore_env(:srql_module, previous_srql_module)
        restore_env(:device_live_log_query_delay_ms, previous_log_delay)
      end)

      {:ok, view, _html} = live(conn, ~p"/devices/stub-device")

      html =
        view
        |> element("button[phx-click='switch_tab'][phx-value-tab='logs']")
        |> render_click()

      assert html =~ "No logs found for this device."
      refute html =~ "Loading device logs"

      assert render_until(view, "No logs found for this device.", 2_000) =~
               "No logs found for this device."
    end
  end

  test "agent availability falls back to recent sweep history when canonical rows are absent" do
    html =
      render_component(&Show.agent_availability_section/1,
        rows: [],
        device_row: %{},
        sweep_results: %{
          results: [
            %{
              execution: %{agent_id: "agent-dusk01"},
              status: :available,
              inserted_at: ~U[2026-05-17 06:42:00Z],
              response_time_ms: 11,
              open_ports: [],
              sweep_modes_results: %{"icmp" => "success", "tcp" => "no_response"}
            }
          ]
        }
      )

    assert html =~ "Source: recent sweep history"
    assert html =~ "agent-dusk01"
    assert html =~ "Available"
    assert html =~ "ICMP ok"
    refute html =~ "No per-agent sweep availability has been recorded"
  end

  test "agent availability marks canonical profile-derived source" do
    html =
      render_component(&Show.agent_availability_section/1,
        rows: [
          %{
            agent_id: "agent-canonical-segment",
            agent_name: "Segment Agent",
            is_available: true,
            checked_at: ~U[2026-05-17 06:42:00Z],
            response_time_ms: 9,
            open_ports: [22, 443],
            sweep_modes_results: %{"icmp" => "success"}
          },
          %{
            agent_id: "agent-other-segment",
            agent_name: "Other Agent",
            is_available: false,
            checked_at: ~U[2026-05-17 06:41:00Z],
            response_time_ms: nil,
            open_ports: [],
            sweep_modes_results: %{"icmp" => "failed"}
          }
        ],
        device_row: %{
          "availability_source_agent_id" => "agent-canonical-segment",
          "availability_source_profile_id" => Ecto.UUID.generate()
        },
        sweep_results: nil
      )

    assert html =~ "Canonical source"
    assert html =~ "profile assigned"
    assert html =~ "source"
    assert html =~ "profile"
    assert html =~ "Segment Agent"
    assert html =~ "Available"
    assert html =~ "Other Agent"
    assert html =~ "Unavailable"
  end

  # DB-dependent (like the rest of this file): excluded automatically when the
  # suite runs with the :db_free-only configuration in test_helper.exs.
  describe "device_updated broadcast refresh (#4409)" do
    setup %{conn: conn} do
      device_uid = "test-device-refresh-#{System.unique_integer([:positive])}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "refresh-host-before",
          ip: "192.168.9.77",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      previous_cooldown = Application.get_env(:serviceradar_web_ng, :device_refresh_cooldown_ms)
      previous_env = Application.get_env(:serviceradar_web_ng, :env)

      on_exit(fn ->
        restore_app_env(:device_refresh_cooldown_ms, previous_cooldown)
        restore_app_env(:env, previous_env)
      end)

      {:ok, conn: conn, device_uid: device_uid}
    end

    test "same-device refresh keeps interfaces rendered while the batch is in flight", %{
      conn: conn,
      device_uid: device_uid
    } do
      insert_test_interfaces!(device_uid)

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}?tab=interfaces")
      assert render(view) =~ "eth0"

      # Let the refresh run immediately and force the production async
      # supplemental path so the mid-refresh render is observable.
      Application.put_env(:serviceradar_web_ng, :device_refresh_cooldown_ms, 0)
      Application.put_env(:serviceradar_web_ng, :env, :prod)

      send(view.pid, {:device_updated, device_uid, %{}})

      # Mid-refresh render: before the fix, reset_supplemental_defaults nilled
      # has_ifaces here and the whole interfaces tab unmounted until the async
      # batch completed ("the page keeps reloading"). details_loading is also
      # true during this window; the table must stay up instead of swapping
      # to the first-load spinner.
      html = render(view)
      assert html =~ "eth0"
      assert html =~ "Primary Ethernet"
      refute html =~ "Loading network interfaces"

      # After the async batch lands the tab is still populated (fresh data).
      html = render_async(view, 15_000)
      assert html =~ "eth0"
      assert html =~ "Primary Ethernet"
    end

    test "broadcasts inside the cooldown window coalesce into one trailing refresh", %{
      conn: conn,
      device_uid: device_uid
    } do
      Application.put_env(:serviceradar_web_ng, :device_refresh_cooldown_ms, 60_000)

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")
      assert current_hostname(view) == "refresh-host-before"

      Repo.query!("UPDATE ocsf_devices SET hostname = 'refresh-host-after' WHERE uid = $1", [device_uid])

      send(view.pid, {:device_updated, device_uid, %{}})
      render(view)

      # Refresh deferred: the page still shows the previously loaded data.
      assert current_hostname(view) == "refresh-host-before"
      timer1 = refresh_assigns(view).device_refresh_timer
      assert is_reference(timer1)

      send(view.pid, {:device_updated, device_uid, %{}})
      render(view)

      # Second broadcast cancelled/replaced the pending timer — exactly one
      # trailing refresh remains scheduled and no reload ran.
      timer2 = refresh_assigns(view).device_refresh_timer
      assert is_reference(timer2)
      refute timer2 == timer1
      assert Process.read_timer(timer1) == false
      assert current_hostname(view) == "refresh-host-before"
    end

    test "a trailing refresh runs at cooldown expiry so the page converges", %{
      conn: conn,
      device_uid: device_uid
    } do
      Application.put_env(:serviceradar_web_ng, :device_refresh_cooldown_ms, 400)

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      Repo.query!("UPDATE ocsf_devices SET hostname = 'refresh-host-after' WHERE uid = $1", [device_uid])

      send(view.pid, {:device_updated, device_uid, %{}})
      send(view.pid, {:device_updated, device_uid, %{}})

      # Past cooldown expiry the single deferred refresh fires and reloads.
      Process.sleep(800)
      render(view)
      assert current_hostname(view) == "refresh-host-after"
    end

    test "broadcasts are ignored while a refresh is in flight", %{
      conn: conn,
      device_uid: device_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      Application.put_env(:serviceradar_web_ng, :device_refresh_cooldown_ms, 0)
      Application.put_env(:serviceradar_web_ng, :env, :prod)

      send(view.pid, {:device_updated, device_uid, %{}})
      ref1 = refresh_assigns(view).device_details_request_ref
      assert is_reference(ref1)

      send(view.pid, {:device_updated, device_uid, %{}})
      assigns = refresh_assigns(view)
      assert assigns.device_details_request_ref == ref1
      assert assigns.device_refresh_timer == nil

      render_async(view, 15_000)
    end
  end

  describe "interfaces bulk edit" do
    setup %{conn: conn} do
      device_uid = "test-device-bulk-#{System.unique_integer([:positive])}"
      ts = DateTime.truncate(DateTime.utc_now(), :second)

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host-bulk",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      Repo.insert_all("discovered_interfaces", [
        %{
          timestamp: ts,
          device_id: device_uid,
          interface_uid: "#{device_uid}-eth0",
          if_name: "eth0",
          if_descr: "Bulk Test Interface 1",
          if_type_name: "ethernetCsmacd",
          if_oper_status: 1,
          if_admin_status: 1,
          speed_bps: 1_000_000_000,
          if_index: 1
        },
        %{
          timestamp: ts,
          device_id: device_uid,
          interface_uid: "#{device_uid}-eth1",
          if_name: "eth1",
          if_descr: "Bulk Test Interface 2",
          if_type_name: "ethernetCsmacd",
          if_oper_status: 1,
          if_admin_status: 1,
          speed_bps: 1_000_000_000,
          if_index: 2
        }
      ])

      {:ok, conn: conn, device_uid: device_uid}
    end

    test "shows bulk edit button when interfaces are selected", %{
      conn: conn,
      device_uid: device_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Select an interface
      view
      |> element("input[phx-click='toggle_interface_select'][phx-value-uid='#{device_uid}-eth0']")
      |> render_click()

      html = render(view)
      assert html =~ "Bulk Edit" or html =~ "bulk"
    end

    test "bulk edit modal has all action options", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Select an interface
      view
      |> element("input[phx-click='toggle_interface_select'][phx-value-uid='#{device_uid}-eth0']")
      |> render_click()

      # Open bulk edit modal
      view
      |> element("[phx-click=open_interfaces_bulk_edit]")
      |> render_click()

      html = render(view)
      assert html =~ "Add to Favorites"
      assert html =~ "Remove from Favorites"
      assert html =~ "Enable Metrics Collection"
      assert html =~ "Disable Metrics Collection"
      assert html =~ "Add Tags"
    end
  end

  describe "device show page camera relays" do
    setup %{conn: conn} do
      previous_manager = Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)

      previous_open_result =
        Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)

      previous_close_result =
        Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_close_result)

      previous_fetcher = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)

      previous_fetch_result =
        Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetch_result)

      previous_poll_interval =
        Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms)

      previous_test_pid =
        Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid)

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager,
        CameraRelaySessionManagerStub
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_test_pid,
        self()
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn _relay_session_id, _opts ->
          Application.get_env(
            :serviceradar_web_ng,
            :camera_relay_session_fetch_result,
            {:ok, nil}
          )
        end
      )

      Application.put_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, 30_000)

      on_exit(fn ->
        restore_env(:camera_relay_session_manager, previous_manager)
        restore_env(:camera_relay_session_manager_open_result, previous_open_result)
        restore_env(:camera_relay_session_manager_close_result, previous_close_result)
        restore_env(:camera_relay_session_fetcher, previous_fetcher)
        restore_env(:camera_relay_session_fetch_result, previous_fetch_result)
        restore_env(:camera_relay_poll_interval_ms, previous_poll_interval)
        restore_env(:camera_relay_session_manager_test_pid, previous_test_pid)
      end)

      viewer = AshTestHelpers.viewer_user_fixture()
      device_uid = "test-device-camera-#{System.unique_integer([:positive])}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 7,
          hostname: "camera-host",
          vendor_name: "Axis",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      %{source: source, profile: profile} = insert_camera_source!(device_uid)

      %{
        conn: log_in_user(conn, viewer),
        device_uid: device_uid,
        source: source,
        profile: profile
      }
    end

    test "renders relay-capable camera streams for viewers", %{
      conn: conn,
      device_uid: device_uid,
      source: source,
      profile: profile
    } do
      {:ok, _view, html} = live(conn, ~p"/devices/#{device_uid}")

      assert html =~ "Camera Streams"
      assert html =~ source.display_name
      assert html =~ profile.profile_name
      assert html =~ "Open Relay"
    end

    test "renders unavailable camera sources without an open relay action", %{
      conn: conn,
      device_uid: device_uid
    } do
      %{source: source, profile: profile} =
        insert_camera_source!(device_uid, %{
          display_name: "Garage Door",
          availability_status: "unavailable",
          availability_reason: "UniFi Protect state DISCONNECTED"
        })

      {:ok, _view, html} = live(conn, ~p"/devices/#{device_uid}")

      assert html =~ source.display_name
      assert html =~ "Unavailable"
      assert html =~ "UniFi Protect state DISCONNECTED"
      assert html =~ "Relay unavailable"
      assert html =~ profile.profile_name

      refute html =~
               "button phx-click=\"open_camera_relay\" phx-value-camera_source_id=\"#{source.id}\" phx-value-stream_profile_id=\"#{profile.id}\""
    end

    test "renders camera streams when inventory is still keyed by raw camera MAC", %{
      conn: conn
    } do
      device_uid = "sr:camera-fallback-#{System.unique_integer([:positive])}"
      mac = "7845582F3F73"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 7,
          hostname: "front-door-camera",
          mac: mac,
          vendor_name: "Ubiquiti",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      %{source: source, profile: profile} = insert_camera_source!(mac)

      {:ok, _view, html} = live(conn, ~p"/devices/#{device_uid}")

      assert html =~ "Camera Streams"
      assert html =~ source.display_name
      assert html =~ profile.profile_name
      assert html =~ "Open Relay"
    end

    test "opens and closes a camera relay session from device details", %{
      conn: conn,
      device_uid: device_uid,
      source: source,
      profile: profile
    } do
      relay_session_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :opening
         }}
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_close_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :closing
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element(
        "button[phx-click='open_camera_relay'][phx-value-camera_source_id='#{source.id}'][phx-value-stream_profile_id='#{profile.id}']"
      )
      |> render_click()

      source_id = source.id
      profile_id = profile.id

      assert_receive {:open_session, ^source_id, ^profile_id, opts}
      assert opts[:scope].user.role == :viewer
      assert render(view) =~ "Opening"
      assert render(view) =~ "Stop Relay"
      assert render(view) =~ "Browser viewer channel is attached to the persisted relay session."
      assert render(view) =~ "Preferred transport: websocket_h264_annexb_webcodecs"
      assert render(view) =~ "/v1/camera-relay-sessions/#{relay_session_id}/stream"

      view
      |> element("button[phx-click='close_camera_relay']")
      |> render_click()

      assert_receive {:close_session, ^relay_session_id, opts}
      assert opts[:scope].user.role == :viewer
      assert render(view) =~ "Closing"
    end

    test "passes insecure skip verify when opening a relay from device details", %{
      conn: conn,
      device_uid: device_uid,
      source: source,
      profile: profile
    } do
      relay_session_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :opening
         }}
      )

      {:ok, source} =
        CameraSource.update_source(source, %{source_url: "rtsps://camera.local/stream"},
          actor: AshTestHelpers.system_actor()
        )

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element(
        "button[phx-click='open_camera_relay'][phx-value-camera_source_id='#{source.id}'][phx-value-stream_profile_id='#{profile.id}'][phx-value-insecure_skip_verify='true']",
        "Skip TLS Verify"
      )
      |> render_click()

      source_id = source.id
      profile_id = profile.id

      assert_receive {:open_session, ^source_id, ^profile_id, opts}
      assert opts[:insecure_skip_verify] == true
    end

    test "refreshes relay session state from persisted relay session records", %{
      conn: conn,
      device_uid: device_uid,
      source: source,
      profile: profile
    } do
      relay_session_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :opening
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element(
        "button[phx-click='open_camera_relay'][phx-value-camera_source_id='#{source.id}'][phx-value-stream_profile_id='#{profile.id}']"
      )
      |> render_click()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetch_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :active,
           media_ingest_id: "core-media-1"
         }}
      )

      send(view.pid, {:refresh_camera_relay_session, relay_session_id})
      html = render_until(view, "Relay status: Active")
      assert html =~ "Active"
      assert html =~ "Stop Relay"
      assert html =~ "Preferred transport: websocket_h264_annexb_webcodecs"

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetch_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :closed,
           media_ingest_id: "core-media-1"
         }}
      )

      send(view.pid, {:refresh_camera_relay_session, relay_session_id})
      html = render(view)
      assert html =~ "Closed"
      assert html =~ "Open Relay"
    end

    test "does not regress a closing relay back to active from a stale refresh", %{
      conn: conn,
      device_uid: device_uid,
      source: source,
      profile: profile
    } do
      relay_session_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :opening
         }}
      )

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_close_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :closing,
           termination_kind: "manual_stop",
           close_reason: "viewer closed device details"
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element(
        "button[phx-click='open_camera_relay'][phx-value-camera_source_id='#{source.id}'][phx-value-stream_profile_id='#{profile.id}']"
      )
      |> render_click()

      view
      |> element("button[phx-click='close_camera_relay']")
      |> render_click()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetch_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: source.id,
           stream_profile_id: profile.id,
           agent_id: source.assigned_agent_id,
           gateway_id: source.assigned_gateway_id,
           status: :active,
           media_ingest_id: "core-media-1"
         }}
      )

      send(view.pid, {:refresh_camera_relay_session, relay_session_id})
      html = render(view)

      assert html =~ "Closing"
      refute html =~ "Active"
    end
  end

  defp promote_user!(user, role) do
    user
    |> Ash.Changeset.for_update(:update_role, %{role: role}, actor: AshTestHelpers.system_actor())
    |> Ash.update!()
  end

  defp with_remote_access_ssh_enabled(enabled?) do
    previous = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, enabled?)

    on_exit(fn ->
      restore_env(:remote_access_ssh_enabled, previous)
    end)
  end

  defp with_remote_access_rdp_enabled(enabled?) do
    previous = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, enabled?)

    on_exit(fn ->
      restore_env(:remote_access_desktop_rdp_enabled, previous)
    end)
  end

  defp with_remote_access_desktop_targets(targets) do
    previous_targets = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_targets)
    previous_provider = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, targets)
    Application.delete_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)

    on_exit(fn ->
      restore_env(:remote_access_desktop_targets, previous_targets)
      restore_env(:remote_access_desktop_target_provider, previous_provider)
    end)
  end

  defp insert_camera_source!(device_uid, attrs \\ %{}) do
    {:ok, source} =
      CameraSource.create_source(
        Map.merge(
          %{
            device_uid: device_uid,
            vendor: "axis",
            vendor_camera_id: "axis-#{System.unique_integer([:positive])}",
            display_name: "Lobby Camera",
            source_url: "rtsp://camera.local/stream",
            assigned_agent_id: "agent-camera-1",
            assigned_gateway_id: "gateway-camera-1"
          },
          attrs
        ),
        actor: AshTestHelpers.system_actor()
      )

    {:ok, profile} =
      CameraStreamProfile.create_profile(
        %{
          camera_source_id: source.id,
          profile_name: "Main Stream",
          codec_hint: "h264",
          container_hint: "annexb",
          rtsp_transport: "tcp",
          relay_eligible: true
        },
        actor: AshTestHelpers.system_actor()
      )

    %{source: source, profile: profile}
  end

  defp with_northbound_stubs(opts) do
    previous_catalog = Application.get_env(:serviceradar_web_ng, :northbound_catalog_module)

    previous_invocation_service =
      Application.get_env(:serviceradar_web_ng, :northbound_invocation_service_module)

    previous_test_pid = Application.get_env(:serviceradar_web_ng, :northbound_action_test_pid)

    previous_device_actions =
      Application.get_env(:serviceradar_web_ng, :northbound_device_actions)

    previous_interface_actions =
      Application.get_env(:serviceradar_web_ng, :northbound_interface_actions)

    Application.put_env(
      :serviceradar_web_ng,
      :northbound_catalog_module,
      __MODULE__.NorthboundCatalogStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :northbound_invocation_service_module,
      __MODULE__.NorthboundInvocationServiceStub
    )

    Application.put_env(:serviceradar_web_ng, :northbound_action_test_pid, self())

    Application.put_env(
      :serviceradar_web_ng,
      :northbound_device_actions,
      Keyword.get(opts, :device_actions, [])
    )

    Application.put_env(
      :serviceradar_web_ng,
      :northbound_interface_actions,
      Keyword.get(opts, :interface_actions, [])
    )

    on_exit(fn ->
      restore_env(:northbound_catalog_module, previous_catalog)
      restore_env(:northbound_invocation_service_module, previous_invocation_service)
      restore_env(:northbound_action_test_pid, previous_test_pid)
      restore_env(:northbound_device_actions, previous_device_actions)
      restore_env(:northbound_interface_actions, previous_interface_actions)
    end)
  end

  defp northbound_action(scope, opts \\ []) do
    scope = to_string(scope)

    %{
      id: "northbound:#{scope}:disable-port",
      descriptor_id: northbound_descriptor_id(scope),
      label: "Disable Switch Port",
      description: "Calls an external NMS to disable a selected target.",
      provider_type: "wasm_plugin",
      provider_name: "Network Automation",
      scope: scope,
      destination: nil,
      input_schema:
        Keyword.get(opts, :input_schema, %{
          "type" => "object",
          "required" => ["reason"],
          "properties" => %{
            "reason" => %{
              "type" => "string",
              "title" => "Reason",
              "description" => "Change ticket or operator reason"
            }
          }
        }),
      safety_classification: Keyword.get(opts, :safety_classification, "destructive"),
      requires_confirmation: Keyword.get(opts, :requires_confirmation, true),
      timeout_seconds: Keyword.get(opts, :timeout_seconds, 120)
    }
  end

  defp northbound_descriptor_id("device"), do: "018f2fd1-f0ff-7cf0-9dc0-000000000101"
  defp northbound_descriptor_id(_scope), do: "018f2fd1-f0ff-7cf0-9dc0-000000000202"

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp edge_addon_saturation_gate_floors do
    source = File.read!(@edge_saturation_profile_source)

    # Parse the production `series_profile_for/1` match arms in
    # rust/anomaly-addon/src/addon.rs. That function constructs the
    # `SeriesProfile.saturation_gate.min_value` used by edge scoring; if those
    # Rust literals move to constants or a different shape, update this parser
    # rather than pointing it at the nearby Rust test fixtures.
    Map.new([{"cpu", "Cpu"}, {"memory", "Mem"}, {"disk", "Disk"}], fn {metric_class, gauge_class} ->
      regex =
        Regex.compile!(
          "Some\\(GaugeClass::#{gauge_class}\\) => SeriesProfile \\{.*?" <>
            "saturation_gate: Some\\(SaturationGate \\{.*?min_value: ([0-9.]+),",
          "s"
        )

      [_match, floor] = Regex.run(regex, source)
      {metric_class, String.to_float(floor)}
    end)
  end

  defp expected_saturation_gate_label(name, percent), do: "#{name} saturation gate #{expected_gate_percent(percent)}%"

  defp expected_gate_percent(percent) when is_float(percent) and percent == trunc(percent),
    do: Integer.to_string(trunc(percent))

  defp expected_gate_percent(percent), do: to_string(percent)

  defp assert_panel_reference_line(sections, section_key, expected_value, expected_label) do
    section = Enum.find(sections, &(&1.key == section_key))
    assert section

    assert [%{assigns: %{reference_lines: [reference_line]}}] = section.panels

    assert %{
             value: ^expected_value,
             label: ^expected_label,
             severity: :warning,
             series: nil
           } = reference_line
  end

  defp drain_srql_queries(acc \\ []) do
    receive do
      {:srql_query, query} -> drain_srql_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp insert_active_fingerprint_device! do
    unique = System.unique_integer([:positive])
    uid = "test-device-active-fingerprint-#{unique}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "active-fingerprint-host-#{unique}",
        ip: "192.0.2.#{rem(unique, 200) + 1}",
        is_available: true,
        metadata: %{
          "active_fingerprint" => %{
            "source" => "sweep_active",
            "observed_at" => "2026-05-28T12:00:00Z",
            "os" => %{
              "family" => "linux",
              "name" => "Ubuntu Linux",
              "version_range" => "22.04",
              "confidence" => 0.91,
              "source" => "serviceradar-sweep-active",
              "observed_at" => "2026-05-28T12:00:00Z"
            },
            "recog" => %{
              "ssh" => %{"product" => "OpenSSH", "version" => "9.6", "os_family" => "linux"},
              "smtp" => %{"product" => "Postfix", "version" => "3.8", "os_family" => "linux"},
              "ntp" => %{"product" => "ntpsec", "version" => "1.2"}
            }
          }
        },
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    uid
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_app_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)

  defp refresh_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp current_hostname(view) do
    refresh_assigns(view).results
    |> Enum.find(%{}, &is_map/1)
    |> Map.get("hostname")
  end

  defp insert_test_interfaces!(device_uid) do
    ts = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("discovered_interfaces", [
      %{
        timestamp: ts,
        device_id: device_uid,
        interface_uid: "#{device_uid}-eth0",
        if_name: "eth0",
        if_descr: "Primary Ethernet",
        if_type_name: "ethernetCsmacd",
        if_oper_status: 1,
        if_admin_status: 1,
        speed_bps: 1_000_000_000,
        if_index: 1
      },
      %{
        timestamp: ts,
        device_id: device_uid,
        interface_uid: "#{device_uid}-lo0",
        if_name: "lo0",
        if_descr: "Loopback",
        if_type_name: "softwareLoopback",
        if_oper_status: 1,
        if_admin_status: 1,
        speed_bps: nil,
        if_index: 2
      }
    ])
  end

  defp insert_test_flow!(device_uid, device_ip) do
    ts = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_network_activity", [
      %{
        time: ts,
        src_endpoint_ip: device_ip,
        src_endpoint_port: 52_344,
        dst_endpoint_ip: "8.8.8.8",
        dst_endpoint_port: 53,
        protocol_num: 17,
        protocol_name: "udp",
        direction_label: "bidirectional",
        dst_service_label: "DNS",
        src_hosting_provider: "SourceNet Inc",
        dst_hosting_provider: "DestNet LLC",
        src_mac: "001122334455",
        dst_mac: "AABBCCDDEEFF",
        src_mac_vendor: "SourceVendor Corp",
        dst_mac_vendor: "DestVendor Inc",
        bytes_total: 1_024,
        packets_total: 8,
        bytes_in: 256,
        bytes_out: 768,
        sampler_address: "10.1.1.1",
        ocsf_payload: %{"device_id" => device_uid},
        created_at: ts
      }
    ])
  end

  test "renders MTR dashboard visuals on the device diagnostics tab", %{conn: conn} do
    uid = "test-device-mtr-dashboard-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)
    trace_one_id = uuid_binary()
    trace_two_id = uuid_binary()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "mtr-dashboard-host",
        ip: "10.42.0.15",
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    Repo.insert_all("mtr_traces", [
      %{
        id: trace_one_id,
        time: now,
        agent_id: "agent-mtr-1",
        device_id: uid,
        target: "10.42.0.15",
        target_ip: "10.42.0.15",
        target_reached: true,
        total_hops: 6,
        protocol: "icmp",
        ip_version: 4,
        created_at: now
      },
      %{
        id: trace_two_id,
        time: DateTime.add(now, -60, :second),
        agent_id: "agent-mtr-1",
        device_id: uid,
        target: "10.42.0.15",
        target_ip: "10.42.0.15",
        target_reached: false,
        total_hops: 9,
        protocol: "icmp",
        ip_version: 4,
        error: "timeout",
        created_at: DateTime.add(now, -60, :second)
      }
    ])

    Repo.insert_all("mtr_hops", [
      %{
        id: uuid_binary(),
        time: now,
        trace_id: trace_one_id,
        hop_number: 6,
        addr: "10.42.0.15",
        sent: 5,
        received: 5,
        loss_pct: 0.0,
        avg_us: 12_000,
        created_at: now
      },
      %{
        id: uuid_binary(),
        time: DateTime.add(now, -60, :second),
        trace_id: trace_two_id,
        hop_number: 9,
        addr: "10.42.0.1",
        sent: 5,
        received: 2,
        loss_pct: 60.0,
        avg_us: 34_000,
        created_at: DateTime.add(now, -60, :second)
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}?tab=mtr")
    html = render_until(view, "Recent Availability Timeline")

    assert has_element?(view, "#device-mtr-reachability")
    assert has_element?(view, "#device-mtr-destination-latency")
    assert has_element?(view, "#device-mtr-destination-loss")
    assert has_element?(view, "#device-mtr-recent-samples")
    assert html =~ "50.0%"
    assert html =~ "12.0ms"
    assert html =~ "Destination Loss"
    assert html =~ "0.0%"
  end

  test "keeps device MTR summary pinned to the newest 50 traces while table shows page two", %{
    conn: conn
  } do
    uid = "test-device-mtr-page-two-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)
    target_ip = "10.42.0.45"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "mtr-page-two-host",
        ip: target_ip,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    newest_traces =
      for offset <- 0..49 do
        %{
          id: uuid_binary(),
          time: DateTime.add(now, -offset, :second),
          agent_id: "agent-mtr-page-two",
          device_id: uid,
          target: target_ip,
          target_ip: target_ip,
          target_reached: true,
          total_hops: 3,
          protocol: "icmp",
          ip_version: 4,
          created_at: DateTime.add(now, -offset, :second)
        }
      end

    oldest_trace = %{
      id: uuid_binary(),
      time: DateTime.add(now, -51, :second),
      agent_id: "agent-mtr-page-two",
      device_id: uid,
      target: target_ip,
      target_ip: target_ip,
      target_reached: false,
      total_hops: 9,
      protocol: "icmp",
      ip_version: 4,
      error: "timeout",
      created_at: DateTime.add(now, -51, :second)
    }

    Repo.insert_all("mtr_traces", newest_traces ++ [oldest_trace])

    destination_hops =
      Enum.map(newest_traces, fn trace ->
        %{
          id: uuid_binary(),
          time: trace.time,
          trace_id: trace.id,
          hop_number: 3,
          addr: target_ip,
          sent: 5,
          received: 5,
          loss_pct: 0.0,
          avg_us: 10_000,
          created_at: trace.created_at
        }
      end)

    oldest_unreachable_hop = %{
      id: uuid_binary(),
      time: oldest_trace.time,
      trace_id: oldest_trace.id,
      hop_number: 9,
      addr: "10.42.0.1",
      sent: 5,
      received: 0,
      loss_pct: 100.0,
      avg_us: 900_000,
      created_at: oldest_trace.created_at
    }

    Repo.insert_all("mtr_hops", destination_hops ++ [oldest_unreachable_hop])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}?tab=mtr&mtr_page=2")
    html = render_until(view, "Recent Availability Timeline")

    assert has_element?(view, "#device-mtr-reachability")
    assert has_element?(view, "#device-mtr-destination-latency")
    assert has_element?(view, "#device-mtr-destination-loss")
    assert has_element?(view, "#device-mtr-recent-samples")
    assert has_element?(view, "#device-mtr-destination-latency-trend polyline[points^='0,60 8,60']")
    assert html =~ "100.0%"
    assert html =~ "10.0ms"
    assert html =~ "50"
    assert html =~ "Unreachable"
  end

  test "shows MTR tab on default device details when diagnostics exist", %{conn: conn} do
    uid = "test-device-mtr-tab-visible-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "mtr-tab-visible-host",
        ip: "10.42.0.35",
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    Repo.insert_all("mtr_traces", [
      %{
        id: uuid_binary(),
        time: now,
        agent_id: "agent-mtr-tab-visible",
        device_id: uid,
        target: "10.42.0.35",
        target_ip: "10.42.0.35",
        target_reached: true,
        total_hops: 3,
        protocol: "icmp",
        ip_version: 4,
        created_at: now
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")

    assert has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='mtr']")

    html =
      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='mtr']")
      |> render_click()

    assert html =~ "Reachability"
    assert html =~ "100.0%"
    assert html =~ "Reached"
  end

  test "loads MTR data when patching the same device to the mtr tab", %{conn: conn} do
    uid = "test-device-mtr-patch-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "mtr-patch-host",
        ip: "10.42.0.25",
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    Repo.insert_all("mtr_traces", [
      %{
        id: uuid_binary(),
        time: now,
        agent_id: "agent-mtr-2",
        device_id: uid,
        target: "10.42.0.25",
        target_ip: "10.42.0.25",
        target_reached: true,
        total_hops: 4,
        protocol: "icmp",
        ip_version: 4,
        created_at: now
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    html = render_patch(view, ~p"/devices/#{uid}?tab=mtr")

    assert html =~ "Reachability"
    assert html =~ "100.0%"
    assert html =~ "Reached"
  end

  defp uuid_binary do
    Ecto.UUID.dump!(Ecto.UUID.generate())
  end

  defp insert_endpoint_inventory_scan!(scope, attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    params =
      Map.merge(
        %{
          collector_name: "serviceradar-endpoint-inventory",
          collector_version: "test",
          enabled_sources: [],
          manager_counts: %{},
          source_summaries: [],
          artifact_count: 0,
          current: true,
          last_changed_scan_at: Map.get(attrs, :last_successful_scan_at) || Map.get(attrs, :last_scan_at) || now,
          ingested_at: now,
          package_set_hash: "sha256:package-set-#{Map.fetch!(attrs, :scan_id)}",
          artifact_hash: nil,
          hash_algorithm: "sha256-v1",
          upload_reason: "changed",
          unchanged_scan_count: 0,
          metadata: %{}
        },
        attrs
      )

    {:ok, scan} =
      EndpointInventoryScan
      |> Ash.Changeset.for_create(:create, params)
      |> Ash.create(scope: scope)

    scan
  end

  defp manual_device_uid(ip) do
    :sha256
    |> :crypto.hash("manual:#{ip}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp proxmox_v3_source_scope(suffix) do
    %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      native_cluster_id: "test-cluster-#{suffix}"
    }
  end

  defp proxmox_v3_identity!(source_scope, object_kind, native_object_id) do
    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        source_scope.integration_id,
        source_scope.controller_id,
        source_scope.native_cluster_id,
        object_kind,
        native_object_id
      )

    identity
  end

  defp proxmox_v3_child_ref!(identity, kind, components) do
    {:ok, provider_ref} =
      IntegrationIdentity.proxmox_v3_child_ref(identity.provider_instance_ref, kind, components)

    provider_ref
  end

  defp render_until(view, expected, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    render_until(view, expected, deadline, nil)
  end

  defp table_row_for(html, needle) do
    ~r/<tr\b.*?<\/tr>/s
    |> Regex.scan(html)
    |> Enum.map(&List.first/1)
    |> Enum.find(&String.contains?(&1, needle))
  end

  defp render_until_row_contains(view, needle, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    render_until_row_contains(view, needle, expected, deadline, nil)
  end

  defp render_until_row_contains(view, needle, expected, deadline, last_html) do
    html = render(view)
    row = table_row_for(html, needle)

    cond do
      is_binary(row) and row =~ expected ->
        html

      System.monotonic_time(:millisecond) >= deadline ->
        last_html || html

      true ->
        Process.sleep(50)
        render_until_row_contains(view, needle, expected, deadline, html)
    end
  end

  defp render_until(view, expected, deadline, last_html) do
    html = render(view)

    cond do
      html =~ expected ->
        html

      System.monotonic_time(:millisecond) >= deadline ->
        last_html || html

      true ->
        Process.sleep(50)
        render_until(view, expected, deadline, html)
    end
  end

  defp timeseries_metric_row(timestamp, device_id, metric_name, metric_type, value, unit, opts \\ []) do
    gateway_id = Keyword.get(opts, :gateway_id, "test-gw")
    agent_id = Keyword.get(opts, :agent_id, "test-agent")
    tags = Keyword.get(opts, :tags, %{})
    series_key = "#{device_id}:#{metric_type}:#{metric_name}:#{Map.get(tags, "pid", "host")}"

    %{
      timestamp: timestamp,
      gateway_id: gateway_id,
      agent_id: agent_id,
      metric_name: metric_name,
      metric_type: metric_type,
      series_key: series_key,
      device_id: device_id,
      value: value,
      unit: unit,
      tags: tags,
      partition: "default",
      is_delta: false,
      metadata: %{"kind" => "gauge"},
      created_at: timestamp
    }
  end

  defmodule RecordingSRQLStub do
    @moduledoc false

    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})
    def query(_query), do: {:error, :invalid_query}

    def query(query, opts) when is_binary(query) do
      if pid = Application.get_env(:serviceradar_web_ng, :device_live_srql_test_pid) do
        send(pid, {:srql_query, query})
      end

      case Application.get_env(:serviceradar_web_ng, :device_live_srql_responder) do
        responder when is_function(responder, 2) ->
          responder.(query, opts)

        _ ->
          cond do
            String.contains?(query, "in:logs") ->
              if delay_ms = Application.get_env(:serviceradar_web_ng, :device_live_log_query_delay_ms) do
                Process.sleep(delay_ms)
              end

              {:ok, %{"results" => [], "pagination" => %{}}}

            String.contains?(query, ~s|stats:"count() as total"|) ->
              {:ok, %{"results" => [%{"total" => 42}], "pagination" => %{}}}

            String.contains?(query, "rollup_stats:inventory_summary") ->
              {:ok,
               %{
                 "results" => [
                   %{
                     "total" => 42,
                     "available" => 40,
                     "unavailable" => 2,
                     "by_type" => [],
                     "by_vendor" => []
                   }
                 ],
                 "pagination" => %{}
               }}

            true ->
              {:ok,
               %{
                 "results" => [
                   %{
                     "uid" => "stub-device",
                     "hostname" => "stub-device",
                     "vendor_name" => "Ubiquiti",
                     "is_available" => true
                   }
                 ],
                 "pagination" => %{}
               }}
          end
      end
    end

    def query(_query, _opts), do: {:error, :invalid_query}

    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}
  end

  defmodule NorthboundCatalogStub do
    @moduledoc false

    def eligible_device_actions(scope) do
      notify({:northbound_device_actions, scope})
      Application.get_env(:serviceradar_web_ng, :northbound_device_actions, [])
    end

    def eligible_interface_actions(scope) do
      notify({:northbound_interface_actions, scope})
      Application.get_env(:serviceradar_web_ng, :northbound_interface_actions, [])
    end

    defp notify(message) do
      if pid = Application.get_env(:serviceradar_web_ng, :northbound_action_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule NorthboundInvocationServiceStub do
    @moduledoc false

    def create_and_dispatch(attrs, opts) do
      if pid = Application.get_env(:serviceradar_web_ng, :northbound_action_test_pid) do
        send(pid, {:northbound_create_and_dispatch, attrs, opts})
      end

      {:ok, %{id: "018f2fd1-f0ff-7cf0-9dc0-000000000999"}}
    end
  end
end
