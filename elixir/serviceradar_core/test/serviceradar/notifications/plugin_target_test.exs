defmodule ServiceRadar.Notifications.PluginTargetTest do
  @moduledoc """
  Which agent runs a plugin-backed notification, and what stops it running at
  all (tasks 3.3.1, 3.3.2).

  The two database reads are injected, so every refusal below is exercised
  without a database. What is asserted is the part that is easy to get wrong and
  expensive to get wrong:

    * a `:control_plane` plugin channel goes to the PLATFORM-resident agent, not
      to nowhere and not to the channel's own `agent_uid`;
    * an unapproved or revoked package is refused at dispatch even though the
      provider row still says `:active`, because a notifier is a signal and not
      a guarantee;
    * `notify:v1` is checked against the EFFECTIVE capability set - the approved
      list when approval narrowed anything, the manifest's list when it did not -
      the same rule `AgentConfigGenerator` applies, so core never promises a
      capability the agent then refuses.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.PluginTarget

  @package_id "11111111-1111-1111-1111-111111111111"
  @assignment_id "22222222-2222-2222-2222-222222222222"

  defp package(overrides \\ %{}) do
    Map.merge(
      %{
        id: @package_id,
        plugin_id: "acme-notifier",
        version: "1.0.0",
        status: :approved,
        approved_capabilities: ["get_config", "log", "http_request", "notify:v1"],
        manifest: %{"capabilities" => ["get_config", "log", "http_request", "notify:v1"]}
      },
      overrides
    )
  end

  defp provider(overrides \\ %{}) do
    Map.merge(
      %{
        provider_type: :wasm_plugin,
        provider_key: "acme",
        action_key: "pagerduty",
        plugin_package_id: @package_id
      },
      overrides
    )
  end

  defp channel(overrides \\ %{}) do
    Map.merge(
      %{execution_route: :control_plane, agent_uid: nil, partition_id: nil},
      overrides
    )
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        platform_agent: {"k8s-agent", "default"},
        load_package: fn _id -> {:ok, package()} end,
        load_assignment: fn _uid, _partition, _package -> {:ok, %{id: @assignment_id}} end
      ],
      overrides
    )
  end

  defp resolve(channel, provider, overrides \\ []) do
    PluginTarget.resolve(channel, provider, opts(overrides))
  end

  describe "which agent runs it" do
    test "a :control_plane plugin channel goes to the platform-resident agent" do
      assert {:ok, target} = resolve(channel(), provider())

      assert target.agent_uid == "k8s-agent"
      assert target.partition_id == "default"
      assert target.execution_route == :control_plane
      assert target.plugin_assignment_id == @assignment_id
      assert target.plugin_package_id == @package_id
    end

    test "an :edge_agent channel goes to the agent it names, not the platform one" do
      channel =
        channel(%{execution_route: :edge_agent, agent_uid: "site-1", partition_id: "east"})

      assert {:ok, target} = resolve(channel, provider())

      assert target.agent_uid == "site-1"
      assert target.partition_id == "east"
      assert target.execution_route == :edge_agent
    end

    test "the partition is part of the assignment lookup when the channel carries one" do
      channel =
        channel(%{execution_route: :edge_agent, agent_uid: "site-1", partition_id: "east"})

      test_pid = self()

      assert {:ok, _target} =
               resolve(channel, provider(),
                 load_assignment: fn uid, partition, package ->
                   send(test_pid, {:assignment_lookup, uid, partition, package})
                   {:ok, %{id: @assignment_id}}
                 end
               )

      assert_received {:assignment_lookup, "site-1", "east", @package_id}
    end

    test "an unconfigured platform agent refuses rather than guessing one" do
      assert {:error, {"platform_agent_unconfigured", message}} =
               resolve(channel(), provider(), platform_agent: nil)

      assert message =~ "SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_ID"
    end

    test "an :edge_agent channel with no agent is refused" do
      channel = channel(%{execution_route: :edge_agent, agent_uid: "   "})

      assert {:error, {"edge_agent_unbound", _message}} = resolve(channel, provider())
    end
  end

  describe "the package must be approved (tasks 3.3.2)" do
    for status <- [:staged, :denied, :revoked] do
      test "a #{status} package cannot dispatch" do
        assert {:error, {"plugin_package_unapproved", message}} =
                 resolve(channel(), provider(),
                   load_package: fn _id -> {:ok, package(%{status: unquote(status)})} end
                 )

        assert message =~ "acme-notifier@1.0.0"
        assert message =~ "only an approved package may deliver"
      end
    end

    test "a package that cannot be read is refused rather than assumed approved" do
      assert {:error, {"plugin_package_unreadable", _message}} =
               resolve(channel(), provider(), load_package: fn _id -> {:error, :not_found} end)
    end

    test "a provider with no package reference is refused" do
      assert {:error, {"provider_has_no_package", _message}} =
               resolve(channel(), provider(%{plugin_package_id: nil}))
    end
  end

  describe "notify:v1 against the effective capability set" do
    test "the approved list wins when approval narrowed the manifest" do
      narrowed =
        package(%{
          approved_capabilities: ["get_config", "log"],
          manifest: %{"capabilities" => ["get_config", "log", "notify:v1"]}
        })

      assert {:error, {"notify_capability_denied", message}} =
               resolve(channel(), provider(), load_package: fn _id -> {:ok, narrowed} end)

      assert message =~ "notify:v1"
    end

    test "an empty approved list falls back to the manifest's declared set" do
      unnarrowed =
        package(%{
          approved_capabilities: [],
          manifest: %{"capabilities" => ["get_config", "notify:v1"]}
        })

      assert {:ok, _target} =
               resolve(channel(), provider(), load_package: fn _id -> {:ok, unnarrowed} end)
    end

    test "a package that declares notify:v1 nowhere is denied" do
      plain =
        package(%{approved_capabilities: [], manifest: %{"capabilities" => ["get_config"]}})

      assert {:error, {"notify_capability_denied", _message}} =
               resolve(channel(), provider(), load_package: fn _id -> {:ok, plain} end)
    end
  end

  describe "the assignment" do
    test "an unassigned package is refused with the agent named" do
      assert {:error, {"plugin_assignment_missing", message}} =
               resolve(channel(), provider(),
                 load_assignment: fn _uid, _partition, _package -> {:error, :not_found} end
               )

      assert message =~ "k8s-agent"
    end
  end

  describe "platform_agent/0" do
    test "an unset agent id reads as unconfigured" do
      previous = Application.get_env(:serviceradar_core, PluginTarget)

      on_exit(fn ->
        if previous do
          Application.put_env(:serviceradar_core, PluginTarget, previous)
        else
          Application.delete_env(:serviceradar_core, PluginTarget)
        end
      end)

      Application.put_env(:serviceradar_core, PluginTarget,
        platform_agent_uid: "  ",
        platform_agent_partition_id: "default"
      )

      assert PluginTarget.platform_agent() == nil

      Application.put_env(:serviceradar_core, PluginTarget,
        platform_agent_uid: "k8s-agent",
        platform_agent_partition_id: nil
      )

      assert PluginTarget.platform_agent() == {"k8s-agent", nil}
    end
  end
end
