defmodule ServiceRadarWebNG.Edge.OnboardingPackagesTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Edge.OnboardingPackages

  describe "create/2" do
    test "creates a package with generated tokens" do
      attrs = %{label: "test-poller-1", component_type: :poller}

      assert {:ok, result} = OnboardingPackages.create(attrs)

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

    test "creates a package with custom TTLs" do
      attrs = %{label: "test-checker", component_type: :checker}
      opts = [join_token_ttl_seconds: 3600, download_token_ttl_seconds: 7200]

      assert {:ok, result} = OnboardingPackages.create(attrs, opts)

      now = DateTime.utc_now()
      join_diff = DateTime.diff(result.package.join_token_expires_at, now)
      download_diff = DateTime.diff(result.package.download_token_expires_at, now)

      # Allow some tolerance for test execution time
      assert_in_delta join_diff, 3600, 5
      assert_in_delta download_diff, 7200, 5
    end

    test "fails with missing label" do
      attrs = %{component_type: :poller}

      assert {:error, error} = OnboardingPackages.create(attrs)
      assert is_struct(error, Ash.Error.Invalid)
    end

    test "fails with invalid component_type" do
      attrs = %{label: "test", component_type: :invalid}

      assert {:error, error} = OnboardingPackages.create(attrs)
      assert is_struct(error, Ash.Error.Invalid)
    end
  end

  describe "get/1" do
    test "returns {:ok, package} for existing package" do
      {:ok, result} = OnboardingPackages.create(%{label: "test"})

      assert {:ok, package} = OnboardingPackages.get(result.package.id)
      assert package.id == result.package.id
      assert package.label == "test"
    end

    test "returns {:error, :not_found} for non-existent package" do
      assert {:error, :not_found} = OnboardingPackages.get(Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} for nil" do
      assert {:error, :not_found} = OnboardingPackages.get(nil)
    end
  end

  describe "list/1" do
    setup do
      # Create some test packages
      {:ok, r1} = OnboardingPackages.create(%{label: "poller-1", component_type: :poller})
      {:ok, r2} = OnboardingPackages.create(%{label: "checker-1", component_type: :checker})

      {:ok, r3} =
        OnboardingPackages.create(%{
          label: "agent-1",
          component_type: :agent,
          poller_id: "poller-123"
        })

      %{packages: [r1.package, r2.package, r3.package]}
    end

    test "lists all packages", %{packages: packages} do
      result = OnboardingPackages.list()
      assert length(result) >= 3

      ids = Enum.map(packages, & &1.id)
      result_ids = Enum.map(result, & &1.id)

      for id <- ids do
        assert id in result_ids
      end
    end

    test "filters by status" do
      result = OnboardingPackages.list(%{status: [:issued]})
      assert Enum.all?(result, &(&1.status == :issued))
    end

    test "filters by component_type" do
      result = OnboardingPackages.list(%{component_type: [:checker]})
      assert Enum.all?(result, &(&1.component_type == :checker))
    end

    test "filters by poller_id" do
      result = OnboardingPackages.list(%{poller_id: "poller-123"})
      assert Enum.all?(result, &(&1.poller_id == "poller-123"))
    end

    test "respects limit" do
      result = OnboardingPackages.list(%{limit: 1})
      assert length(result) == 1
    end
  end

  describe "deliver/3" do
    test "delivers package with valid token" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-deliver"})

      assert {:ok, result} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token
               )

      assert result.package.status == :delivered
      assert result.package.delivered_at != nil
      assert result.join_token == created.join_token
    end

    test "fails with invalid token" do
      {:ok, created} = OnboardingPackages.create(%{label: "test"})

      assert {:error, :invalid_token} =
               OnboardingPackages.deliver(
                 created.package.id,
                 "wrong-token"
               )
    end

    test "fails for already delivered package" do
      {:ok, created} = OnboardingPackages.create(%{label: "test"})
      {:ok, _} = OnboardingPackages.deliver(created.package.id, created.download_token)

      assert {:error, :already_delivered} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token
               )
    end

    test "fails for revoked package" do
      {:ok, created} = OnboardingPackages.create(%{label: "test"})
      {:ok, _} = OnboardingPackages.revoke(created.package.id)

      assert {:error, :revoked} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token
               )
    end

    test "fails with expired token" do
      {:ok, created} =
        OnboardingPackages.create(
          %{label: "test"},
          # Already expired
          download_token_ttl_seconds: -1
        )

      assert {:error, :expired} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token
               )
    end
  end

  describe "revoke/2" do
    test "revokes an issued package" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-revoke"})

      assert {:ok, package} = OnboardingPackages.revoke(created.package.id, reason: "test reason")

      assert package.status == :revoked
      assert package.revoked_at != nil
    end

    test "fails to revoke already revoked package" do
      {:ok, created} = OnboardingPackages.create(%{label: "test"})
      {:ok, _} = OnboardingPackages.revoke(created.package.id)

      assert {:error, :already_revoked} = OnboardingPackages.revoke(created.package.id)
    end

    test "fails for non-existent package" do
      assert {:error, :not_found} = OnboardingPackages.revoke(Ecto.UUID.generate())
    end
  end

  describe "delete/2" do
    test "soft-deletes a package" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-delete"})

      assert {:ok, package} =
               OnboardingPackages.delete(
                 created.package.id,
                 actor: "admin@test.com",
                 reason: "cleanup"
               )

      assert package.status == :deleted
      assert package.deleted_at != nil
      assert package.deleted_by == "admin@test.com"
      assert package.deleted_reason == "cleanup"
    end

    test "soft-deleted packages are excluded from list" do
      {:ok, created} = OnboardingPackages.create(%{label: "test-delete-exclude"})
      {:ok, _} = OnboardingPackages.delete(created.package.id)

      result = OnboardingPackages.list()
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
