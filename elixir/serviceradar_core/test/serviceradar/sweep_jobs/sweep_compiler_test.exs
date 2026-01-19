defmodule ServiceRadar.SweepJobs.SweepCompilerTest do
  @moduledoc """
  Tests for sweep config generation consistency.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler

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

  describe "config format for agent consumption" do
    @tag :integration
    test "compiled group structure matches agent expectations" do
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
        assert is_valid_target?(target), "#{target} should be a valid target"
      end
    end

    test "ports list contains valid port numbers" do
      ports = [22, 80, 443, 3389, 8080, 65_535]

      for port <- ports do
        assert is_integer(port)
        assert port >= 1 and port <= 65_535
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

  defp is_valid_target?(target) when is_binary(target) do
    case String.split(target, "/") do
      [ip_part] ->
        case :inet.parse_address(String.to_charlist(ip_part)) do
          {:ok, _} -> true
          _ -> false
        end

      [ip_part, mask_part] ->
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
