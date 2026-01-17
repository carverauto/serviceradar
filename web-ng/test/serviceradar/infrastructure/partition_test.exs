defmodule ServiceRadar.Infrastructure.PartitionTest do
  @moduledoc """
  Tests for Partition resource.

  Verifies:
  - Partition creation and CRUD
  - Enable/disable operations
  - Read actions (by_id, by_slug, enabled, by_site, by_environment)
  - Calculations (display_name, cidr_count, environment_label, status_color)
  - Policy enforcement
  """
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  alias ServiceRadar.Infrastructure.Partition

  describe "partition creation" do
    test "can create a partition with required fields" do
      result =
        Partition
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Production Network",
            slug: "production-network",
            cidr_ranges: ["10.0.0.0/8", "192.168.0.0/16"]
          },
          actor: system_actor()
        )
        |> Ash.create()

      assert {:ok, partition} = result
      assert partition.name == "Production Network"
      assert partition.slug == "production-network"
      assert partition.cidr_ranges == ["10.0.0.0/8", "192.168.0.0/16"]
      # default
      assert partition.enabled == true
    end

    test "sets timestamps on creation" do
      partition = partition_fixture()

      assert partition.created_at != nil
      assert partition.updated_at != nil
      assert DateTime.diff(DateTime.utc_now(), partition.created_at, :second) < 60
    end

    test "supports all environment types" do
      for environment <- ["production", "staging", "development", "lab"] do
        unique = System.unique_integer([:positive])

        partition =
          partition_fixture(%{
            slug: "partition-env-#{environment}-#{unique}",
            environment: environment
          })

        assert partition.environment == environment
      end
    end

    test "supports all connectivity types" do
      for connectivity <- ["direct", "vpn", "proxy"] do
        unique = System.unique_integer([:positive])

        partition =
          partition_fixture(%{
            slug: "partition-conn-#{connectivity}-#{unique}",
            connectivity_type: connectivity
          })

        assert partition.connectivity_type == connectivity
      end
    end
  end

  describe "update actions" do
    setup do
      partition = partition_fixture()
      {:ok, partition: partition}
    end

    test "admin can update partition", %{partition: partition} do
      actor = admin_actor()

      result =
        partition
        |> Ash.Changeset.for_update(
          :update,
          %{
            name: "Updated Network",
            description: "Updated description",
            cidr_ranges: ["172.16.0.0/12"]
          },
          actor: actor
        )
        |> Ash.update()

      assert {:ok, updated} = result
      assert updated.name == "Updated Network"
      assert updated.description == "Updated description"
      assert updated.cidr_ranges == ["172.16.0.0/12"]
      assert updated.updated_at != nil
    end

    test "operator cannot update partition (admin only)", %{partition: partition} do
      actor = operator_actor()

      result =
        partition
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"},
          actor: actor
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "viewer cannot update partition", %{partition: partition} do
      actor = viewer_actor()

      result =
        partition
        |> Ash.Changeset.for_update(:update, %{name: "Should Fail"},
          actor: actor
        )
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "enable/disable actions" do
    setup do
      partition = partition_fixture()
      {:ok, partition: partition}
    end

    test "admin can disable partition", %{partition: partition} do
      actor = admin_actor()

      {:ok, disabled} =
        partition
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      assert disabled.enabled == false
      assert disabled.updated_at != nil
    end

    test "admin can enable disabled partition", %{partition: partition} do
      actor = admin_actor()

      # First disable
      {:ok, disabled} =
        partition
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      # Then enable
      {:ok, enabled} =
        disabled
        |> Ash.Changeset.for_update(:enable, %{}, actor: actor)
        |> Ash.update()

      assert enabled.enabled == true
    end

    test "operator cannot enable/disable partition", %{partition: partition} do
      actor = operator_actor()

      result =
        partition
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  describe "read actions" do
    setup do
      partition_enabled =
        partition_fixture(%{
          name: "Enabled Partition",
          slug: "enabled-partition",
          site: "datacenter-1",
          environment: "production"
        })

      partition_disabled =
        partition_fixture(%{
          name: "Disabled Partition",
          slug: "disabled-partition",
          enabled: false,
          site: "datacenter-1",
          environment: "staging"
        })

      {:ok,
       partition_enabled: partition_enabled,
       partition_disabled: partition_disabled}
    end

    test "by_id returns specific partition", %{partition_enabled: partition} do
      actor = viewer_actor()

      {:ok, found} =
        Partition
        |> Ash.Query.for_read(:by_id, %{id: partition.id}, actor: actor)
        |> Ash.read_one()

      assert found.id == partition.id
    end

    test "by_slug returns partition by slug", %{partition_enabled: partition} do
      actor = viewer_actor()

      {:ok, found} =
        Partition
        |> Ash.Query.for_read(:by_slug, %{slug: partition.slug}, actor: actor)
        |> Ash.read_one()

      assert found.slug == partition.slug
    end

    test "enabled action returns only enabled partitions", %{
      partition_enabled: enabled,
      partition_disabled: disabled
    } do
      actor = viewer_actor()

      {:ok, partitions} = Ash.read(Partition, action: :enabled, actor: actor)
      ids = Enum.map(partitions, & &1.id)

      assert enabled.id in ids
      refute disabled.id in ids
    end

    test "by_site filters by site", %{
      partition_enabled: partition
    } do
      actor = viewer_actor()

      {:ok, partitions} =
        Partition
        |> Ash.Query.for_read(:by_site, %{site: "datacenter-1"}, actor: actor)
        |> Ash.read()

      refute Enum.empty?(partitions)
      assert Enum.any?(partitions, fn p -> p.id == partition.id end)
    end

    test "by_environment filters by environment", %{
      partition_enabled: production,
      partition_disabled: staging
    } do
      actor = viewer_actor()

      {:ok, prod_partitions} =
        Partition
        |> Ash.Query.for_read(:by_environment, %{environment: "production"},
          actor: actor
        )
        |> Ash.read()

      prod_ids = Enum.map(prod_partitions, & &1.id)
      assert production.id in prod_ids
      refute staging.id in prod_ids
    end
  end

  describe "calculations" do
    test "display_name uses name or slug" do
      actor = viewer_actor()

      # With name
      partition_named =
        partition_fixture(%{
          name: "Named Partition",
          slug: "named-partition-slug"
        })

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^partition_named.id)
        |> Ash.Query.load(:display_name)
        |> Ash.read(actor: actor)

      assert loaded.display_name == "Named Partition"
    end

    test "environment_label returns formatted labels" do
      actor = viewer_actor()

      label_map = %{
        "production" => "Production",
        "staging" => "Staging",
        "development" => "Development",
        "lab" => "Lab"
      }

      for {environment, expected_label} <- label_map do
        unique = System.unique_integer([:positive])

        partition =
          partition_fixture(%{
            slug: "partition-label-#{environment}-#{unique}",
            environment: environment
          })

        {:ok, [loaded]} =
          Partition
          |> Ash.Query.filter(id == ^partition.id)
          |> Ash.Query.load(:environment_label)
          |> Ash.read(actor: actor)

        assert loaded.environment_label == expected_label
      end
    end

    test "status_color returns green for enabled, gray for disabled" do
      actor = admin_actor()

      # Enabled partition
      partition_enabled = partition_fixture(%{slug: "status-color-enabled"})

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^partition_enabled.id)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor)

      assert loaded.status_color == "green"

      # Disable it
      {:ok, disabled} =
        partition_enabled
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^disabled.id)
        |> Ash.Query.load(:status_color)
        |> Ash.read(actor: actor)

      assert loaded.status_color == "gray"
    end

    test "cidr_count returns number of CIDR ranges" do
      actor = viewer_actor()

      partition =
        partition_fixture(%{
          slug: "cidr-count-test",
          cidr_ranges: ["10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"]
        })

      {:ok, [loaded]} =
        Partition
        |> Ash.Query.filter(id == ^partition.id)
        |> Ash.Query.load(:cidr_count)
        |> Ash.read(actor: actor)

      assert loaded.cidr_count == 3
    end
  end
end
