defmodule ServiceRadar.Inventory.Identity.MergeTransactionRollbackTest do
  @moduledoc """
  Pins the transaction semantics MergeEngine depends on.

  `Ash.transaction/3` (deprecated) does NOT inspect the return value of the
  function it wraps: a `with` that RETURNS `{:error, _}` yields
  `{:ok, {:error, _}}` and the transaction COMMITS. `Ash.transact/3` is
  identical except that it passes `rollback_on_error?: true`, which is the
  entire reason `transaction/3` is deprecated
  (ash/lib/ash.ex:4243-4257 vs :4140-4153, and the flag's `false` default at
  ash/lib/ash/data_layer/data_layer.ex:585).

  This mattered in MergeEngine: a merge that failed partway committed its
  partial work, leaving identifiers already reassigned to the survivor, the
  source device still live and untombstoned, and no `merge_audit` row.
  `Resolver.follow_canonical_device_id/2` keys on `deleted_at`, so nothing
  downstream could detect that state.

  These tests exist because the fix is a one-word change that an Ash upgrade
  or a careless edit could silently revert. The first test asserts the
  behaviour we now rely on; the second documents the behaviour we moved away
  from, so a change in Ash's default surfaces here rather than in production.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:merge_transaction_rollback_test)}
  end

  test "Ash.transact rolls back work when the function returns an error", %{actor: actor} do
    uid = "sr:" <> Ecto.UUID.generate()

    result =
      Ash.transact([Device], fn ->
        {:ok, _device} = create_device(actor, uid, "10.90.0.1")
        # A plain returned error, not a raise and not Ash.DataLayer.rollback/2.
        # This is the exact shape MergeEngine's `with` produces on failure.
        {:error, :simulated_failure}
      end)

    assert {:error, _} = result

    refute device_exists?(actor, uid),
           "Ash.transact must roll back a device created before a returned error"
  end

  test "the deprecated Ash.transaction commits the same work", %{actor: actor} do
    uid = "sr:" <> Ecto.UUID.generate()

    result =
      Ash.transaction([Device], fn ->
        {:ok, _device} = create_device(actor, uid, "10.90.0.2")
        {:error, :simulated_failure}
      end)

    # The committed-but-failed shape. MergeEngine handled this as "merge_failed"
    # while the partial write had already landed.
    assert {:ok, {:error, :simulated_failure}} = result

    assert device_exists?(actor, uid),
           "if this fails, Ash changed its rollback_on_error? default - re-check " <>
             "whether MergeEngine still needs Ash.transact and update this test's premise"
  end

  test "MergeEngine uses Ash.transact for both merge and unmerge" do
    source =
      File.read!("lib/serviceradar/inventory/identity/merge_engine.ex")

    refute source =~ "Ash.transaction(",
           "MergeEngine must not use the deprecated Ash.transaction/3: it commits " <>
             "a partial merge when the transaction body returns an error"

    assert length(String.split(source, "Ash.transact(")) - 1 == 2,
           "expected exactly two Ash.transact/3 call sites (do_merge_devices, do_unmerge)"
  end

  defp create_device(actor, uid, ip) do
    Device
    |> Ash.Changeset.for_create(:create, %{uid: uid, hostname: "rollback-test", ip: ip})
    |> Ash.create(actor: actor)
  end

  defp device_exists?(actor, uid), do: rows(actor, uid) != []

  # Device's read action is paginated, so Ash.read! can hand back an
  # Ash.Page.Keyset rather than a list.
  defp rows(actor, uid) do
    Device
    |> Ash.Query.filter(uid == ^uid)
    |> Ash.read!(actor: actor, authorize?: false)
    |> case do
      %Ash.Page.Keyset{results: results} -> results
      %Ash.Page.Offset{results: results} -> results
      results when is_list(results) -> results
    end
  end
end
