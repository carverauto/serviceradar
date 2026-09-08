defmodule ServiceRadar.CompositeChecks.RollupTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.CompositeChecks.Rollup

  defp actor, do: SystemActor.system(:composite_check_test)

  defp check! do
    CompositeCheck
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Rollup #{System.unique_integer([:positive])}", scope_query: "in:devices"},
      actor: actor()
    )
    |> Ash.create!()
  end

  defp verdict!(check, device_uid, verdict, status) do
    now = DateTime.utc_now()

    DeviceCompositeCheckResult
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        device_uid: device_uid,
        check_id: check.id,
        verdict: verdict,
        status: status,
        inputs: %{},
        evaluated_at: now,
        changed_at: now
      },
      actor: actor(),
      upsert?: true,
      upsert_identity: :unique_device_check
    )
    |> Ash.create!()
  end

  test "counts verdicts per check" do
    check = check!()
    verdict!(check, "r-a", "isolated_verified", :healthy)
    verdict!(check, "r-b", "isolated_verified", :healthy)
    verdict!(check, "r-c", "not_isolated", :down)

    counts = [check.id] |> Rollup.for_checks() |> Map.fetch!(check.id)

    assert Enum.find(counts, &(&1.verdict == "isolated_verified")).count == 2
    assert Enum.find(counts, &(&1.verdict == "not_isolated")).count == 1
  end

  test "orders most common first" do
    check = check!()
    verdict!(check, "o-a", "rare", :degraded)
    for uid <- ["o-b", "o-c", "o-d"], do: verdict!(check, uid, "common", :healthy)

    %{} = rollup = Rollup.for_checks([check.id])
    assert [%{verdict: "common", count: 3} | _] = rollup[check.id]
  end

  test "keeps checks separate" do
    a = check!()
    b = check!()
    verdict!(a, "s-1", "alpha", :healthy)
    verdict!(b, "s-1", "beta", :down)

    rollup = Rollup.for_checks([a.id, b.id])

    assert [%{verdict: "alpha"}] = rollup[a.id]
    assert [%{verdict: "beta"}] = rollup[b.id]
  end

  test "a check with no results is absent, not empty" do
    check = check!()

    # Absent and empty mean different things to a caller: "not yet evaluated"
    # versus "evaluated, found nothing".
    refute Map.has_key?(Rollup.for_checks([check.id]), check.id)
  end

  test "an empty id list does no work" do
    assert Rollup.for_checks([]) == %{}
  end

  test "total sums the counts" do
    check = check!()
    verdict!(check, "t-a", "x", :healthy)
    verdict!(check, "t-b", "y", :down)

    assert [check.id] |> Rollup.for_checks() |> Map.get(check.id) |> Rollup.total() == 2
    assert Rollup.total(nil) == 0
  end
end
