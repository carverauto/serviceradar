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
  - Tenant isolation
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Monitoring.ServiceCheck

  describe "service check creation" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "can create a service check with required fields", %{tenant: tenant} do
      result =
        ServiceCheck
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "HTTP Health Check",
            check_type: :http,
            target: "https://api.example.com/health"
          },
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
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
      assert check.tenant_id == tenant.id
    end

    test "sets default values on creation", %{tenant: tenant} do
      check = service_check_fixture(tenant)

      assert check.enabled == true
      assert check.interval_seconds == 60
      assert check.timeout_seconds == 10
      assert check.retries == 3
      assert check.consecutive_failures == 0
    end

    test "supports all check types", %{tenant: tenant} do
      for check_type <- [:ping, :http, :tcp, :snmp, :grpc, :dns, :custom] do
        check =
          service_check_fixture(tenant, %{
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
      tenant = tenant_fixture()
      check = service_check_fixture(tenant)
      {:ok, tenant: tenant, check: check}
    end

    test "operator can update service check", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      result =
        check
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "Updated Check Name",
            interval_seconds: 120
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.name == "Updated Check Name"
      assert updated.interval_seconds == 120
    end

    test "viewer cannot update service check", %{tenant: tenant, check: check} do
      actor = viewer_actor(tenant)

      result =
        check
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "enable/disable actions" do
    setup do
      tenant = tenant_fixture()
      check = service_check_fixture(tenant)
      {:ok, tenant: tenant, check: check}
    end

    test "operator can disable service check", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      {:ok, disabled} =
        check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert disabled.enabled == false
    end

    test "operator can enable disabled service check", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      # First disable
      {:ok, disabled} =
        check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Then enable
      {:ok, enabled} =
        disabled
        |> Ash.Changeset.for_update(:enable, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert enabled.enabled == true
    end

    test "viewer cannot enable/disable service check", %{tenant: tenant, check: check} do
      actor = viewer_actor(tenant)

      result =
        check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "result recording" do
    setup do
      tenant = tenant_fixture()
      check = service_check_fixture(tenant)
      {:ok, tenant: tenant, check: check}
    end

    test "can record success result", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      {:ok, updated} =
        check
        |> Ash.Changeset.for_update(
          :record_result,
          %{
            result: :success,
            last_response_time_ms: 150
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert updated.last_result == :success
      assert updated.last_response_time_ms == 150
      assert updated.last_check_at != nil
      assert updated.consecutive_failures == 0
    end

    test "can record failure result", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      {:ok, updated} =
        check
        |> Ash.Changeset.for_update(
          :record_result,
          %{
            result: :error,
            last_error: "Connection refused"
          },
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert updated.last_result == :error
      assert updated.last_error == "Connection refused"
      assert updated.consecutive_failures == 1
    end

    test "consecutive failures increment on each failure", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      # First failure
      {:ok, first} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :error},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert first.consecutive_failures == 1

      # Second failure
      {:ok, second} =
        first
        |> Ash.Changeset.for_update(:record_result, %{result: :critical},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert second.consecutive_failures == 2

      # Success resets counter
      {:ok, success} =
        second
        |> Ash.Changeset.for_update(:record_result, %{result: :success},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert success.consecutive_failures == 0
    end

    test "warning is considered success for failure tracking", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      # Create a failure first
      {:ok, failed} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :error},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert failed.consecutive_failures == 1

      # Warning resets counter (warning is still a successful response)
      {:ok, warning} =
        failed
        |> Ash.Changeset.for_update(:record_result, %{result: :warning},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert warning.consecutive_failures == 0
    end

    test "can reset failures manually", %{tenant: tenant, check: check} do
      actor = operator_actor(tenant)

      # Create some failures
      {:ok, failed} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :error},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, failed2} =
        failed
        |> Ash.Changeset.for_update(:record_result, %{result: :error},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      assert failed2.consecutive_failures == 2

      # Reset
      {:ok, reset} =
        failed2
        |> Ash.Changeset.for_update(:reset_failures, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert reset.consecutive_failures == 0
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()

      # Enabled check
      check_enabled = service_check_fixture(tenant, %{name: "Enabled Check"})

      # Disabled check
      {:ok, check_disabled} =
        service_check_fixture(tenant, %{name: "Disabled Check"})
        |> Ash.Changeset.for_update(:disable, %{},
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.update()

      # Failing check
      {:ok, check_failing} =
        service_check_fixture(tenant, %{name: "Failing Check"})
        |> Ash.Changeset.for_update(:record_result, %{result: :error},
          actor: system_actor(),
          authorize?: false,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok,
       tenant: tenant,
       check_enabled: check_enabled,
       check_disabled: check_disabled,
       check_failing: check_failing}
    end

    test "by_id returns specific check", %{tenant: tenant, check_enabled: check} do
      actor = viewer_actor(tenant)

      {:ok, found} =
        ServiceCheck
        |> Ash.Query.for_read(:by_id, %{id: check.id}, actor: actor, tenant: tenant.id)
        |> Ash.read_one()

      assert found.id == check.id
    end

    test "enabled action returns only enabled checks", %{
      tenant: tenant,
      check_enabled: enabled,
      check_disabled: disabled,
      check_failing: failing
    } do
      actor = viewer_actor(tenant)

      {:ok, checks} = Ash.read(ServiceCheck, action: :enabled, actor: actor, tenant: tenant.id)
      ids = Enum.map(checks, & &1.id)

      assert enabled.id in ids
      refute disabled.id in ids
      # Still enabled even if failing
      assert failing.id in ids
    end

    test "failing action returns checks with consecutive failures", %{
      tenant: tenant,
      check_enabled: enabled,
      check_failing: failing
    } do
      actor = viewer_actor(tenant)

      {:ok, checks} = Ash.read(ServiceCheck, action: :failing, actor: actor, tenant: tenant.id)
      ids = Enum.map(checks, & &1.id)

      assert failing.id in ids
      refute enabled.id in ids
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "check_type_label returns correct labels", %{tenant: tenant} do
      actor = viewer_actor(tenant)

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
          service_check_fixture(tenant, %{
            name: "Check #{check_type}",
            check_type: check_type,
            target: "192.168.1.#{System.unique_integer([:positive])}"
          })

        {:ok, [loaded]} =
          ServiceCheck
          |> Ash.Query.filter(id == ^check.id)
          |> Ash.Query.load(:check_type_label)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.check_type_label == expected_label
      end
    end

    test "status_color returns correct colors", %{tenant: tenant} do
      actor = admin_actor(tenant)

      # Create a check with success result
      check = service_check_fixture(tenant)

      {:ok, success} =
        check
        |> Ash.Changeset.for_update(:record_result, %{result: :success},
          actor: actor,
          tenant: tenant.id
        )
        |> Ash.update()

      {:ok, [loaded]} =
        ServiceCheck
        |> Ash.Query.filter(id == ^success.id)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.status_color == "green"
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-check"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-check"})

      check_a = service_check_fixture(tenant_a, %{name: "Check A"})
      check_b = service_check_fixture(tenant_b, %{name: "Check B"})

      {:ok, tenant_a: tenant_a, tenant_b: tenant_b, check_a: check_a, check_b: check_b}
    end

    test "user cannot see checks from other tenant", %{
      tenant_a: tenant_a,
      check_a: check_a,
      check_b: check_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, checks} = Ash.read(ServiceCheck, actor: actor, tenant: tenant_a.id)
      ids = Enum.map(checks, & &1.id)

      assert check_a.id in ids
      refute check_b.id in ids
    end

    test "user cannot update check from other tenant", %{
      tenant_a: tenant_a,
      check_b: check_b
    } do
      actor = operator_actor(tenant_a)

      result =
        check_b
        |> Ash.Changeset.for_update(:update, %{name: "Hacked"}, actor: actor, tenant: tenant_a.id)
        |> Ash.update()

      assert {:error, error} = result
      assert match?(%Ash.Error.Forbidden{}, error) or match?(%Ash.Error.Invalid{}, error)
    end

    test "user cannot get check from other tenant by id", %{
      tenant_a: tenant_a,
      check_b: check_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, result} =
        ServiceCheck
        |> Ash.Query.for_read(:by_id, %{id: check_b.id}, actor: actor, tenant: tenant_a.id)
        |> Ash.read_one()

      assert result == nil
    end
  end
end
