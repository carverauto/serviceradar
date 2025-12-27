defmodule ServiceRadar.Infrastructure.PartitionTest do
  @moduledoc """
  Tests for Partition resource.

  Verifies:
  - Partition creation and CRUD
  - Enable/disable operations
  - Read actions (by_id, by_slug, enabled, by_site, by_environment)
  - Calculations (display_name, cidr_count, environment_label, status_color)
  - Policy enforcement
  - Tenant isolation
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Infrastructure.Partition

  describe "partition creation" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "can create a partition with required fields", %{tenant: tenant} do
      result =
        Partition
        |> Ash.Changeset.for_create(:create, %{
          name: "Production Network",
          slug: "production-network",
          cidr_ranges: ["10.0.0.0/8", "192.168.0.0/16"]
        }, actor: system_actor(), authorize?: false, tenant: tenant.id)
        |> Ash.create()

      assert {:ok, partition} = result
      assert partition.name == "Production Network"
      assert partition.slug == "production-network"
      assert partition.cidr_ranges == ["10.0.0.0/8", "192.168.0.0/16"]
      assert partition.enabled == true  # default
      assert partition.tenant_id == tenant.id
    end

    test "sets timestamps on creation", %{tenant: tenant} do
      partition = partition_fixture(tenant)

      assert partition.created_at != nil
      assert partition.updated_at != nil
      assert DateTime.diff(DateTime.utc_now(), partition.created_at, :second) < 60
    end

    test "supports all environment types", %{tenant: tenant} do
      for environment <- ["production", "staging", "development", "lab"] do
        unique = System.unique_integer([:positive])
        partition = partition_fixture(tenant, %{
          slug: "partition-env-#{environment}-#{unique}",
          environment: environment
        })
        assert partition.environment == environment
      end
    end

    test "supports all connectivity types", %{tenant: tenant} do
      for connectivity <- ["direct", "vpn", "proxy"] do
        unique = System.unique_integer([:positive])
        partition = partition_fixture(tenant, %{
          slug: "partition-conn-#{connectivity}-#{unique}",
          connectivity_type: connectivity
        })
        assert partition.connectivity_type == connectivity
      end
    end
  end

  describe "update actions" do
    setup do
      tenant = tenant_fixture()
      partition = partition_fixture(tenant)
      {:ok, tenant: tenant, partition: partition}
    end

    test "admin can update partition", %{tenant: tenant, partition: partition} do
      actor = admin_actor(tenant)

      result =
        partition
        |> Ash.Changeset.for_update(:update, %{
          name: "Updated Network",
          description: "Updated description",
          cidr_ranges: ["172.16.0.0/12"]
        }, actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.name == "Updated Network"
      assert updated.description == "Updated description"
      assert updated.cidr_ranges == ["172.16.0.0/12"]
      assert updated.updated_at != nil
    end

    test "operator cannot update partition (admin only)", %{tenant: tenant, partition: partition} do
      actor = operator_actor(tenant)

      result =
        partition
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "viewer cannot update partition", %{tenant: tenant, partition: partition} do
      actor = viewer_actor(tenant)

      result =
        partition
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "enable/disable actions" do
    setup do
      tenant = tenant_fixture()
      partition = partition_fixture(tenant)
      {:ok, tenant: tenant, partition: partition}
    end

    test "admin can disable partition", %{tenant: tenant, partition: partition} do
      actor = admin_actor(tenant)

      {:ok, disabled} =
        partition
        |> Ash.Changeset.for_update(:disable, %{},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert disabled.enabled == false
      assert disabled.updated_at != nil
    end

    test "admin can enable disabled partition", %{tenant: tenant, partition: partition} do
      actor = admin_actor(tenant)

      # First disable
      {:ok, disabled} =
        partition
        |> Ash.Changeset.for_update(:disable, %{},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      # Then enable
      {:ok, enabled} =
        disabled
        |> Ash.Changeset.for_update(:enable, %{},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert enabled.enabled == true
    end

    test "operator cannot enable/disable partition", %{tenant: tenant, partition: partition} do
      actor = operator_actor(tenant)

      result =
        partition
        |> Ash.Changeset.for_update(:disable, %{},
          actor: actor, tenant: tenant.id)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "read actions" do
    setup do
      tenant = tenant_fixture()

      partition_enabled = partition_fixture(tenant, %{
        name: "Enabled Partition",
        slug: "enabled-partition",
        site: "datacenter-1",
        environment: "production"
      })

      partition_disabled = partition_fixture(tenant, %{
        name: "Disabled Partition",
        slug: "disabled-partition",
        enabled: false,
        site: "datacenter-1",
        environment: "staging"
      })

      {:ok,
       tenant: tenant,
       partition_enabled: partition_enabled,
       partition_disabled: partition_disabled}
    end

    test "by_id returns specific partition", %{tenant: tenant, partition_enabled: partition} do
      actor = viewer_actor(tenant)

      {:ok, found} =
        Partition
        |> Ash.Query.for_read(:by_id, %{id: partition.id}, actor: actor, tenant: tenant.id)
        |> Ash.read_one()

      assert found.id == partition.id
    end

    test "by_slug returns partition by slug", %{tenant: tenant, partition_enabled: partition} do
      actor = viewer_actor(tenant)

      {:ok, found} =
        Partition
        |> Ash.Query.for_read(:by_slug, %{slug: partition.slug}, actor: actor, tenant: tenant.id)
        |> Ash.read_one()

      assert found.slug == partition.slug
    end

    test "enabled action returns only enabled partitions", %{
      tenant: tenant,
      partition_enabled: enabled,
      partition_disabled: disabled
    } do
      actor = viewer_actor(tenant)

      {:ok, partitions} = Ash.read(Partition, action: :enabled, actor: actor, tenant: tenant.id)
      ids = Enum.map(partitions, & &1.id)

      assert enabled.id in ids
      refute disabled.id in ids
    end

    test "by_site filters by site", %{
      tenant: tenant,
      partition_enabled: partition
    } do
      actor = viewer_actor(tenant)

      {:ok, partitions} =
        Partition
        |> Ash.Query.for_read(:by_site, %{site: "datacenter-1"}, actor: actor, tenant: tenant.id)
        |> Ash.read()

      assert length(partitions) >= 1
      assert Enum.any?(partitions, fn p -> p.id == partition.id end)
    end

    test "by_environment filters by environment", %{
      tenant: tenant,
      partition_enabled: production,
      partition_disabled: staging
    } do
      actor = viewer_actor(tenant)

      {:ok, prod_partitions} =
        Partition
        |> Ash.Query.for_read(:by_environment, %{environment: "production"},
          actor: actor, tenant: tenant.id)
        |> Ash.read()

      prod_ids = Enum.map(prod_partitions, & &1.id)
      assert production.id in prod_ids
      refute staging.id in prod_ids
    end
  end

  describe "calculations" do
    setup do
      tenant = tenant_fixture()
      {:ok, tenant: tenant}
    end

    test "display_name uses name or slug", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      # With name
      partition_named = partition_fixture(tenant, %{
        name: "Named Partition",
        slug: "named-partition-slug"
      })

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^partition_named.id)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.display_name == "Named Partition"
    end

    test "environment_label returns formatted labels", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      label_map = %{
        "production" => "Production",
        "staging" => "Staging",
        "development" => "Development",
        "lab" => "Lab"
      }

      for {environment, expected_label} <- label_map do
        unique = System.unique_integer([:positive])
        partition = partition_fixture(tenant, %{
          slug: "partition-label-#{environment}-#{unique}",
          environment: environment
        })

        {:ok, [loaded]} =
          Partition
          |> Ash.Query.filter(id == ^partition.id)
          |> Ash.Query.load(:environment_label)
          |> Ash.read(actor: actor, tenant: tenant.id)

        assert loaded.environment_label == expected_label
      end
    end

    test "status_color returns green for enabled, gray for disabled", %{tenant: tenant} do
      actor = admin_actor(tenant)

      # Enabled partition
      partition_enabled = partition_fixture(tenant, %{slug: "status-color-enabled"})

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^partition_enabled.id)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.status_color == "green"

      # Disable it
      {:ok, disabled} =
        partition_enabled
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor, tenant: tenant.id)
        |> Ash.update()

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^disabled.id)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.status_color == "gray"
    end

    test "cidr_count returns number of CIDR ranges", %{tenant: tenant} do
      actor = viewer_actor(tenant)

      partition = partition_fixture(tenant, %{
        slug: "cidr-count-test",
        cidr_ranges: ["10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"]
      })

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^partition.id)
        |> Ash.Query.load(:cidr_count)
        |> Ash.read(actor: actor, tenant: tenant.id)

      assert loaded.cidr_count == 3
    end
  end

  describe "tenant isolation" do
    setup do
      tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a-partition"})
      tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b-partition"})

      partition_a = partition_fixture(tenant_a, %{slug: "partition-a"})
      partition_b = partition_fixture(tenant_b, %{slug: "partition-b"})

      {:ok,
       tenant_a: tenant_a,
       tenant_b: tenant_b,
       partition_a: partition_a,
       partition_b: partition_b}
    end

    test "user cannot see partitions from other tenant", %{
      tenant_a: tenant_a,
      partition_a: partition_a,
      partition_b: partition_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, partitions} = Ash.read(Partition, actor: actor, tenant: tenant_a.id)
      ids = Enum.map(partitions, & &1.id)

      assert partition_a.id in ids
      refute partition_b.id in ids
    end

    test "user cannot update partition from other tenant", %{
      tenant_a: tenant_a,
      partition_b: partition_b
    } do
      actor = admin_actor(tenant_a)

      result =
        partition_b
        |> Ash.Changeset.for_update(:update, %{name: "Hacked"},
          actor: actor, tenant: tenant_a.id)
        |> Ash.update()

      assert {:error, error} = result
      assert match?(%Ash.Error.Forbidden{}, error) or match?(%Ash.Error.Invalid{}, error)
    end

    test "user cannot get partition from other tenant by id", %{
      tenant_a: tenant_a,
      partition_b: partition_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, result} =
        Partition
        |> Ash.Query.for_read(:by_id, %{id: partition_b.id}, actor: actor, tenant: tenant_a.id)
        |> Ash.read_one()

      assert result == nil
    end

    test "user cannot get partition from other tenant by slug", %{
      tenant_a: tenant_a,
      partition_b: partition_b
    } do
      actor = viewer_actor(tenant_a)

      {:ok, result} =
        Partition
        |> Ash.Query.for_read(:by_slug, %{slug: partition_b.slug}, actor: actor, tenant: tenant_a.id)
        |> Ash.read_one()

      assert result == nil
    end
  end
end
