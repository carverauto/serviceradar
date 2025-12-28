defmodule ServiceRadarWebNG.Edge.OnboardingPackagesTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Edge.OnboardingPackages
  alias ServiceRadar.Identity.Tenant

  # Create a tenant for all tests
  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Test Org",
          slug: "test-org-#{System.unique_integer([:positive])}"
        },
        authorize?: false
      )
      |> Ash.create()

    %{tenant: tenant, tenant_id: tenant.id}
  end

  describe "create/2" do
    test "creates a package with generated tokens", %{tenant_id: tenant_id} do
      attrs = %{label: "test-poller-1", component_type: :poller}

      assert {:ok, result} = OnboardingPackages.create(attrs, tenant: tenant_id)

      assert result.package.id != nil
      assert result.package.label == "test-poller-1"
      assert result.package.component_type == :poller
      assert result.package.status == :issued
      assert result.join_token != nil
      assert result.download_token != nil

      # Verify tokens are stored encrypted/hashed
      assert result.package.join_token_ciphertext != nil
      assert result.package.download_token_hash != nil
      assert result.package.join_token_expires_at != nil
      assert result.package.download_token_expires_at != nil
    end

    test "creates a package with custom TTLs", %{tenant_id: tenant_id} do
      attrs = %{label: "test-checker", component_type: :checker}
      opts = [join_token_ttl_seconds: 3600, download_token_ttl_seconds: 7200, tenant: tenant_id]

      assert {:ok, result} = OnboardingPackages.create(attrs, opts)

      now = DateTime.utc_now()
      join_diff = DateTime.diff(result.package.join_token_expires_at, now)
      download_diff = DateTime.diff(result.package.download_token_expires_at, now)

      # Allow some tolerance for test execution time
      assert_in_delta join_diff, 3600, 5
      assert_in_delta download_diff, 7200, 5
    end

    test "fails with missing label", %{tenant_id: tenant_id} do
      attrs = %{component_type: :poller}

      assert {:error, error} = OnboardingPackages.create(attrs, tenant: tenant_id)
      assert is_struct(error, Ash.Error.Invalid)
    end

    test "fails with invalid component_type", %{tenant_id: tenant_id} do
      attrs = %{label: "test", component_type: :invalid}

      assert {:error, error} = OnboardingPackages.create(attrs, tenant: tenant_id)
      assert is_struct(error, Ash.Error.Invalid)
    end
  end

  describe "get/1" do
    test "returns {:ok, package} for existing package", %{tenant_id: tenant_id} do
      {:ok, result} = OnboardingPackages.create(%{label: "test"}, tenant: tenant_id)

      assert {:ok, package} = OnboardingPackages.get(result.package.id, tenant: tenant_id)
      assert package.id == result.package.id
      assert package.label == "test"
    end

    test "returns {:error, :not_found} for non-existent package", %{tenant_id: tenant_id} do
      assert {:error, :not_found} =
               OnboardingPackages.get(Ecto.UUID.generate(), tenant: tenant_id)
    end

    test "returns {:error, :not_found} for nil" do
      assert {:error, :not_found} = OnboardingPackages.get(nil)
    end
  end

  describe "list/1" do
    setup %{tenant_id: tenant_id} do
      # Create some test packages
      {:ok, r1} =
        OnboardingPackages.create(%{label: "poller-1", component_type: :poller},
          tenant: tenant_id
        )

      {:ok, r2} =
        OnboardingPackages.create(%{label: "checker-1", component_type: :checker},
          tenant: tenant_id
        )

      {:ok, r3} =
        OnboardingPackages.create(
          %{
            label: "agent-1",
            component_type: :agent,
            poller_id: "poller-123"
          },
          tenant: tenant_id
        )

      %{packages: [r1.package, r2.package, r3.package]}
    end

    test "lists all packages", %{packages: packages, tenant_id: tenant_id} do
      result = OnboardingPackages.list(%{}, tenant: tenant_id)
      assert length(result) >= 3

      ids = Enum.map(packages, & &1.id)
      result_ids = Enum.map(result, & &1.id)

      for id <- ids do
        assert id in result_ids
      end
    end

    test "filters by status", %{tenant_id: tenant_id} do
      result = OnboardingPackages.list(%{status: [:issued]}, tenant: tenant_id)
      assert Enum.all?(result, &(&1.status == :issued))
    end

    test "filters by component_type", %{tenant_id: tenant_id} do
      result = OnboardingPackages.list(%{component_type: [:checker]}, tenant: tenant_id)
      assert Enum.all?(result, &(&1.component_type == :checker))
    end

    test "filters by poller_id", %{tenant_id: tenant_id} do
      result = OnboardingPackages.list(%{poller_id: "poller-123"}, tenant: tenant_id)
      assert Enum.all?(result, &(&1.poller_id == "poller-123"))
    end

    test "respects limit", %{tenant_id: tenant_id} do
      result = OnboardingPackages.list(%{limit: 1}, tenant: tenant_id)
      assert length(result) == 1
    end
  end

  describe "deliver/3" do
    test "delivers package with valid token", %{tenant_id: tenant_id} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-deliver"}, tenant: tenant_id)

      assert {:ok, result} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 tenant: tenant_id
               )

      assert result.package.status == :delivered
      assert result.package.delivered_at != nil
      assert result.join_token == created.join_token
    end

    test "fails with invalid token", %{tenant_id: tenant_id} do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, tenant: tenant_id)

      assert {:error, :invalid_token} =
               OnboardingPackages.deliver(
                 created.package.id,
                 "wrong-token",
                 tenant: tenant_id
               )
    end

    test "fails for already delivered package", %{tenant_id: tenant_id} do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, tenant: tenant_id)

      {:ok, _} =
        OnboardingPackages.deliver(created.package.id, created.download_token, tenant: tenant_id)

      assert {:error, :already_delivered} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 tenant: tenant_id
               )
    end

    test "fails for revoked package", %{tenant_id: tenant_id} do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, tenant: tenant_id)
      {:ok, _} = OnboardingPackages.revoke(created.package.id, tenant: tenant_id)

      assert {:error, :revoked} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 tenant: tenant_id
               )
    end

    test "fails with expired token", %{tenant_id: tenant_id} do
      {:ok, created} =
        OnboardingPackages.create(
          %{label: "test"},
          # Already expired
          download_token_ttl_seconds: -1,
          tenant: tenant_id
        )

      assert {:error, :expired} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 tenant: tenant_id
               )
    end
  end

  describe "revoke/2" do
    test "revokes an issued package", %{tenant_id: tenant_id} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-revoke"}, tenant: tenant_id)

      assert {:ok, package} =
               OnboardingPackages.revoke(created.package.id,
                 reason: "test reason",
                 tenant: tenant_id
               )

      assert package.status == :revoked
      assert package.revoked_at != nil
    end

    test "fails to revoke already revoked package", %{tenant_id: tenant_id} do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, tenant: tenant_id)
      {:ok, _} = OnboardingPackages.revoke(created.package.id, tenant: tenant_id)

      assert {:error, :already_revoked} =
               OnboardingPackages.revoke(created.package.id, tenant: tenant_id)
    end

    test "fails for non-existent package", %{tenant_id: tenant_id} do
      assert {:error, :not_found} =
               OnboardingPackages.revoke(Ecto.UUID.generate(), tenant: tenant_id)
    end
  end

  describe "delete/2" do
    test "soft-deletes a package", %{tenant_id: tenant_id} do
      {:ok, created} = OnboardingPackages.create(%{label: "test-delete"}, tenant: tenant_id)

      assert {:ok, package} =
               OnboardingPackages.delete(
                 created.package.id,
                 actor: "admin@test.com",
                 reason: "cleanup",
                 tenant: tenant_id
               )

      assert package.status == :deleted
      assert package.deleted_at != nil
      assert package.deleted_by == "admin@test.com"
      assert package.deleted_reason == "cleanup"
    end

    test "soft-deleted packages are excluded from list", %{tenant_id: tenant_id} do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-delete-exclude"}, tenant: tenant_id)

      {:ok, _} = OnboardingPackages.delete(created.package.id, tenant: tenant_id)

      result = OnboardingPackages.list(%{}, tenant: tenant_id)
      ids = Enum.map(result, & &1.id)
      refute created.package.id in ids
    end
  end

  describe "defaults/0" do
    test "returns a map with selectors and metadata" do
      defaults = OnboardingPackages.defaults()
      assert is_map(defaults)
      assert Map.has_key?(defaults, :selectors)
      assert Map.has_key?(defaults, :metadata)
    end
  end
end
