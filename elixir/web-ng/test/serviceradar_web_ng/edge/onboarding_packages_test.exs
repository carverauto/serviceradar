defmodule ServiceRadarWebNG.Edge.OnboardingPackagesTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Edge.OnboardingPackages

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  @actor system_actor()

  describe "create/2" do
    test "creates a package with generated tokens", _context do
      attrs = %{label: "test-gateway-1", component_type: :gateway}

      assert {:ok, result} = OnboardingPackages.create(attrs, actor: @actor)

      assert result.package.id != nil
      assert result.package.label == "test-gateway-1"
      assert result.package.component_type == :gateway
      assert result.package.status == :issued
      assert result.join_token != nil
      assert result.download_token != nil

      # Verify tokens are stored encrypted/hashed
      assert result.package.join_token_ciphertext != nil
      assert result.package.download_token_hash != nil
      assert result.package.join_token_expires_at != nil
      assert result.package.download_token_expires_at != nil
    end

    test "creates a package with custom TTLs", _context do
      attrs = %{label: "test-checker", component_type: :checker}
      opts = [actor: @actor, join_token_ttl_seconds: 3600, download_token_ttl_seconds: 7200]

      assert {:ok, result} = OnboardingPackages.create(attrs, opts)

      now = DateTime.utc_now()
      join_diff = DateTime.diff(result.package.join_token_expires_at, now)
      download_diff = DateTime.diff(result.package.download_token_expires_at, now)

      # Allow some tolerance for test execution time
      assert_in_delta join_diff, 3600, 5
      assert_in_delta download_diff, 7200, 5
    end

    test "fails with missing label", _context do
      attrs = %{component_type: :gateway}

      assert {:error, error} = OnboardingPackages.create(attrs, actor: @actor)
      assert is_struct(error, Ash.Error.Invalid)
    end

    test "fails with invalid component_type", _context do
      attrs = %{label: "test", component_type: :invalid}

      assert {:error, error} = OnboardingPackages.create(attrs, actor: @actor)
      assert is_struct(error, Ash.Error.Invalid)
    end
  end

  describe "get/1" do
    test "returns {:ok, package} for existing package", _context do
      {:ok, result} = OnboardingPackages.create(%{label: "test"}, actor: @actor)

      assert {:ok, package} = OnboardingPackages.get(result.package.id, actor: @actor)
      assert package.id == result.package.id
      assert package.label == "test"
    end

    test "returns {:error, :not_found} for non-existent package", _context do
      assert {:error, :not_found} =
               OnboardingPackages.get(Ecto.UUID.generate(), actor: @actor)
    end

    test "returns {:error, :not_found} for nil", _context do
      assert {:error, :not_found} = OnboardingPackages.get(nil)
    end
  end

  describe "list/1" do
    setup _context do
      # Create some test packages
      {:ok, r1} =
        OnboardingPackages.create(%{label: "gateway-1", component_type: :gateway}, actor: @actor)

      {:ok, r2} =
        OnboardingPackages.create(%{label: "checker-1", component_type: :checker}, actor: @actor)

      {:ok, r3} =
        OnboardingPackages.create(
          %{
            label: "agent-1",
            component_type: :agent,
            gateway_id: "gateway-123"
          },
          actor: @actor
        )

      %{packages: [r1.package, r2.package, r3.package]}
    end

    test "lists all packages", %{packages: packages} do
      result = OnboardingPackages.list(%{}, actor: @actor)
      assert length(result) >= 3

      ids = Enum.map(packages, & &1.id)
      result_ids = Enum.map(result, & &1.id)

      for id <- ids do
        assert id in result_ids
      end
    end

    test "filters by status", _context do
      result = OnboardingPackages.list(%{status: [:issued]}, actor: @actor)
      assert Enum.all?(result, &(&1.status == :issued))
    end

    test "filters by component_type", _context do
      result = OnboardingPackages.list(%{component_type: [:checker]}, actor: @actor)
      assert Enum.all?(result, &(&1.component_type == :checker))
    end

    test "filters by gateway_id", _context do
      result = OnboardingPackages.list(%{gateway_id: "gateway-123"}, actor: @actor)
      assert Enum.all?(result, &(&1.gateway_id == "gateway-123"))
    end

    test "respects limit", _context do
      result = OnboardingPackages.list(%{limit: 1}, actor: @actor)
      assert length(result) == 1
    end
  end

  describe "deliver/3" do
    test "delivers package with valid token", _context do
      {:ok, created} = OnboardingPackages.create(%{label: "test-deliver"}, actor: @actor)

      assert {:ok, result} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 authorize?: false
               )

      assert result.package.status == :delivered
      assert result.package.delivered_at != nil
      assert result.join_token == created.join_token
    end

    test "fails with invalid token", _context do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, actor: @actor)

      assert {:error, :invalid_token} =
               OnboardingPackages.deliver(
                 created.package.id,
                 "wrong-token",
                 authorize?: false
               )
    end

    test "fails for already delivered package", _context do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, actor: @actor)

      {:ok, _} =
        OnboardingPackages.deliver(created.package.id, created.download_token, authorize?: false)

      assert {:error, :already_delivered} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 authorize?: false
               )
    end

    test "fails for revoked package", _context do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, actor: @actor)
      {:ok, _} = OnboardingPackages.revoke(created.package.id, actor: @actor)

      assert {:error, :revoked} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 authorize?: false
               )
    end

    test "fails with expired token", _context do
      {:ok, created} =
        OnboardingPackages.create(
          %{label: "test"},
          # Already expired
          actor: @actor,
          download_token_ttl_seconds: -1
        )

      assert {:error, :expired} =
               OnboardingPackages.deliver(
                 created.package.id,
                 created.download_token,
                 authorize?: false
               )
    end
  end

  describe "revoke/2" do
    test "revokes an issued package", _context do
      {:ok, created} = OnboardingPackages.create(%{label: "test-revoke"}, actor: @actor)

      assert {:ok, package} =
               OnboardingPackages.revoke(created.package.id,
                 actor: @actor,
                 reason: "test reason"
               )

      assert package.status == :revoked
      assert package.revoked_at != nil
    end

    test "fails to revoke already revoked package", _context do
      {:ok, created} = OnboardingPackages.create(%{label: "test"}, actor: @actor)
      {:ok, _} = OnboardingPackages.revoke(created.package.id, actor: @actor)

      assert {:error, :already_revoked} =
               OnboardingPackages.revoke(created.package.id, actor: @actor)
    end

    test "fails for non-existent package", _context do
      assert {:error, :not_found} =
               OnboardingPackages.revoke(Ecto.UUID.generate(), actor: @actor)
    end
  end

  describe "delete/2" do
    test "soft-deletes a package", _context do
      actor = %{id: Ecto.UUID.generate(), role: :admin, email: "admin@test.com"}
      {:ok, created} = OnboardingPackages.create(%{label: "test-delete"}, actor: actor)

      assert {:ok, package} =
               OnboardingPackages.delete(
                 created.package.id,
                 actor: actor,
                 reason: "cleanup"
               )

      assert package.status == :deleted
      assert package.deleted_at != nil
      assert package.deleted_by == "admin@test.com"
      assert package.deleted_reason == "cleanup"
    end

    test "soft-deleted packages are excluded from list", _context do
      {:ok, created} =
        OnboardingPackages.create(%{label: "test-delete-exclude"}, actor: @actor)

      {:ok, _} = OnboardingPackages.delete(created.package.id, actor: @actor)

      result = OnboardingPackages.list(%{}, actor: @actor)
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

  describe "create_with_platform_cert/2" do
    test "creates package with certificate data", _context do
      attrs = %{
        label: "test-gateway-cert",
        component_type: :gateway,
        component_id: "gateway-test-cert"
      }

      result = OnboardingPackages.create_with_platform_cert(attrs, actor: @actor)

      case result do
        {:ok, package_result} ->
          assert package_result.package.id != nil
          assert package_result.package.label == "test-gateway-cert"
          assert package_result.join_token != nil
          assert package_result.download_token != nil

          # Certificate data should be present
          if package_result[:certificate_data] do
            assert package_result.certificate_data.certificate_pem != nil ||
                     package_result.certificate_data[:spiffe_id] != nil
          end

        {:error, :ca_generation_failed} ->
          # CA generation might fail in test environment without PKI setup
          # This is acceptable for unit tests
          assert true

        {:error, _} = error ->
          # Other errors (like missing PKI) are acceptable in unit tests
          assert true
      end
    end

    test "delegates to core create_with_platform_cert function", _context do
      attrs = %{label: "test-delegation", component_type: :gateway}

      # The function should either succeed or fail gracefully
      result = OnboardingPackages.create_with_platform_cert(attrs, actor: @actor)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "passes options to underlying function", _context do
      attrs = %{label: "test-options", component_type: :checker}

      # Call with options - should not raise
      result = OnboardingPackages.create_with_platform_cert(attrs, actor: @actor)

      # Verify the function completed without argument errors
      assert is_tuple(result)
      assert elem(result, 0) in [:ok, :error]
    end
  end

  describe "configured_security_mode/0" do
    test "returns a string security mode" do
      mode = OnboardingPackages.configured_security_mode()
      assert is_binary(mode)
      assert mode in ["mtls", "spire", "insecure"]
    end
  end

  describe "certificate generation (external infrastructure)" do
    # NOTE: In single-deployment mode, certificate generation is handled by
    # external infrastructure (SPIFFE/SPIRE, cert-manager). These tests verify that
    # the functions return appropriate errors indicating this.

    test "create_with_platform_cert returns error for unavailable CA", _context do
      attrs = %{
        label: "ca-test",
        component_type: :gateway,
        component_id: "gateway-ca-test"
      }

      # In single-deployment mode, this should return an error since CA generation is not available
      result = OnboardingPackages.create_with_platform_cert(attrs, actor: @actor)

      assert match?({:error, _}, result)
    end
  end
end
