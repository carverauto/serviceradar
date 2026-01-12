defmodule ServiceRadar.SweepJobs.SweepCompilerTest do
  @moduledoc """
  Tests for sweep config generation consistency.

  Ensures that configs created through different paths (bulk edit via static_targets
  and settings UI via target_criteria) produce valid agent-consumable configurations.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.SweepJobs.TargetCriteria

  describe "config validation" do
    test "empty config is valid" do
      config = %{
        "groups" => [],
        "compiled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "config_hash" => "abc123"
      }

      assert :ok = SweepCompiler.validate(config)
    end

    test "config with groups is valid" do
      config = %{
        "groups" => [
          %{
            "id" => "test-group-1",
            "sweep_group_id" => "test-group-1",
            "name" => "Test Group",
            "description" => "A test sweep group",
            "schedule" => %{
              "type" => "interval",
              "interval" => "15m"
            },
            "targets" => ["10.0.1.0/24", "192.168.1.1"],
            "ports" => [22, 80, 443],
            "modes" => ["icmp", "tcp"],
            "settings" => %{
              "concurrency" => 50,
              "timeout" => "3s"
            }
          }
        ],
        "compiled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "config_hash" => "abc123"
      }

      assert :ok = SweepCompiler.validate(config)
    end

    test "config missing groups key is invalid" do
      config = %{
        "compiled_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      assert {:error, "Config missing 'groups' key"} = SweepCompiler.validate(config)
    end

    test "config with non-list groups is invalid" do
      config = %{
        "groups" => "not a list"
      }

      assert {:error, "'groups' must be a list"} = SweepCompiler.validate(config)
    end
  end

  describe "config hash" do
    test "config_hash is deterministic regardless of group ordering" do
      group_a = %{"id" => "a", "name" => "Group A"}
      group_b = %{"id" => "b", "name" => "Group B"}

      hash_one = SweepCompiler.config_hash([group_a, group_b])
      hash_two = SweepCompiler.config_hash([group_b, group_a])

      assert is_binary(hash_one)
      assert hash_one == hash_two
    end

    test "config_hash changes when group content changes" do
      group = %{"id" => "a", "name" => "Group A"}
      updated = %{"id" => "a", "name" => "Group A+", "ports" => [22]}

      refute SweepCompiler.config_hash([group]) == SweepCompiler.config_hash([updated])
    end
  end

  describe "target_criteria DSL" do
    test "empty criteria matches all devices" do
      device = %{hostname: "server1", ip: "10.0.1.5"}
      criteria = %{}

      assert TargetCriteria.matches?(device, criteria)
    end

    test "eq operator matches exact value" do
      device = %{hostname: "server1", ip: "10.0.1.5"}
      criteria = %{"hostname" => %{"eq" => "server1"}}

      assert TargetCriteria.matches?(device, criteria)

      non_matching = %{"hostname" => %{"eq" => "server2"}}
      refute TargetCriteria.matches?(device, non_matching)
    end

    test "neq operator excludes value" do
      device = %{hostname: "server1", ip: "10.0.1.5"}
      criteria = %{"hostname" => %{"neq" => "server2"}}

      assert TargetCriteria.matches?(device, criteria)

      non_matching = %{"hostname" => %{"neq" => "server1"}}
      refute TargetCriteria.matches?(device, non_matching)
    end

    test "contains operator for string fields" do
      device = %{hostname: "prod-server-01", ip: "10.0.1.5"}
      criteria = %{"hostname" => %{"contains" => "server"}}

      assert TargetCriteria.matches?(device, criteria)

      non_matching = %{"hostname" => %{"contains" => "dev"}}
      refute TargetCriteria.matches?(device, non_matching)
    end

    test "contains operator for array fields (discovery_sources)" do
      device = %{discovery_sources: ["armis", "netbox"], ip: "10.0.1.5"}
      criteria = %{"discovery_sources" => %{"contains" => "armis"}}

      assert TargetCriteria.matches?(device, criteria)

      non_matching = %{"discovery_sources" => %{"contains" => "snmp"}}
      refute TargetCriteria.matches?(device, non_matching)
    end

    test "in_cidr operator for IP addresses" do
      device = %{ip: "10.0.1.5"}
      criteria = %{"ip" => %{"in_cidr" => "10.0.0.0/8"}}

      assert TargetCriteria.matches?(device, criteria)

      non_matching = %{"ip" => %{"in_cidr" => "192.168.0.0/16"}}
      refute TargetCriteria.matches?(device, non_matching)
    end

    test "not_in_cidr operator excludes IP range" do
      device = %{ip: "192.168.1.5"}
      criteria = %{"ip" => %{"not_in_cidr" => "10.0.0.0/8"}}

      assert TargetCriteria.matches?(device, criteria)

      non_matching = %{"ip" => %{"not_in_cidr" => "192.168.0.0/16"}}
      refute TargetCriteria.matches?(device, non_matching)
    end

    test "in operator for list values" do
      device = %{type_id: 10}
      criteria = %{"type_id" => %{"in" => [9, 10, 12]}}

      assert TargetCriteria.matches?(device, criteria)

      non_matching = %{"type_id" => %{"in" => [1, 2, 3]}}
      refute TargetCriteria.matches?(device, non_matching)
    end

    test "multiple criteria fields use AND logic" do
      device = %{
        hostname: "prod-router-01",
        type_id: 12,
        ip: "10.0.1.1",
        discovery_sources: ["armis"]
      }

      # All conditions must match
      criteria = %{
        "hostname" => %{"contains" => "router"},
        "type_id" => %{"eq" => 12},
        "ip" => %{"in_cidr" => "10.0.0.0/8"}
      }

      assert TargetCriteria.matches?(device, criteria)

      # One condition fails
      partial_match = %{
        "hostname" => %{"contains" => "router"},
        "type_id" => %{"eq" => 10},
        "ip" => %{"in_cidr" => "10.0.0.0/8"}
      }

      refute TargetCriteria.matches?(device, partial_match)
    end

    test "filter_devices returns matching devices" do
      devices = [
        %{hostname: "server1", ip: "10.0.1.1"},
        %{hostname: "server2", ip: "10.0.1.2"},
        %{hostname: "workstation1", ip: "192.168.1.5"}
      ]

      criteria = %{"ip" => %{"in_cidr" => "10.0.0.0/8"}}
      filtered = TargetCriteria.filter_devices(devices, criteria)

      assert length(filtered) == 2
      assert Enum.all?(filtered, fn d -> String.starts_with?(d.ip, "10.") end)
    end

    test "extract_targets combines criteria and static targets" do
      devices = [
        %{ip: "10.0.1.1"},
        %{ip: "10.0.1.2"},
        %{ip: "192.168.1.5"}
      ]

      criteria = %{"ip" => %{"in_cidr" => "10.0.0.0/8"}}
      static_targets = ["172.16.0.0/12"]

      targets = TargetCriteria.extract_targets(devices, criteria, static_targets)

      # Should include IPs from matching devices + static targets
      assert "10.0.1.1" in targets
      assert "10.0.1.2" in targets
      assert "172.16.0.0/12" in targets
      refute "192.168.1.5" in targets
    end
  end

  describe "criteria validation" do
    test "empty criteria is valid" do
      assert :ok = TargetCriteria.validate(%{})
    end

    test "valid operator spec is accepted" do
      criteria = %{
        "hostname" => %{"contains" => "server"},
        "ip" => %{"in_cidr" => "10.0.0.0/8"}
      }

      assert :ok = TargetCriteria.validate(criteria)
    end

    test "invalid operator is rejected" do
      criteria = %{
        "hostname" => %{"invalid_op" => "value"}
      }

      assert {:error, message} = TargetCriteria.validate(criteria)
      assert String.contains?(message, "invalid operator")
    end

    test "multiple operators per field is rejected" do
      criteria = %{
        "hostname" => %{"eq" => "server1", "neq" => "server2"}
      }

      assert {:error, message} = TargetCriteria.validate(criteria)
      assert String.contains?(message, "multiple operators")
    end
  end

  describe "config format for agent consumption" do
    @tag :integration
    test "compiled group structure matches agent expectations" do
      # This test documents the expected structure for the Go agent
      group = %{
        "id" => "123e4567-e89b-12d3-a456-426614174000",
        "sweep_group_id" => "123e4567-e89b-12d3-a456-426614174000",
        "name" => "Production Network Sweep",
        "description" => "Sweep all production servers",
        "schedule" => %{
          "type" => "interval",
          "interval" => "15m"
        },
        "targets" => [
          "10.0.1.0/24",
          "10.0.2.0/24",
          "192.168.1.100"
        ],
        "ports" => [22, 80, 443, 3389, 8080],
        "modes" => ["icmp", "tcp"],
        "settings" => %{
          "concurrency" => 100,
          "timeout" => "5s",
          "icmp_settings" => %{},
          "tcp_settings" => %{}
        }
      }

      # Verify required fields for agent
      assert is_binary(group["id"])
      assert is_binary(group["name"])
      assert is_map(group["schedule"])
      assert group["schedule"]["type"] in ["interval", "cron"]
      assert is_list(group["targets"])
      assert is_list(group["ports"])
      assert is_list(group["modes"])
      assert is_map(group["settings"])
      assert is_integer(group["settings"]["concurrency"])
      assert is_binary(group["settings"]["timeout"])
    end

    test "targets list contains valid IP addresses and CIDRs" do
      valid_targets = [
        "10.0.1.1",
        "192.168.1.0/24",
        "172.16.0.0/12",
        "10.0.0.0/8"
      ]

      for target <- valid_targets do
        # Should be parseable as IP or CIDR
        assert is_valid_target?(target), "#{target} should be a valid target"
      end
    end

    test "ports list contains valid port numbers" do
      ports = [22, 80, 443, 3389, 8080, 65535]

      for port <- ports do
        assert is_integer(port)
        assert port >= 1 and port <= 65535
      end
    end

    test "modes list contains valid sweep modes" do
      valid_modes = ["icmp", "tcp", "arp"]

      modes = ["icmp", "tcp"]

      for mode <- modes do
        assert mode in valid_modes
      end
    end
  end

  # Helper functions

  defp is_valid_target?(target) when is_binary(target) do
    # Check if it's a valid IP or CIDR
    case String.split(target, "/") do
      [ip_part] ->
        # Plain IP
        case :inet.parse_address(String.to_charlist(ip_part)) do
          {:ok, _} -> true
          _ -> false
        end

      [ip_part, mask_part] ->
        # CIDR notation
        with {:ok, _} <- :inet.parse_address(String.to_charlist(ip_part)),
             {mask, ""} <- Integer.parse(mask_part),
             true <- mask >= 0 and mask <= 32 do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end
end
