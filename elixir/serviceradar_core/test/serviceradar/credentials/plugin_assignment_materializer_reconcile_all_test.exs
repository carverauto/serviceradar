defmodule ServiceRadar.Credentials.PluginAssignmentMaterializerReconcileAllTest do
  @moduledoc """
  Regression coverage for `reconcile_all_for_agent/2`'s nested `reduce_while`.

  The outer `reduce_while` used to return the inner one's `{:ok, acc}` result
  directly. That is not a valid accumulator -- the Enumerable protocol only accepts
  `:cont` / `:halt` / `:suspend` -- so the next iteration raised a
  `FunctionClauseError` in `Enumerable.List.reduce/3`.

  An empty integration catalog hid this completely: with no profiles the callback
  never ran, so the reconciler quietly reported zero matches instead of crashing. It
  only surfaced in production the moment a plugin package was approved, which is
  exactly the case these tests pin down.

  A profile in `target_policy` mode with no consumers has no purposes, so the inner
  reduce returns immediately without touching the database -- the smallest input that
  reproduces the original crash.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginAssignmentMaterializer, as: Materializer

  defp target_policy_profile(provider) do
    %{
      "provider" => provider,
      "provisioning" => %{"mode" => "target_policy", "consumers" => []}
    }
  end

  test "a single profile does not crash the outer reduce_while" do
    assert {:ok, summary} =
             Materializer.reconcile_all_for_agent("agent-test",
               integration_catalog: [target_policy_profile("provider-a")]
             )

    assert is_map(summary)
  end

  test "multiple profiles are folded into one summary" do
    profiles = [
      target_policy_profile("provider-a"),
      target_policy_profile("provider-b"),
      target_policy_profile("provider-c")
    ]

    assert {:ok, summary} =
             Materializer.reconcile_all_for_agent("agent-test", integration_catalog: profiles)

    assert is_map(summary)
  end

  test "an empty catalog still succeeds - the case that masked the bug" do
    assert {:ok, summary} =
             Materializer.reconcile_all_for_agent("agent-test", integration_catalog: [])

    assert is_map(summary)
  end

  test "profiles that are not target_policy are filtered out before reduction" do
    # `credential_only` (AWX) and `producer_schedule` (OpenText) profiles coexist with
    # target_policy ones in a real catalog and must not reach this path.
    profiles = [
      %{"provider" => "awx", "provisioning" => %{"mode" => "credential_only"}},
      %{
        "provider" => "opentext-nom",
        "provisioning" => %{
          "mode" => "producer_schedule",
          "schedule_id" => "opentext-nom.inventory.refresh"
        }
      },
      target_policy_profile("proxmox")
    ]

    assert {:ok, summary} =
             Materializer.reconcile_all_for_agent("agent-test", integration_catalog: profiles)

    assert is_map(summary)
  end

  test "a malformed catalog is reported rather than raised" do
    assert {:error, :invalid_plugin_integration_catalog} =
             Materializer.reconcile_all_for_agent("agent-test", integration_catalog: "nonsense")
  end
end
