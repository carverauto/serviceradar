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
  reproduces the original crash. Profiles that declare a purpose are reconciled
  against an injected empty rule list, which keeps them database-free and makes each
  one report a `no_matching_rules` skip that the fold must carry into the result.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginAssignmentMaterializer, as: Materializer

  defp target_policy_profile(provider, consumers \\ []) do
    %{
      "provider" => provider,
      "provisioning" => %{"mode" => "target_policy", "consumers" => consumers}
    }
  end

  defp inventory_consumer do
    %{"purpose" => "device_inventory", "plugin_id" => "example-inventory"}
  end

  test "a single profile does not crash the outer reduce_while" do
    assert {:ok, summary} =
             Materializer.reconcile_all_for_agent("agent-test",
               integration_catalog: [target_policy_profile("provider-a")]
             )

    assert summary == %{
             rules: 0,
             resolved_inputs: 0,
             desired_assignments: 0,
             upserted: 0,
             unchanged: 0,
             disabled: 0,
             skips: %{}
           }
  end

  test "multiple profiles are folded into one summary" do
    profiles =
      for provider <- ["provider-a", "provider-b", "provider-c"] do
        target_policy_profile(provider, [inventory_consumer()])
      end

    assert {:ok, summary} =
             Materializer.reconcile_all_for_agent("agent-test",
               integration_catalog: profiles,
               rules: []
             )

    assert summary.skips == %{no_matching_rules: 3}
  end

  test "profiles that are not target_policy are filtered out before reduction" do
    # `credential_only` (AWX) and `producer_schedule` (OpenText) profiles coexist with
    # target_policy ones in a real catalog and must not reach this path. Each one
    # declares a purpose, so reconciling it would fail as an invalid target-policy
    # profile rather than pass unnoticed.
    profiles = [
      %{
        "provider" => "awx",
        "provisioning" => %{"mode" => "credential_only", "consumers" => [inventory_consumer()]}
      },
      %{
        "provider" => "opentext-nom",
        "provisioning" => %{
          "mode" => "producer_schedule",
          "schedule_id" => "opentext-nom.inventory.refresh",
          "consumers" => [inventory_consumer()]
        }
      },
      target_policy_profile("proxmox", [inventory_consumer()])
    ]

    assert {:ok, summary} =
             Materializer.reconcile_all_for_agent("agent-test",
               integration_catalog: profiles,
               rules: []
             )

    assert summary.skips == %{no_matching_rules: 1}
  end
end
