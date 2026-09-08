defmodule ServiceRadar.AgentConfig.CompilerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AgentConfig.Compiler

  test "content_hash is stable across map key ordering" do
    config_a = %{
      "enabled" => true,
      "targets" => [
        %{
          "host" => "192.168.1.1",
          "oids" => [
            %{"oid" => ".1.3.6.1.2.1.1.3.0", "name" => "sysUpTime"},
            %{"oid" => ".1.3.6.1.2.1.1.5.0", "name" => "sysName"}
          ]
        }
      ]
    }

    config_b = %{
      "targets" => [
        %{
          "oids" => [
            %{"name" => "sysUpTime", "oid" => ".1.3.6.1.2.1.1.3.0"},
            %{"name" => "sysName", "oid" => ".1.3.6.1.2.1.1.5.0"}
          ],
          "host" => "192.168.1.1"
        }
      ],
      "enabled" => true
    }

    assert Compiler.content_hash(config_a) == Compiler.content_hash(config_b)
  end

  test "content_hash preserves list ordering semantics" do
    config_a = %{"targets" => [%{"host" => "192.168.1.1"}, %{"host" => "192.168.1.2"}]}
    config_b = %{"targets" => [%{"host" => "192.168.1.2"}, %{"host" => "192.168.1.1"}]}

    refute Compiler.content_hash(config_a) == Compiler.content_hash(config_b)
  end
end
