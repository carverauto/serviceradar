defmodule ServiceRadar.Edge.OnboardingPackageTest do
  @moduledoc """
  Tests for OnboardingPackage resource and state machine transitions.

  Verifies:
  - Package creation
  - State machine transitions (issued -> delivered -> activated)
  - Revocation flow (issued/delivered -> revoked)
  - Expiration flow (issued/delivered -> expired)
  - Soft delete
  - Policy enforcement for each action
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Edge.OnboardingPackage

  describe "package creation" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "can create a package with required fields", %{tenant: tenant} do
      result =
        OnboardingPackage
        |> Ash.Changeset.for_create(:create, %{
          label: "Test Poller Package",
          component_id: "test-poller-001",
          component_type: :poller,
          site: "datacenter-1"
        }, actor: system_actor(), authorize?: false, tenant: tenant.id)
        |> Ash.create()

      assert {:ok, package} = result
      assert package.label == "Test Poller Package"
      assert package.component_id == "test-poller-001"
      assert package.component_type == :poller
      assert package.status == :issued
      assert package.tenant_id == tenant.id
    end

    test "creates package with default issued status", %{tenant: tenant} do
      package = onboarding_package_fixture(tenant)

      assert package.status == :issued
    end

    test "supports all component types", %{tenant: tenant} do
      for component_type <- [:poller, :agent, :checker] do
        package = onboarding_package_fixture(tenant, %{component_type: component_type})
        assert package.component_type == component_type
      end
    end

    test "supports all security modes", %{tenant: tenant} do
      for mode <- [:spire, :mtls] do
        package = onboarding_package_fixture(tenant, %{security_mode: mode})
        assert package.security_mode == mode
      end
    end
  end

  describe "deliver transition" do
    setup do
      tenant = tenant_fixture()
      package = onboarding_package_fixture(tenant)
      {:ok, tenant: tenant, package: package}
    end

    test "admin can deliver issued package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      result =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, delivered} = result
      assert delivered.status == :delivered
      assert delivered.delivered_at != nil
    end

    test "operator can deliver issued package", %{tenant: tenant, package: package} do
      actor = operator_actor(tenant)

      result =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, delivered} = result
      assert delivered.status == :delivered
    end

    test "cannot deliver already delivered package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      # First deliver
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Try to deliver again
      result =
        delivered
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "activate transition" do
    setup do
      tenant = tenant_fixture()
      package = onboarding_package_fixture(tenant)
      actor = admin_actor(tenant)

      # First deliver the package
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, tenant: tenant, delivered_package: delivered}
    end

    test "admin can activate delivered package", %{tenant: tenant, delivered_package: package} do
      actor = admin_actor(tenant)

      result =
        package
        |> Ash.Changeset.for_update(:activate, %{
          activated_from_ip: "192.168.1.100",
          last_seen_spiffe_id: "spiffe://example.org/poller/test"
        }, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, activated} = result
      assert activated.status == :activated
      assert activated.activated_at != nil
      assert activated.activated_from_ip == "192.168.1.100"
      assert activated.last_seen_spiffe_id == "spiffe://example.org/poller/test"
    end

    test "cannot activate from issued state (must deliver first)", %{tenant: tenant} do
      actor = admin_actor(tenant)
      issued_package = onboarding_package_fixture(tenant)

      result =
        issued_package
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, _} = result
    end

    test "cannot activate already activated package", %{tenant: tenant, delivered_package: package} do
      actor = admin_actor(tenant)

      # First activate
      {:ok, activated} =
        package
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Try to activate again
      result =
        activated
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "revoke transition" do
    setup do
      tenant = tenant_fixture()
      package = onboarding_package_fixture(tenant)
      {:ok, tenant: tenant, package: package}
    end

    test "admin can revoke issued package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      result =
        package
        |> Ash.Changeset.for_update(:revoke, %{reason: "Security concern"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, revoked} = result
      assert revoked.status == :revoked
      assert revoked.revoked_at != nil
    end

    test "admin can revoke delivered package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      # First deliver
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Then revoke
      result =
        delivered
        |> Ash.Changeset.for_update(:revoke, %{reason: "Compromised credentials"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, revoked} = result
      assert revoked.status == :revoked
    end

    test "cannot revoke activated package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      # Deliver then activate
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, activated} =
        delivered
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Try to revoke activated package
      result =
        activated
        |> Ash.Changeset.for_update(:revoke, %{reason: "Too late"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, _} = result
    end

    test "operator cannot revoke packages", %{tenant: tenant, package: package} do
      actor = operator_actor(tenant)

      result =
        package
        |> Ash.Changeset.for_update(:revoke, %{reason: "Should fail"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "expire transition" do
    setup do
      tenant = tenant_fixture()
      package = onboarding_package_fixture(tenant)
      {:ok, tenant: tenant, package: package}
    end

    test "can expire issued package", %{tenant: tenant, package: package} do
      # Expiration is usually triggered by AshOban, so use system actor
      result =
        package
        |> Ash.Changeset.for_update(:expire, %{},
          actor: system_actor(), authorize?: false, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, expired} = result
      assert expired.status == :expired
    end

    test "can expire delivered package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      # First deliver
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Then expire
      result =
        delivered
        |> Ash.Changeset.for_update(:expire, %{},
          actor: system_actor(), authorize?: false, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, expired} = result
      assert expired.status == :expired
    end

    test "cannot expire activated package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      # Deliver then activate
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, activated} =
        delivered
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Try to expire activated package
      result =
        activated
        |> Ash.Changeset.for_update(:expire, %{},
          actor: system_actor(), authorize?: false, tenant: tenant.id)
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "soft_delete transition" do
    setup do
      tenant = tenant_fixture()
      package = onboarding_package_fixture(tenant)
      {:ok, tenant: tenant, package: package}
    end

    test "admin can soft delete package", %{tenant: tenant, package: package} do
      actor = admin_actor(tenant)

      result =
        package
        |> Ash.Changeset.for_update(:soft_delete, %{
          deleted_by: "admin@example.com",
          deleted_reason: "Cleanup"
        }, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, deleted} = result
      assert deleted.status == :deleted
      assert deleted.deleted_at != nil
      assert deleted.deleted_by == "admin@example.com"
      assert deleted.deleted_reason == "Cleanup"
    end

    test "can soft delete from any state", %{tenant: tenant} do
      actor = admin_actor(tenant)

      for initial_state <- [:issued, :delivered, :activated, :revoked, :expired] do
        package = onboarding_package_fixture(tenant)

        # Transition to target state
        package = transition_to_state(package, initial_state, actor, tenant.id)

        # Soft delete should work from any state
        result =
          package
          |> Ash.Changeset.for_update(:soft_delete, %{deleted_by: "admin"},
            actor: actor, tenant: tenant.id)
          |> Ash.update()

        assert {:ok, deleted} = result
        assert deleted.status == :deleted
      end
    end

    test "operator cannot soft delete packages", %{tenant: tenant, package: package} do
      actor = operator_actor(tenant)

      result =
        package
        |> Ash.Changeset.for_update(:soft_delete, %{deleted_by: "operator"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()
      actor = admin_actor(tenant)

      # Create packages in different states
      issued = onboarding_package_fixture(tenant, %{label: "Issued Package"})

      {:ok, delivered} =
        onboarding_package_fixture(tenant, %{label: "Delivered Package"})
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, activated} =
        onboarding_package_fixture(tenant, %{label: "Activated Package"})
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()
        |> elem(1)
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, revoked} =
        onboarding_package_fixture(tenant, %{label: "Revoked Package"})
        |> Ash.Changeset.for_update(:revoke, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok,
       tenant: tenant,
       issued: issued,
       delivered: delivered,
       activated: activated,
       revoked: revoked}
    end

    test "active action returns only usable packages", %{
      tenant: tenant,
      issued: issued,
      delivered: delivered,
      activated: activated,
      revoked: revoked
    } do
      actor = operator_actor(tenant)

      {:ok, active} = Ash.read(OnboardingPackage, action: :active, actor: actor, tenant: tenant.id)
      ids = Enum.map(active, & &1.id)

      assert issued.id in ids
      assert delivered.id in ids
      refute activated.id in ids
      refute revoked.id in ids
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "is_usable returns true for issued and delivered", %{tenant: tenant} do
      actor = admin_actor(tenant)

      issued = onboarding_package_fixture(tenant)

      {:ok, [loaded]} =
        OnboardingPackage
        |> Ash.Query.filter(id == ^issued.id)
        |> Ash.Query.load(:is_usable)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.is_usable == true

      # Deliver and check again
      {:ok, delivered} =
        issued
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, [loaded]} =
        OnboardingPackage
        |> Ash.Query.filter(id == ^delivered.id)
        |> Ash.Query.load(:is_usable)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.is_usable == true
    end

    test "is_terminal returns true for terminal states", %{tenant: tenant} do
      actor = admin_actor(tenant)

      # Activate a package
      package = onboarding_package_fixture(tenant)

      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, activated} =
        delivered
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, [loaded]} =
        OnboardingPackage
        |> Ash.Query.filter(id == ^activated.id)
        |> Ash.Query.load(:is_terminal)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.is_terminal == true
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-edge"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-edge"})

      package_a = onboarding_package_fixture(tenant_a, %{label: "Package A"})
      package_b = onboarding_package_fixture(tenant_b, %{label: "Package B"})

      {:ok,
       tenant_a: tenant_a,
       tenant_b: tenant_b,
       package_a: package_a,
       package_b: package_b}
    end

    test "user cannot see packages from other tenant", %{
      tenant_a: tenant_a,
      package_a: package_a,
      package_b: package_b
    } do
      actor = operator_actor(tenant_a)

      {:ok, packages} = Ash.read(OnboardingPackage, actor: actor, tenant: tenant_a.id)
      ids = Enum.map(packages, & &1.id)

      assert package_a.id in ids
      refute package_b.id in ids
    end

    test "user cannot revoke package from other tenant", %{
      tenant_a: tenant_a,
      package_b: package_b
    } do
      actor = admin_actor(tenant_a)

      result =
        package_b
        |> Ash.Changeset.for_update(:revoke, %{reason: "Attacker action"},
          actor: actor, tenant: tenant_a.id)
        |> Ash.update()

      # Should fail - either Forbidden or StaleRecord (record not found in tenant context)
      assert {:error, error} = result
      assert match?(%Ash.Error.Forbidden{}, error) or match?(%Ash.Error.Invalid{}, error)
    end
  end

  # Helper function to transition package to a specific state
  defp transition_to_state(package, :issued, _actor, _tenant_id), do: package

  defp transition_to_state(package, :delivered, actor, tenant_id) do
    {:ok, delivered} =
      package
      |> Ash.Changeset.for_update(:deliver, %{}, actor: actor, tenant: tenant_id)
      |> Ash.update()
    delivered
  end

  defp transition_to_state(package, :activated, actor, tenant_id) do
    package
    |> transition_to_state(:delivered, actor, tenant_id)
    |> then(fn p ->
      {:ok, activated} =
        p
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor, tenant: tenant_id)
        |> Ash.update()
      activated
    end)
  end

  defp transition_to_state(package, :revoked, actor, tenant_id) do
    {:ok, revoked} =
      package
      |> Ash.Changeset.for_update(:revoke, %{}, actor: actor, tenant: tenant_id)
      |> Ash.update()
    revoked
  end

  defp transition_to_state(package, :expired, _actor, tenant_id) do
    {:ok, expired} =
      package
      |> Ash.Changeset.for_update(:expire, %{},
        actor: system_actor(), authorize?: false, tenant: tenant_id)
      |> Ash.update()
    expired
  end
end
