defmodule ServiceRadar.Plugins.NetboxCredentialProfileTest do
  @moduledoc """
  Contract tests for the shipped NetBox manifest.

  Both assertions guard a silent failure rather than a crash, which is why they
  are pinned to the real `plugin.yaml` instead of a fixture.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialIntegration
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  setup do
    %{profile: CredentialIntegrationFixtures.profile!("netbox", "netbox")}
  end

  test "the inventory_sync consumer declares single target cardinality", %{profile: profile} do
    # A NetBox instance is the rule's controller host, so every chunk of the
    # resolved target set would sync the same instance in full and emit another
    # complete snapshot under the same source_instance.
    assert {:ok, consumer} =
             CredentialIntegration.consumer_for_rule(
               profile,
               %{auth_method: "api_token", purpose: "inventory_sync"},
               "inventory_sync"
             )

    assert CredentialIntegration.single_target_cardinality?(consumer)
  end

  test "the profile offers an agent scope and nothing wider", %{profile: profile} do
    # A gateway- or partition-scoped rule is in scope for every agent under it,
    # and the materializer reconciles each agent separately, so a single
    # NetBox instance would be walked once per agent -- each walk emitting
    # another complete snapshot under the same source_instance. The rule form
    # renders its scope options from this list.
    assert profile["scope_types"] == ["agent"]
  end

  test "the profile ships no default target query", %{profile: profile} do
    # The target set only gates delivery, and a default would have to both
    # resolve and stay small on every deployment. `metadata.netbox_candidate`
    # has no writer, so a marker default resolved nothing, and `limit:` cannot
    # bound the set because target queries are read whole and refuse it. The
    # operator names the NetBox host's own device record instead.
    refute Map.has_key?(profile["rule_defaults"] || %{}, "target_query")
  end
end
