defmodule ServiceRadar.Monitoring.ServiceCheckTest do
  @moduledoc """
  Tests for ServiceCheck resource.

  Verifies:
  - ServiceCheck creation and CRUD
  - Enable/disable operations
  - Result recording and failure tracking
  - Read actions (by_id, by_agent, enabled, failing, due_for_check)
  - Calculations (check_type_label, status_color, is_overdue)
  - Policy enforcement
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Monitoring.ServiceCheck

  describe "service check creation" do
    test "can create a service check with required fields" do
      actor = system_actor()

      result =
        ServiceCheck
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "HTTP Health Check",
            check_type: :http,
            target: "https://api.example.com/health"
          },
          actor: actor
        )
        |> Ash.create()

      assert {:ok, check} = result
      assert check.name == "HTTP Health Check"
      assert check.check_type == :http
      assert check.target == "https://api.example.com/health"
      # default
      assert check.enabled == true
      # default
      assert check.interval_seconds == 60
    end

    test "sets default values on creation" do
      check = service_check_fixture()

      assert check.enabled == true
      assert check.interval_seconds == 60
      assert check.timeout_seconds == 10
      assert check.retries == 3
      assert check.consecutive_failures == 0
    end

    test "supports all check types" do
      for check_type <- [:ping, :http, :tcp, :snmp, :grpc, :dns, :custom] do
        check =
          service_check_fixture(%{
            name: "Check #{check_type}",
            check_type: check_type,
            target: "192.168.1.#{System.unique_integer([:positive])}"
          })

        assert check.check_type == check_type
      end
    end
  end

  describe "update actions" do
    setup do
      check = service_check_fixture()
      {:ok, check: check}
    end

    test "operator can update service check", %{check: check} do
      actor = operator_actor()

      result =
        check
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "Updated Check Name",
            interval_seconds: 120
          },
          actor: actor
        )
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.name == "Updated Check Name"
      assert updated.interval_seconds == 120
    end

    test "viewer cannot update service check", %{check: check} do
      actor = viewer_actor()

      result =
        check
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"}, actor: actor)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "enable/disable actions" do
    setup do
      check = service_check_fixture()
      {:ok, check: check}
    end

    test "operator can disable service check", %{check: check} do
      actor = operator_actor()

      {:ok, disabled} =
        check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      assert disabled.enabled == false
    end

    test "operator can enable disabled service check", %{check: check} do
      actor = operator_actor()

      # First disable
      {:ok, disabled} =
        check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      # Then enable
      {:ok, enabled} =
        disabled
        |> Ash.Changeset.for_update(:enable, %{}, actor: actor)
        |> Ash.update()

      assert enabled.enabled == true
    end

    test "viewer cannot enable/disable service check", %{check: check} do
      actor = viewer_actor()

      result =
        check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "result recording" do
    setup do
      check = service_check_fixture()
      {:ok, check: check}
    end

    test "can record success result", %{check: check} do
      actor = operator_actor()

      {:ok, updated} =
        check
        |> Ash.Changeset.for_update(
          :record_result,
          %{
            result: :success,
            last_response_time_ms: 150
          },
          actor: actor
        )
        |> Ash.update()

      assert updated.last_result == :success
      assert updated.last_response_time_ms == 150
      assert updated.last_check_at != nil
      assert updated.consecutive_failures == 0
    end

    test "can record failure result", %{check: check} do
      actor = operator_actor()

      {:ok, updated} =
        check
        |> Ash.Changeset.for_update(
          :record_result,
          %{
            result: :error,
            last_error: "Connection refused"
          },
          actor: actor
        )
        |> Ash.update()

      assert updated.last_result == :error
      assert updated.last_error == "Connection refused"
      assert updated.consecutive_failures == 1
    end

    test "consecutive failures increment on each failure", %{check: check} do
      actor = operator_actor()

      # First failure
      {:ok, first} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :error}, actor: actor)
        |> Ash.update()

      assert first.consecutive_failures == 1

      # Second failure
      {:ok, second} =
        first
        |> Ash.Changeset.for_update(:record_result, %{result: :critical}, actor: actor)
        |> Ash.update()

      assert second.consecutive_failures == 2

      # Success resets counter
      {:ok, success} =
        second
        |> Ash.Changeset.for_update(:record_result, %{result: :success}, actor: actor)
        |> Ash.update()

      assert success.consecutive_failures == 0
    end

    test "warning is considered success for failure tracking", %{check: check} do
      actor = operator_actor()

      # Create a failure first
      {:ok, failed} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :error}, actor: actor)
        |> Ash.update()

      assert failed.consecutive_failures == 1

      # Warning resets counter (warning is still a successful response)
      {:ok, warning} =
        failed
        |> Ash.Changeset.for_update(:record_result, %{result: :warning}, actor: actor)
        |> Ash.update()

      assert warning.consecutive_failures == 0
    end

    test "can reset failures manually", %{check: check} do
      actor = operator_actor()

      # Create some failures
      {:ok, failed} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :error}, actor: actor)
        |> Ash.update()

      {:ok, failed2} =
        failed
        |> Ash.Changeset.for_update(:record_result, %{result: :error}, actor: actor)
        |> Ash.update()

      assert failed2.consecutive_failures == 2

      # Reset
      {:ok, reset} =
        failed2
        |> Ash.Changeset.for_update(:reset_failures, %{}, actor: actor)
        |> Ash.update()

      assert reset.consecutive_failures == 0
    end
  end

  describe "read actions" do
    setup do
      actor = system_actor()

      # Enabled check
      check_enabled = service_check_fixture(%{name: "Enabled Check"})

      # Disabled check
      {:ok, check_disabled} =
        service_check_fixture(%{name: "Disabled Check"})
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      # Failing check
      {:ok, check_failing} =
        service_check_fixture(%{name: "Failing Check"})
        |> Ash.Changeset.for_update(:record_result, %{result: :error}, actor: actor)
        |> Ash.update()

      {:ok,
       check_enabled: check_enabled, check_disabled: check_disabled, check_failing: check_failing}
    end

    test "by_id returns specific check", %{check_enabled: check} do
      actor = viewer_actor()

      {:ok, found} =
        ServiceCheck
        |> Ash.Query.for_read(:by_id, %{id: check.id}, actor: actor)
        |> Ash.read_one()

      assert found.id == check.id
    end

    test "enabled action returns only enabled checks", %{
      check_enabled: enabled,
      check_disabled: disabled,
      check_failing: failing
    } do
      actor = viewer_actor()

      {:ok, checks} = Ash.read(ServiceCheck, action: :enabled, actor: actor)
      ids = Enum.map(checks, & &1.id)

      assert enabled.id in ids
      refute disabled.id in ids
      # Still enabled even if failing
      assert failing.id in ids
    end

    test "failing action returns checks with consecutive failures", %{
      check_enabled: enabled,
      check_failing: failing
    } do
      actor = viewer_actor()

      {:ok, checks} = Ash.read(ServiceCheck, action: :failing, actor: actor)
      ids = Enum.map(checks, & &1.id)

      assert failing.id in ids
      refute enabled.id in ids
    end
  end

  describe "calculations" do
    test "check_type_label returns correct labels" do
      actor = viewer_actor()

      label_map = %{
        ping: "Ping",
        http: "HTTP",
        tcp: "TCP",
        snmp: "SNMP",
        grpc: "gRPC",
        dns: "DNS",
        custom: "Custom"
      }

      for {check_type, expected_label} <- label_map do
        check =
          service_check_fixture(%{
            name: "Check #{check_type}",
            check_type: check_type,
            target: "192.168.1.#{System.unique_integer([:positive])}"
          })

        {:ok, [loaded]} =
          ServiceCheck
          |> Ash.Query.filter(id == ^check.id)
          |> Ash.Query.load(:check_type_label)
          |> Ash.read(actor: actor)

        assert loaded.check_type_label == expected_label
      end
    end

    test "status_color returns correct colors" do
      actor = admin_actor()

      # Create a check with success result
      check = service_check_fixture()

      {:ok, success} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :success}, actor: actor)
        |> Ash.update()

      {:ok, [loaded]} =
        ServiceCheck
        |> Ash.Query.filter(id == ^success.id)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor)

      assert loaded.status_color == "green"
    end
  end
end
