defmodule ServiceRadar.Oban.AshObanTriggersTest do
  @moduledoc """
  Tests for AshOban triggers across all domains.

  Verifies that:
  - Read actions correctly identify records needing processing
  - Actions properly process records
  - Filter conditions work as expected
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias Ash.Page.Keyset
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.PollingSchedule
  alias ServiceRadar.Monitoring.ServiceCheck

  require Ash.Query

  # =============================================================================
  # OnboardingPackage.expire_packages trigger
  # =============================================================================

  describe "OnboardingPackage expire_packages trigger" do
    test "needs_expiration finds packages with expired tokens" do
      # Create a package with expired tokens
      expired_download = DateTime.add(DateTime.utc_now(), -3600, :second)
      expired_join = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, expired_package} =
        OnboardingPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            label: "Expired Package",
            component_type: :gateway,
            site: "test-site"
          },
          actor: system_actor()
        )
        |> Ash.create()

      # Update with expired tokens
      {:ok, expired_package} =
        expired_package
        |> Ash.Changeset.for_update(
          :update_tokens,
          %{
            download_token_expires_at: expired_download,
            join_token_expires_at: expired_join
          },
          actor: system_actor()
        )
        |> Ash.update()

      # Create a package with valid tokens (should NOT be returned)
      valid_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, valid_package} =
        OnboardingPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            label: "Valid Package",
            component_type: :gateway,
            site: "test-site"
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, _valid_package} =
        valid_package
        |> Ash.Changeset.for_update(
          :update_tokens,
          %{
            download_token_expires_at: valid_expiry,
            join_token_expires_at: valid_expiry
          },
          actor: system_actor()
        )
        |> Ash.update()

      # Query needs_expiration (system actor for scheduler context) - returns a page
      {:ok, expiration_page} =
        OnboardingPackage
        |> Ash.Query.for_read(:needs_expiration, %{}, actor: system_actor())
        |> Ash.read()

      needing_expiration =
        if is_struct(expiration_page, Keyset),
          do: expiration_page.results,
          else: expiration_page

      ids = Enum.map(needing_expiration, & &1.id)
      assert expired_package.id in ids
      refute valid_package.id in ids
    end

    test "expire action transitions package to expired status" do
      package = onboarding_package_fixture()

      # Expire the package
      {:ok, expired} =
        package
        |> Ash.Changeset.for_update(:expire, %{}, actor: system_actor())
        |> Ash.update()

      assert expired.status == :expired
    end

    test "needs_expiration excludes already expired packages" do
      # Create and expire a package
      package = onboarding_package_fixture()

      {:ok, expired} =
        package
        |> Ash.Changeset.for_update(:expire, %{}, actor: system_actor())
        |> Ash.update()

      # Query needs_expiration - returns a page
      {:ok, expiration_page} =
        OnboardingPackage
        |> Ash.Query.for_read(:needs_expiration, %{}, actor: system_actor())
        |> Ash.read()

      needing_expiration =
        if is_struct(expiration_page, Keyset),
          do: expiration_page.results,
          else: expiration_page

      ids = Enum.map(needing_expiration, & &1.id)
      refute expired.id in ids
    end

    test "needs_expiration excludes delivered packages without expired tokens" do
      package = onboarding_package_fixture()

      # Deliver the package
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: system_actor())
        |> Ash.update()

      # Query needs_expiration (without expired tokens, should not be returned) - returns a page
      {:ok, expiration_page} =
        OnboardingPackage
        |> Ash.Query.for_read(:needs_expiration, %{}, actor: system_actor())
        |> Ash.read()

      needing_expiration =
        if is_struct(expiration_page, Keyset),
          do: expiration_page.results,
          else: expiration_page

      ids = Enum.map(needing_expiration, & &1.id)
      refute delivered.id in ids
    end
  end

  # =============================================================================
  # ServiceCheck.execute_due_checks trigger
  # =============================================================================

  describe "ServiceCheck execute_due_checks trigger" do
    test "due_for_check finds enabled checks past their interval" do
      # Create a check that was last checked 2 minutes ago with 60s interval
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-120, :second)
        |> DateTime.truncate(:second)

      check =
        service_check_fixture(%{
          name: "Overdue Check",
          interval_seconds: 60
        })

      # Record a result to set last_check_at
      {:ok, overdue_check} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :success}, actor: system_actor())
        |> Ash.update()

      # Manually set last_check_at to the past
      {:ok, overdue_check} =
        overdue_check
        |> Ecto.Changeset.change(%{last_check_at: past_time})
        |> ServiceRadar.Repo.update()

      # Create a fresh check with no last_check_at (should be due)
      fresh_check =
        service_check_fixture(%{
          name: "Fresh Check",
          interval_seconds: 60
        })

      # Query due_for_check - returns a page
      {:ok, due_page} =
        ServiceCheck
        |> Ash.Query.for_read(:due_for_check, %{}, actor: system_actor())
        |> Ash.read()

      due_checks = if is_struct(due_page, Keyset), do: due_page.results, else: due_page
      ids = Enum.map(due_checks, & &1.id)
      assert overdue_check.id in ids
      assert fresh_check.id in ids
    end

    test "due_for_check excludes disabled checks" do
      check = service_check_fixture()

      # Disable the check
      {:ok, disabled} =
        check
        |> Ash.Changeset.for_update(:disable, %{}, actor: system_actor())
        |> Ash.update()

      # Query due_for_check - returns a page
      {:ok, due_page} =
        ServiceCheck
        |> Ash.Query.for_read(:due_for_check, %{}, actor: system_actor())
        |> Ash.read()

      due_checks = if is_struct(due_page, Keyset), do: due_page.results, else: due_page
      ids = Enum.map(due_checks, & &1.id)
      refute disabled.id in ids
    end

    test "execute action updates last_check_at" do
      check = service_check_fixture()

      {:ok, executed} =
        check
        |> Ash.Changeset.for_update(:execute, %{}, actor: system_actor())
        |> Ash.update()

      assert executed.last_check_at
    end
  end

  # =============================================================================
  # PollingSchedule.execute_schedules trigger
  # =============================================================================

  describe "PollingSchedule execute_schedules trigger" do
    test "due_for_execution finds enabled interval schedules past their interval" do
      # Create an interval schedule that was last executed 2 minutes ago with 60s interval
      past_time = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Overdue Schedule",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      # Manually set last_executed_at
      {:ok, overdue} =
        schedule
        |> Ecto.Changeset.change(%{last_executed_at: past_time})
        |> ServiceRadar.Repo.update()

      # Create a fresh schedule with no last_executed_at (should be due)
      {:ok, fresh} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Fresh Schedule",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      # Query due_for_execution - returns a page
      {:ok, due_page} =
        PollingSchedule
        |> Ash.Query.for_read(:due_for_execution, %{}, actor: system_actor())
        |> Ash.read()

      due_schedules =
        if is_struct(due_page, Keyset), do: due_page.results, else: due_page

      ids = Enum.map(due_schedules, & &1.id)
      assert overdue.id in ids
      assert fresh.id in ids
    end

    test "due_for_execution excludes manual schedules" do
      {:ok, manual} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Manual Schedule",
            schedule_type: :manual
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, due_page} =
        PollingSchedule
        |> Ash.Query.for_read(:due_for_execution, %{}, actor: system_actor())
        |> Ash.read()

      due_schedules =
        if is_struct(due_page, Keyset), do: due_page.results, else: due_page

      ids = Enum.map(due_schedules, & &1.id)
      refute manual.id in ids
    end

    test "due_for_execution excludes disabled schedules" do
      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Disabled Schedule",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, disabled} =
        schedule
        |> Ash.Changeset.for_update(:disable, %{}, actor: system_actor())
        |> Ash.update()

      {:ok, due_page} =
        PollingSchedule
        |> Ash.Query.for_read(:due_for_execution, %{}, actor: system_actor())
        |> Ash.read()

      due_schedules =
        if is_struct(due_page, Keyset), do: due_page.results, else: due_page

      ids = Enum.map(due_schedules, & &1.id)
      refute disabled.id in ids
    end

    test "execute action updates last_executed_at and execution_count" do
      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Schedule",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, executed} =
        schedule
        |> Ash.Changeset.for_update(:execute, %{}, actor: system_actor())
        |> Ash.update()

      assert executed.last_executed_at
      assert executed.execution_count == 1
    end

    test "record_result updates result tracking fields" do
      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Result Schedule",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, recorded} =
        schedule
        |> Ash.Changeset.for_update(
          :record_result,
          %{
            result: :partial,
            check_count: 10,
            success_count: 8,
            failure_count: 2
          },
          actor: system_actor()
        )
        |> Ash.update()

      assert recorded.last_result == :partial
      assert recorded.last_check_count == 10
      assert recorded.last_success_count == 8
      assert recorded.last_failure_count == 2
      # partial is considered success
      assert recorded.consecutive_failures == 0
    end

    test "consecutive failures increment on failed results" do
      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Failing Schedule",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      # First failure
      {:ok, failed1} =
        schedule
        |> Ash.Changeset.for_update(:record_result, %{result: :failed}, actor: system_actor())
        |> Ash.update()

      assert failed1.consecutive_failures == 1

      # Second failure
      {:ok, failed2} =
        failed1
        |> Ash.Changeset.for_update(:record_result, %{result: :timeout}, actor: system_actor())
        |> Ash.update()

      assert failed2.consecutive_failures == 2

      # Success resets
      {:ok, success} =
        failed2
        |> Ash.Changeset.for_update(:record_result, %{result: :success}, actor: system_actor())
        |> Ash.update()

      assert success.consecutive_failures == 0
    end
  end

  # =============================================================================
  # Alert.auto_escalate trigger
  # =============================================================================

  describe "Alert auto_escalate trigger" do
    test "pending action finds unacknowledged alerts" do
      # Create a pending alert
      pending_alert =
        alert_fixture(%{
          title: "Pending Alert",
          severity: :warning
        })

      # Create and acknowledge an alert
      ack_alert =
        alert_fixture(%{
          title: "Acknowledged Alert",
          severity: :warning
        })

      {:ok, _acknowledged} =
        ack_alert
        |> Ash.Changeset.for_update(
          :acknowledge,
          %{
            acknowledged_by: "test-user"
          },
          actor: admin_actor()
        )
        |> Ash.update()

      # Query pending - returns a page, so get the results
      {:ok, pending_page} =
        Alert
        |> Ash.Query.for_read(:pending, %{}, actor: system_actor())
        |> Ash.read()

      pending_alerts =
        if is_struct(pending_page, Keyset), do: pending_page.results, else: pending_page

      ids = Enum.map(pending_alerts, & &1.id)
      assert pending_alert.id in ids
      refute ack_alert.id in ids
    end

    test "escalate action transitions alert to escalated status" do
      alert = alert_fixture()

      {:ok, escalated} =
        alert
        |> Ash.Changeset.for_update(
          :escalate,
          %{
            reason: "No response for 30 minutes"
          },
          actor: system_actor()
        )
        |> Ash.update()

      assert escalated.status == :escalated
      assert escalated.escalated_at
    end

    test "pending excludes resolved alerts" do
      alert = alert_fixture()

      {:ok, resolved} =
        alert
        |> Ash.Changeset.for_update(
          :resolve,
          %{
            resolution_note: "Fixed"
          },
          actor: admin_actor()
        )
        |> Ash.update()

      {:ok, pending_page} =
        Alert
        |> Ash.Query.for_read(:pending, %{}, actor: system_actor())
        |> Ash.read()

      pending_alerts =
        if is_struct(pending_page, Keyset), do: pending_page.results, else: pending_page

      ids = Enum.map(pending_alerts, & &1.id)
      refute resolved.id in ids
    end
  end

  # =============================================================================
  # Alert.send_notifications trigger
  # =============================================================================

  describe "Alert send_notifications trigger" do
    test "needs_notification finds alerts with notification_count = 0" do
      # Create a new alert - starts with notification_count = 0
      alert = alert_fixture()

      # The needs_notification read action filters for notification_count == 0 and status in [:pending, :escalated]
      {:ok, needing_notification_page} =
        Alert
        |> Ash.Query.for_read(:needs_notification, %{}, actor: system_actor())
        |> Ash.read()

      needing_notification =
        if is_struct(needing_notification_page, Keyset),
          do: needing_notification_page.results,
          else: needing_notification_page

      # New alerts with notification_count = 0 SHOULD need notification
      ids = Enum.map(needing_notification, & &1.id)
      assert alert.id in ids
    end

    test "send_notification increments notification_count and sets last_notification_at" do
      alert = alert_fixture()
      assert alert.notification_count == 0

      {:ok, notified} =
        alert
        |> Ash.Changeset.for_update(:send_notification, %{}, actor: system_actor())
        |> Ash.update()

      assert notified.notification_count == 1
      assert notified.last_notification_at
    end
  end

  # =============================================================================
  # Distributed locking tests
  # =============================================================================

  describe "PollingSchedule distributed locking" do
    test "acquire_lock sets lock fields" do
      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Lock Test",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, locked} =
        schedule
        |> Ash.Changeset.for_update(
          :acquire_lock,
          %{
            node_id: "node-1@localhost"
          },
          actor: system_actor()
        )
        |> Ash.update()

      assert locked.lock_token
      assert locked.locked_at
      assert locked.locked_by == "node-1@localhost"
    end

    test "release_lock clears lock fields" do
      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Release Test",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      # Acquire lock
      {:ok, locked} =
        schedule
        |> Ash.Changeset.for_update(
          :acquire_lock,
          %{
            node_id: "node-1@localhost"
          },
          actor: system_actor()
        )
        |> Ash.update()

      # Release lock
      {:ok, released} =
        locked
        |> Ash.Changeset.for_update(:release_lock, %{}, actor: system_actor())
        |> Ash.update()

      assert released.lock_token == nil
      assert released.locked_at == nil
      assert released.locked_by == nil
    end

    test "is_locked calculation returns true for recently locked schedules" do
      {:ok, schedule} =
        PollingSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Calc Test",
            schedule_type: :interval,
            interval_seconds: 60
          },
          actor: system_actor()
        )
        |> Ash.create()

      {:ok, locked} =
        schedule
        |> Ash.Changeset.for_update(
          :acquire_lock,
          %{
            node_id: "node-1@localhost"
          },
          actor: system_actor()
        )
        |> Ash.update()

      # Load the calculation
      {:ok, [loaded]} =
        PollingSchedule
        |> Ash.Query.filter(id == ^locked.id)
        |> Ash.Query.load(:is_locked)
        |> Ash.read(actor: system_actor())

      assert loaded.is_locked == true
    end
  end
end
