defmodule ServiceRadar.Monitoring.AlertTest do
  @moduledoc """
  Tests for Alert resource and state machine transitions.

  Verifies:
  - Alert creation and triggering
  - State machine transitions (pending -> acknowledged -> resolved)
  - Escalation flow (pending -> escalated)
  - Suppression and reopening
  - Policy enforcement for each action
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Monitoring.Alert

  describe "alert creation" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "can trigger an alert with required fields", %{tenant: tenant} do
      # Note: Create policy authorization is tested separately
      # Here we test the action functionality
      result =
        Alert
        |> Ash.Changeset.for_create(
          :trigger,
          %{
            title: "High CPU Usage",
            severity: :warning,
            source_type: :device
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.create()

      assert {:ok, alert} = result
      assert alert.title == "High CPU Usage"
      assert alert.severity == :warning
      assert alert.status == :pending
      assert alert.triggered_at != nil
      assert alert.tenant_id == tenant.id
    end

    test "creates alert with default pending status", %{tenant: tenant} do
      alert = alert_fixture(tenant)

      assert alert.status == :pending
    end

    test "sets triggered_at timestamp on creation", %{tenant: tenant} do
      alert = alert_fixture(tenant)

      # Verify triggered_at is set and is recent (within last minute)
      assert alert.triggered_at != nil
      assert DateTime.diff(DateTime.utc_now(), alert.triggered_at, :second) < 60
    end

    test "supports all severity levels", %{tenant: tenant} do
      for severity <- [:info, :warning, :critical, :emergency] do
        alert = alert_fixture(tenant, %{severity: severity})
        assert alert.severity == severity
      end
    end
  end

  describe "acknowledge transition" do
    setup do
      tenant = tenant_fixture()
      alert = alert_fixture(tenant)
      {:ok, tenant: tenant, alert: alert}
    end

    test "operator can acknowledge pending alert", %{tenant: tenant, alert: alert} do
      actor = operator_actor(tenant)

      result =
        alert
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "operator@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.status == :acknowledged
      assert updated.acknowledged_by == "operator@example.com"
      assert updated.acknowledged_at != nil
    end

    test "admin can acknowledge pending alert", %{tenant: tenant, alert: alert} do
      actor = admin_actor(tenant)

      {:ok, updated} =
        alert
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "admin@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert updated.status == :acknowledged
    end

    test "viewer cannot acknowledge alert", %{tenant: tenant, alert: alert} do
      actor = viewer_actor(tenant)

      result =
        alert
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "viewer@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "cannot acknowledge already acknowledged alert", %{tenant: tenant, alert: alert} do
      actor = operator_actor(tenant)

      # First acknowledge
      {:ok, acknowledged} =
        alert
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "first@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      # Try to acknowledge again
      result =
        acknowledged
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "second@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "resolve transition" do
    setup do
      tenant = tenant_fixture()
      alert = alert_fixture(tenant)
      {:ok, tenant: tenant, alert: alert}
    end

    test "can resolve from pending state", %{tenant: tenant, alert: alert} do
      actor = operator_actor(tenant)

      {:ok, resolved} =
        alert
        |> Ash.Changeset.for_update(
          :resolve,
          %{
            resolved_by: "operator@example.com",
            resolution_note: "Issue fixed"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert resolved.status == :resolved
      assert resolved.resolved_by == "operator@example.com"
      assert resolved.resolution_note == "Issue fixed"
      assert resolved.resolved_at != nil
    end

    test "can resolve from acknowledged state", %{tenant: tenant, alert: alert} do
      actor = operator_actor(tenant)

      # First acknowledge
      {:ok, acknowledged} =
        alert
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "operator@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      # Then resolve
      {:ok, resolved} =
        acknowledged
        |> Ash.Changeset.for_update(
          :resolve,
          %{
            resolved_by: "operator@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert resolved.status == :resolved
    end

    test "can resolve from escalated state", %{tenant: tenant, alert: alert} do
      actor = admin_actor(tenant)

      # First escalate
      {:ok, escalated} =
        alert
        |> Ash.Changeset.for_update(
          :escalate,
          %{
            reason: "No response"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      # Then resolve
      {:ok, resolved} =
        escalated
        |> Ash.Changeset.for_update(
          :resolve,
          %{
            resolved_by: "admin@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert resolved.status == :resolved
    end

    test "cannot resolve already resolved alert", %{tenant: tenant, alert: alert} do
      actor = operator_actor(tenant)

      # First resolve
      {:ok, resolved} =
        alert
        |> Ash.Changeset.for_update(
          :resolve,
          %{
            resolved_by: "operator@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      # Try to resolve again
      result =
        resolved
        |> Ash.Changeset.for_update(
          :resolve,
          %{
            resolved_by: "another@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "escalate transition" do
    setup do
      tenant = tenant_fixture()
      alert = alert_fixture(tenant)
      {:ok, tenant: tenant, alert: alert}
    end

    test "admin can escalate pending alert", %{tenant: tenant, alert: alert} do
      actor = admin_actor(tenant)

      {:ok, escalated} =
        alert
        |> Ash.Changeset.for_update(
          :escalate,
          %{
            reason: "No response after 30 minutes"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert escalated.status == :escalated
      assert escalated.escalation_reason == "No response after 30 minutes"
      assert escalated.escalated_at != nil
      assert escalated.escalation_level == 1
    end

    test "escalation increments escalation_level", %{tenant: tenant} do
      # Create an alert with existing escalation level
      actor = admin_actor(tenant)

      alert = alert_fixture(tenant)

      # First escalation
      {:ok, first} =
        alert
        |> Ash.Changeset.for_update(:escalate, %{reason: "First escalation"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert first.escalation_level == 1

      # Resolve, then reopen, then escalate again
      {:ok, resolved} =
        first
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "admin"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, reopened} =
        resolved
        |> Ash.Changeset.for_update(:reopen, %{reason: "Still broken"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, second} =
        reopened
        |> Ash.Changeset.for_update(:escalate, %{reason: "Second escalation"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert second.escalation_level == 2
    end

    test "operator cannot escalate alerts (admin only)", %{tenant: tenant, alert: alert} do
      actor = operator_actor(tenant)

      result =
        alert
        |> Ash.Changeset.for_update(
          :escalate,
          %{
            reason: "Should fail"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "can escalate from acknowledged state", %{tenant: tenant, alert: alert} do
      operator = operator_actor(tenant)
      admin = admin_actor(tenant)

      # First acknowledge as operator
      {:ok, acknowledged} =
        alert
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "operator@example.com"
          },
          actor: operator,
          tenant: tenant.id
        )
        |> Ash.update()

      # Then escalate as admin
      {:ok, escalated} =
        acknowledged
        |> Ash.Changeset.for_update(
          :escalate,
          %{
            reason: "Needs attention"
          },
          actor: admin,
          tenant: tenant.id
        )
        |> Ash.update()

      assert escalated.status == :escalated
    end
  end

  describe "suppress transition" do
    setup do
      tenant = tenant_fixture()
      alert = alert_fixture(tenant)
      {:ok, tenant: tenant, alert: alert}
    end

    test "admin can suppress pending alert", %{tenant: tenant, alert: alert} do
      actor = admin_actor(tenant)
      suppress_until = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, suppressed} =
        alert
        |> Ash.Changeset.for_update(
          :suppress,
          %{
            until: suppress_until
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert suppressed.status == :suppressed
      assert suppressed.suppressed_until != nil
    end

    test "operator cannot suppress alerts", %{tenant: tenant, alert: alert} do
      actor = operator_actor(tenant)
      suppress_until = DateTime.add(DateTime.utc_now(), 3600, :second)

      result =
        alert
        |> Ash.Changeset.for_update(
          :suppress,
          %{
            until: suppress_until
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "reopen transition" do
    setup do
      tenant = tenant_fixture()
      alert = alert_fixture(tenant)
      actor = admin_actor(tenant)

      # Resolve the alert first
      {:ok, resolved} =
        alert
        |> Ash.Changeset.for_update(
          :resolve,
          %{
            resolved_by: "admin@example.com"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, tenant: tenant, resolved_alert: resolved}
    end

    test "admin can reopen resolved alert", %{tenant: tenant, resolved_alert: alert} do
      actor = admin_actor(tenant)

      {:ok, reopened} =
        alert
        |> Ash.Changeset.for_update(
          :reopen,
          %{
            reason: "Issue recurring"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert reopened.status == :pending
      assert reopened.resolved_at == nil
      assert reopened.resolved_by == nil
    end

    test "operator cannot reopen alerts", %{tenant: tenant, resolved_alert: alert} do
      actor = operator_actor(tenant)

      result =
        alert
        |> Ash.Changeset.for_update(
          :reopen,
          %{
            reason: "Should fail"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()

      # Create alerts in different states
      pending = alert_fixture(tenant, %{title: "Pending Alert"})

      actor = admin_actor(tenant)

      {:ok, acknowledged} =
        alert_fixture(tenant, %{title: "Acknowledged Alert"})
        |> Ash.Changeset.for_update(:acknowledge, %{acknowledged_by: "test"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, resolved} =
        alert_fixture(tenant, %{title: "Resolved Alert"})
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "test"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, tenant: tenant, pending: pending, acknowledged: acknowledged, resolved: resolved}
    end

    test "active action returns non-resolved alerts", %{
      tenant: tenant,
      pending: pending,
      acknowledged: acknowledged,
      resolved: resolved
    } do
      actor = viewer_actor(tenant)

      {:ok, active} = Ash.read(Alert, action: :active, actor: actor, tenant: tenant.id)
      ids = Enum.map(active, & &1.id)

      assert pending.id in ids
      assert acknowledged.id in ids
      refute resolved.id in ids
    end

    test "pending action returns only pending alerts", %{
      tenant: tenant,
      pending: pending,
      acknowledged: acknowledged
    } do
      actor = viewer_actor(tenant)

      {:ok, page} = Ash.read(Alert, action: :pending, actor: actor, tenant: tenant.id)
      # The :pending action uses keyset pagination, so extract results
      pending_alerts = if is_struct(page, Ash.Page.Keyset), do: page.results, else: page
      ids = Enum.map(pending_alerts, & &1.id)

      assert pending.id in ids
      refute acknowledged.id in ids
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "severity_color returns correct colors", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      for {severity, expected_color} <- [
            {:emergency, "red"},
            {:critical, "red"},
            {:warning, "yellow"},
            {:info, "blue"}
          ] do
        alert = alert_fixture(tenant, %{severity: severity})

        {:ok, [loaded]} =
          Alert
          |> Ash.Query.filter(id == ^alert.id)
          |> Ash.Query.load(:severity_color)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.severity_color == expected_color
      end
    end

    test "is_actionable returns true for active states", %{tenant: tenant} do
      actor = admin_actor(tenant)
      alert = alert_fixture(tenant)

      {:ok, [pending]} =
        Alert
        |> Ash.Query.filter(id == ^alert.id)
        |> Ash.Query.load(:is_actionable)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert pending.is_actionable == true

      # Resolve and check again
      {:ok, resolved} =
        alert
        |> Ash.Changeset.for_update(:resolve, %{resolved_by: "test"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, [loaded]} =
        Alert
        |> Ash.Query.filter(id == ^resolved.id)
        |> Ash.Query.load(:is_actionable)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.is_actionable == false
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-alert"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-alert"})

      alert_a = alert_fixture(tenant_a, %{title: "Alert A"})
      alert_b = alert_fixture(tenant_b, %{title: "Alert B"})

      {:ok, tenant_a: tenant_a, tenant_b: tenant_b, alert_a: alert_a, alert_b: alert_b}
    end

    test "user cannot see alerts from other tenant", %{
      tenant_a: tenant_a,
      alert_a: alert_a,
      alert_b: alert_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, alerts} = Ash.read(Alert, actor: actor, tenant: tenant_a.id)
      ids = Enum.map(alerts, & &1.id)

      assert alert_a.id in ids
      refute alert_b.id in ids
    end

    test "user cannot acknowledge alert from other tenant", %{
      tenant_a: tenant_a,
      alert_b: alert_b
    } do
      actor = operator_actor(tenant_a)

      result =
        alert_b
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "attacker@example.com"
          },
          actor: actor,
          tenant: tenant_a.id
        )
        |> Ash.update()

      # Should fail - either Forbidden or StaleRecord (record not found in tenant context)
      assert {:error, error} = result
      assert match?(%Ash.Error.Forbidden{}, error) or match?(%Ash.Error.Invalid{}, error)
    end
  end
end
