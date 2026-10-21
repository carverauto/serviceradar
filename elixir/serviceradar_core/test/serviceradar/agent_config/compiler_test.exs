defmodule ServiceRadar.AgentConfig.CompilerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.SNMPProfiles.SNMPProfile

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

  test "SNMPCompiler returns :repo_unavailable without error logs when Repo is not started" do
    actor = SystemActor.system(:test)

    profile = %SNMPProfile{
      id: "00000000-0000-0000-0000-000000000001",
      name: "Synthetic Profile",
      enabled: true,
      is_default: true,
      target_query: "in:devices",
      oid_template_ids: []
    }

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :repo_unavailable} =
                 SNMPCompiler.compile("default", "agent-01", actor: actor)

        assert {:error, :repo_unavailable} =
                 SNMPCompiler.compile_profile(profile, actor,
                   agent_id: "agent-01",
                   partition: "default"
                 )

        assert {:error, :repo_unavailable} =
                 SNMPCompiler.execute_target_query("in:devices", actor)

        assert {:error, :repo_unavailable} =
                 SNMPCompiler.load_template_oids(
                   ["00000000-0000-0000-0000-000000000002"],
                   actor
                 )

        assert nil == SNMPCompiler.resolve_profile("sr:device:01", "agent-01", actor)
        assert :all_online == SNMPCompiler.affected_agents_for_device("sr:device:01")
      end)

    refute log =~ "SNMPCompiler"
    refute log =~ "SNMP ownership lookup failed"

    assert SNMPCompiler.repo_unavailable_error?(%RuntimeError{
             message:
               "could not lookup Ecto repo ServiceRadar.Repo because it was not started or it does not exist"
           })

    assert SNMPCompiler.repo_unavailable_error?({
             :target_query_failed,
             %RuntimeError{
               message:
                 "could not lookup Ecto repo ServiceRadar.Repo because it was not started or it does not exist"
             }
           })

    refute SNMPCompiler.repo_unavailable_error?(%RuntimeError{message: "database timeout"})
  end
end
