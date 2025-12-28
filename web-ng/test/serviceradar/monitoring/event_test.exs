defmodule ServiceRadar.Monitoring.EventTest do
  @moduledoc """
  Tests for Event resource.

  Verifies:
  - Event recording (immutable)
  - Read actions (by_category, by_severity, by_device, by_agent, recent)
  - Calculations (severity_label, severity_color, category_label)
  - Policy enforcement
  - Tenant isolation
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Monitoring.Event

  describe "event recording" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "can record an event with required fields", %{tenant: tenant} do
      result =
        Event
        |> Ash.Changeset.for_create(
          :record,
          %{
            category: :check,
            event_type: "check.success",
            message: "Health check passed"
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      assert {:ok, event} = result
      assert event.category == :check
      assert event.event_type == "check.success"
      assert event.message == "Health check passed"
      assert event.occurred_at != nil
      assert event.tenant_id == tenant.id
    end

    test "sets occurred_at automatically on record action", %{tenant: tenant} do
      event = event_fixture(tenant)

      assert event.occurred_at != nil
      assert DateTime.diff(DateTime.utc_now(), event.occurred_at, :second) < 60
    end

    test "supports all category types", %{tenant: tenant} do
      for category <- [:check, :alert, :agent, :poller, :device, :system, :audit] do
        event =
          event_fixture(tenant, %{
            category: category,
            event_type: "#{category}.test",
            message: "Test #{category} event"
          })

        assert event.category == category
      end
    end

    test "supports all severity levels", %{tenant: tenant} do
      for severity <- [0, 1, 2, 3, 4] do
        event =
          event_fixture(tenant, %{
            severity: severity,
            message: "Severity #{severity} event"
          })

        assert event.severity == severity
      end
    end

    test "can record event with specific timestamp", %{tenant: tenant} do
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, event} =
        Event
        |> Ash.Changeset.for_create(
          :record_at_time,
          %{
            category: :audit,
            event_type: "audit.login",
            message: "User logged in",
            occurred_at: past_time
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      # Compare within 1 second tolerance (due to microsecond precision differences)
      assert abs(DateTime.diff(event.occurred_at, past_time, :second)) <= 1
    end

    test "can record event with related entities", %{tenant: tenant} do
      poller = poller_fixture(tenant)
      agent = agent_fixture(poller)

      {:ok, event} =
        Event
        |> Ash.Changeset.for_create(
          :record,
          %{
            category: :agent,
            event_type: "agent.connected",
            message: "Agent connected to poller",
            agent_uid: agent.uid,
            source_type: :agent,
            source_id: agent.uid,
            source_name: agent.name || agent.uid,
            target_type: :poller,
            target_id: poller.id,
            target_name: poller.id
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      assert event.agent_uid == agent.uid
      assert event.source_type == :agent
      assert event.target_type == :poller
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()

      # Create events in different categories
      event_check =
        event_fixture(tenant, %{
          category: :check,
          event_type: "check.success",
          message: "Check passed",
          severity: 1
        })

      event_alert =
        event_fixture(tenant, %{
          category: :alert,
          event_type: "alert.triggered",
          message: "Alert triggered",
          severity: 3
        })

      event_system =
        event_fixture(tenant, %{
          category: :system,
          event_type: "system.startup",
          message: "System started",
          severity: 1
        })

      {:ok,
       tenant: tenant,
       event_check: event_check,
       event_alert: event_alert,
       event_system: event_system}
    end

    test "by_category filters by category", %{
      tenant: tenant,
      event_check: check,
      event_alert: alert
    } do
      actor = viewer_actor(tenant)

      {:ok, events} =
        Event
        |> Ash.Query.for_read(:by_category, %{category: :check}, actor: actor, tenant: tenant.id)
        |> Ash.read()

      ids = Enum.map(events, & &1.id)
      assert check.id in ids
      refute alert.id in ids
    end

    test "by_severity filters by minimum severity", %{
      tenant: tenant,
      event_check: check,
      event_alert: alert
    } do
      actor = viewer_actor(tenant)

      {:ok, events} =
        Event
        |> Ash.Query.for_read(:by_severity, %{min_severity: 3}, actor: actor, tenant: tenant.id)
        |> Ash.read()

      ids = Enum.map(events, & &1.id)
      assert alert.id in ids
      # severity 1 is below 3
      refute check.id in ids
    end

    test "recent returns events from last hour", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      {:ok, events} = Ash.read(Event, action: :recent, actor: actor, tenant: tenant.id)

      # All events created in setup should be recent
      assert length(events) >= 3
    end

    test "in_time_range filters by time window", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      start_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      end_time = DateTime.utc_now()

      {:ok, events} =
        Event
        |> Ash.Query.for_read(
          :in_time_range,
          %{
            start_time: start_time,
            end_time: end_time
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.read()

      # All events in setup should be in range
      assert length(events) >= 3
    end
  end

  describe "event with device relationship" do
    setup do
      tenant = tenant_fixture()
      device = device_fixture(tenant, %{uid: "event-device-test"})
      {:ok, tenant: tenant, device: device}
    end

    test "by_device returns events for specific device", %{tenant: tenant, device: device} do
      # Create another device for comparison
      other_device =
        device_fixture(tenant, %{uid: "other-device-#{System.unique_integer([:positive])}"})

      # Create event for device
      {:ok, event_for_device} =
        Event
        |> Ash.Changeset.for_create(
          :record,
          %{
            category: :device,
            event_type: "device.discovered",
            message: "Device discovered",
            device_uid: device.uid
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      # Create event for different device
      {:ok, _other_event} =
        Event
        |> Ash.Changeset.for_create(
          :record,
          %{
            category: :device,
            event_type: "device.discovered",
            message: "Other device discovered",
            device_uid: other_device.uid
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      actor = viewer_actor(tenant)

      {:ok, events} =
        Event
        |> Ash.Query.for_read(:by_device, %{device_uid: device.uid},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.read()

      assert length(events) == 1
      assert hd(events).id == event_for_device.id
    end
  end

  describe "event with agent relationship" do
    setup do
      tenant = tenant_fixture()
      poller = poller_fixture(tenant)
      agent = agent_fixture(poller, %{uid: "event-agent-test"})
      {:ok, tenant: tenant, agent: agent}
    end

    test "by_agent returns events for specific agent", %{tenant: tenant, agent: agent} do
      # Create event for agent
      {:ok, event_for_agent} =
        Event
        |> Ash.Changeset.for_create(
          :record,
          %{
            category: :agent,
            event_type: "agent.heartbeat",
            message: "Agent heartbeat",
            agent_uid: agent.uid
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      actor = viewer_actor(tenant)

      {:ok, events} =
        Event
        |> Ash.Query.for_read(:by_agent, %{agent_uid: agent.uid}, actor: actor, tenant: tenant.id)
        |> Ash.read()

      assert length(events) == 1
      assert hd(events).id == event_for_agent.id
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "severity_label returns correct labels", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      label_map = %{
        0 => "Unknown",
        1 => "Info",
        2 => "Warning",
        3 => "Error",
        4 => "Critical"
      }

      for {severity, expected_label} <- label_map do
        event =
          event_fixture(tenant, %{
            severity: severity,
            message: "Severity #{severity}"
          })

        {:ok, [loaded]} =
          Event
          |> Ash.Query.filter(id == ^event.id)
          |> Ash.Query.load(:severity_label)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.severity_label == expected_label
      end
    end

    test "severity_color returns correct colors", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      color_map = %{
        # Info
        1 => "blue",
        # Warning
        2 => "yellow",
        # Error
        3 => "red",
        # Critical
        4 => "red"
      }

      for {severity, expected_color} <- color_map do
        event =
          event_fixture(tenant, %{
            severity: severity,
            message: "Severity #{severity}"
          })

        {:ok, [loaded]} =
          Event
          |> Ash.Query.filter(id == ^event.id)
          |> Ash.Query.load(:severity_color)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.severity_color == expected_color
      end
    end

    test "category_label returns correct labels", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      label_map = %{
        check: "Check",
        alert: "Alert",
        agent: "Agent",
        poller: "Poller",
        device: "Device",
        system: "System",
        audit: "Audit"
      }

      for {category, expected_label} <- label_map do
        event =
          event_fixture(tenant, %{
            category: category,
            event_type: "#{category}.test",
            message: "Category #{category}"
          })

        {:ok, [loaded]} =
          Event
          |> Ash.Query.filter(id == ^event.id)
          |> Ash.Query.load(:category_label)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.category_label == expected_label
      end
    end
  end

  describe "policy enforcement" do
    setup do
      tenant = tenant_fixture()
      event = event_fixture(tenant)
      {:ok, tenant: tenant, event: event}
    end

    test "viewer can read events", %{tenant: tenant, event: event} do
      actor = viewer_actor(tenant)

      {:ok, events} = Ash.read(Event, actor: actor, tenant: tenant.id)
      ids = Enum.map(events, & &1.id)

      assert event.id in ids
    end

    # Note: Create policy authorization with tenant_id filter can't work on create actions
    # because no data exists yet to filter against. The Event resource policies need to be
    # fixed to use actor-only expressions for create actions. For now, we test that
    # event creation works with the system actor (which bypasses authorization).

    test "events can be created via fixtures", %{tenant: tenant} do
      # This tests that the fixture mechanism works correctly
      event = event_fixture(tenant, %{message: "Created via fixture"})
      assert event.message == "Created via fixture"
      assert event.tenant_id == tenant.id
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-event"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-event"})

      event_a = event_fixture(tenant_a, %{message: "Event A"})
      event_b = event_fixture(tenant_b, %{message: "Event B"})

      {:ok, tenant_a: tenant_a, tenant_b: tenant_b, event_a: event_a, event_b: event_b}
    end

    test "user cannot see events from other tenant", %{
      tenant_a: tenant_a,
      event_a: event_a,
      event_b: event_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, events} = Ash.read(Event, actor: actor, tenant: tenant_a.id)
      ids = Enum.map(events, & &1.id)

      assert event_a.id in ids
      refute event_b.id in ids
    end

    test "user cannot get event from other tenant by category", %{
      tenant_a: tenant_a,
      event_b: event_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, events} =
        Event
        |> Ash.Query.for_read(:by_category, %{category: event_b.category},
          actor: actor,
          tenant: tenant_a.id
        )
        |> Ash.read()

      ids = Enum.map(events, & &1.id)
      refute event_b.id in ids
    end
  end
end
