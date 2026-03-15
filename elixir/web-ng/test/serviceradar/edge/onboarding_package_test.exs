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

  alias Ash.Error.Forbidden
  alias ServiceRadar.Edge.OnboardingPackage

  require Ash.Query

  describe "package creation" do
    test "can create a package with required fields" do
      result =
        OnboardingPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            label: "Test Gateway Package",
            component_id: "test-gateway-001",
            component_type: :gateway,
            site: "datacenter-1"
          },
          actor: system_actor()
        )
        |> Ash.create()

      assert {:ok, package} = result
      assert package.label == "Test Gateway Package"
      assert package.component_id == "test-gateway-001"
      assert package.component_type == :gateway
      assert package.status == :issued
    end

    test "creates package with default issued status" do
      package = onboarding_package_fixture()

      assert package.status == :issued
    end

    test "supports all component types" do
      for component_type <- [:gateway, :agent, :checker] do
        package = onboarding_package_fixture(%{component_type: component_type})
        assert package.component_type == component_type
      end
    end

    test "supports all security modes" do
      for mode <- [:spire, :mtls] do
        package = onboarding_package_fixture(%{security_mode: mode})
        assert package.security_mode == mode
      end
    end
  end

  describe "deliver transition" do
    setup do
      package = onboarding_package_fixture()
      {:ok, package: package}
    end

    test "admin can deliver issued package", %{package: package} do
      actor = admin_actor()

      result =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      assert {:ok, delivered} = result
      assert delivered.status == :delivered
      assert delivered.delivered_at
    end

    test "operator can deliver issued package", %{package: package} do
      actor = operator_actor()

      result =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      assert {:ok, delivered} = result
      assert delivered.status == :delivered
    end

    test "cannot deliver already delivered package", %{package: package} do
      actor = admin_actor()

      # First deliver
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      # Try to deliver again
      result =
        delivered
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "activate transition" do
    setup do
      package = onboarding_package_fixture()
      actor = admin_actor()

      # First deliver the package
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      {:ok, delivered_package: delivered}
    end

    test "admin can activate delivered package", %{delivered_package: package} do
      actor = admin_actor()

      result =
        package
        |> Ash.Changeset.for_update(
          :activate,
          %{
            activated_from_ip: "192.168.1.100",
            last_seen_spiffe_id: "spiffe://example.org/gateway/test"
          },
          actor: actor
        )
        |> Ash.update()

      assert {:ok, activated} = result
      assert activated.status == :activated
      assert activated.activated_at
      assert activated.activated_from_ip == "192.168.1.100"
      assert activated.last_seen_spiffe_id == "spiffe://example.org/gateway/test"
    end

    test "cannot activate from issued state (must deliver first)" do
      actor = admin_actor()
      issued_package = onboarding_package_fixture()

      result =
        issued_package
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      assert {:error, _} = result
    end

    test "cannot activate already activated package", %{
      delivered_package: package
    } do
      actor = admin_actor()

      # First activate
      {:ok, activated} =
        package
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      # Try to activate again
      result =
        activated
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "revoke transition" do
    setup do
      package = onboarding_package_fixture()
      {:ok, package: package}
    end

    test "admin can revoke issued package", %{package: package} do
      actor = admin_actor()

      result =
        package
        |> Ash.Changeset.for_update(:revoke, %{reason: "Security concern"}, actor: actor)
        |> Ash.update()

      assert {:ok, revoked} = result
      assert revoked.status == :revoked
      assert revoked.revoked_at
    end

    test "admin can revoke delivered package", %{package: package} do
      actor = admin_actor()

      # First deliver
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      # Then revoke
      result =
        delivered
        |> Ash.Changeset.for_update(:revoke, %{reason: "Compromised credentials"}, actor: actor)
        |> Ash.update()

      assert {:ok, revoked} = result
      assert revoked.status == :revoked
    end

    test "cannot revoke activated package", %{package: package} do
      actor = admin_actor()

      # Deliver then activate
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      {:ok, activated} =
        delivered
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      # Try to revoke activated package
      result =
        activated
        |> Ash.Changeset.for_update(:revoke, %{reason: "Too late"}, actor: actor)
        |> Ash.update()

      assert {:error, _} = result
    end

    test "operator cannot revoke packages", %{package: package} do
      actor = operator_actor()

      result =
        package
        |> Ash.Changeset.for_update(:revoke, %{reason: "Should fail"}, actor: actor)
        |> Ash.update()

      assert {:error, %Forbidden{}} = result
    end
  end

  describe "expire transition" do
    setup do
      package = onboarding_package_fixture()
      {:ok, package: package}
    end

    test "can expire issued package", %{package: package} do
      # Expiration is usually triggered by AshOban, so use system actor
      result =
        package
        |> Ash.Changeset.for_update(:expire, %{}, actor: system_actor())
        |> Ash.update()

      assert {:ok, expired} = result
      assert expired.status == :expired
    end

    test "can expire delivered package", %{package: package} do
      actor = admin_actor()

      # First deliver
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      # Then expire
      result =
        delivered
        |> Ash.Changeset.for_update(:expire, %{}, actor: system_actor())
        |> Ash.update()

      assert {:ok, expired} = result
      assert expired.status == :expired
    end

    test "cannot expire activated package", %{package: package} do
      actor = admin_actor()

      # Deliver then activate
      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      {:ok, activated} =
        delivered
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      # Try to expire activated package
      result =
        activated
        |> Ash.Changeset.for_update(:expire, %{}, actor: system_actor())
        |> Ash.update()

      assert {:error, _} = result
    end
  end

  describe "soft_delete transition" do
    setup do
      package = onboarding_package_fixture()
      {:ok, package: package}
    end

    test "admin can soft delete package", %{package: package} do
      actor = admin_actor()

      result =
        package
        |> Ash.Changeset.for_update(
          :soft_delete,
          %{
            deleted_by: "admin@example.com",
            deleted_reason: "Cleanup"
          },
          actor: actor
        )
        |> Ash.update()

      assert {:ok, deleted} = result
      assert deleted.status == :deleted
      assert deleted.deleted_at
      assert deleted.deleted_by == "admin@example.com"
      assert deleted.deleted_reason == "Cleanup"
    end

    test "can soft delete from any state" do
      actor = admin_actor()

      for initial_state <- [:issued, :delivered, :activated, :revoked, :expired] do
        package = onboarding_package_fixture()

        # Transition to target state
        package = transition_to_state(package, initial_state, actor)

        # Soft delete should work from any state
        result =
          package
          |> Ash.Changeset.for_update(:soft_delete, %{deleted_by: "admin"}, actor: actor)
          |> Ash.update()

        assert {:ok, deleted} = result
        assert deleted.status == :deleted
      end
    end

    test "operator cannot soft delete packages", %{package: package} do
      actor = operator_actor()

      result =
        package
        |> Ash.Changeset.for_update(:soft_delete, %{deleted_by: "operator"}, actor: actor)
        |> Ash.update()

      assert {:error, %Forbidden{}} = result
    end
  end

  describe "read actions" do
    setup do
      actor = admin_actor()

      # Create packages in different states
      issued = onboarding_package_fixture(%{label: "Issued Package"})

      {:ok, delivered} =
        %{label: "Delivered Package"}
        |> onboarding_package_fixture()
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      {:ok, activated} =
        %{label: "Activated Package"}
        |> onboarding_package_fixture()
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()
        |> elem(1)
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      {:ok, revoked} =
        %{label: "Revoked Package"}
        |> onboarding_package_fixture()
        |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
        |> Ash.update()

      {:ok, issued: issued, delivered: delivered, activated: activated, revoked: revoked}
    end

    test "active action returns only usable packages", %{
      issued: issued,
      delivered: delivered,
      activated: activated,
      revoked: revoked
    } do
      actor = operator_actor()

      {:ok, active} =
        Ash.read(OnboardingPackage, action: :active, actor: actor)

      ids = Enum.map(active, & &1.id)

      assert issued.id in ids
      assert delivered.id in ids
      refute activated.id in ids
      refute revoked.id in ids
    end
  end

  describe "calculations" do
    test "is_usable returns true for issued and delivered" do
      actor = admin_actor()
      issued = onboarding_package_fixture()

      {:ok, [loaded]} =
        OnboardingPackage
        |> Ash.Query.filter(id == ^issued.id)
        |> Ash.Query.load(:is_usable)
        |> Ash.read(actor: actor)

      assert loaded.is_usable == true

      # Deliver and check again
      {:ok, delivered} =
        issued
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      {:ok, [loaded]} =
        OnboardingPackage
        |> Ash.Query.filter(id == ^delivered.id)
        |> Ash.Query.load(:is_usable)
        |> Ash.read(actor: actor)

      assert loaded.is_usable == true
    end

    test "is_terminal returns true for terminal states" do
      actor = admin_actor()

      # Activate a package
      package = onboarding_package_fixture()

      {:ok, delivered} =
        package
        |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
        |> Ash.update()

      {:ok, activated} =
        delivered
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      {:ok, [loaded]} =
        OnboardingPackage
        |> Ash.Query.filter(id == ^activated.id)
        |> Ash.Query.load(:is_terminal)
        |> Ash.read(actor: actor)

      assert loaded.is_terminal == true
    end
  end

  # Helper function to transition package to a specific state
  defp transition_to_state(package, :issued, _actor), do: package

  defp transition_to_state(package, :delivered, actor) do
    {:ok, delivered} =
      package
      |> Ash.Changeset.for_update(:deliver, %{}, actor: actor)
      |> Ash.update()

    delivered
  end

  defp transition_to_state(package, :activated, actor) do
    package
    |> transition_to_state(:delivered, actor)
    |> then(fn p ->
      {:ok, activated} =
        p
        |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
        |> Ash.update()

      activated
    end)
  end

  defp transition_to_state(package, :revoked, actor) do
    {:ok, revoked} =
      package
      |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
      |> Ash.update()

    revoked
  end

  defp transition_to_state(package, :expired, _actor) do
    {:ok, expired} =
      package
      |> Ash.Changeset.for_update(:expire, %{}, actor: system_actor())
      |> Ash.update()

    expired
  end
end
