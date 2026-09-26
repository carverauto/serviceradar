defmodule ServiceRadar.Identity.SAMLConsumedAssertionTest do
  @moduledoc """
  The SAML assertion replay ledger: a second use of an assertion must conflict,
  and the cleanup worker must drop only rows whose assertions can no longer be
  accepted.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.SAMLAssertionCleanupWorker
  alias ServiceRadar.Identity.SAMLConsumedAssertion
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    issuer = "https://idp-#{System.unique_integer([:positive])}.example.com/metadata"
    {:ok, actor: SystemActor.system(:saml_consumed_assertion_test), issuer: issuer}
  end

  test "a second use of the same assertion conflicts on the unique identity", %{
    actor: actor,
    issuer: issuer
  } do
    not_on_or_after = DateTime.add(DateTime.utc_now(), 120, :second)

    assert {:ok, _row} =
             SAMLConsumedAssertion.record(issuer, "_assertion-1", not_on_or_after, actor: actor)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             SAMLConsumedAssertion.record(issuer, "_assertion-1", not_on_or_after, actor: actor)

    assert Enum.any?(errors, fn
             %Ash.Error.Changes.InvalidAttribute{private_vars: vars} ->
               Keyword.get(vars || [], :constraint_type) == :unique

             _other ->
               false
           end)

    # The same assertion ID from a different IdP is a different assertion.
    assert {:ok, _row} =
             SAMLConsumedAssertion.record(
               issuer <> "/other",
               "_assertion-1",
               not_on_or_after,
               actor: actor
             )
  end

  test "cleanup deletes rows past NotOnOrAfter plus grace and keeps the rest", %{
    actor: actor,
    issuer: issuer
  } do
    now = DateTime.utc_now()

    for {assertion_id, offset_seconds} <- [
          {"_long-expired", -3_600},
          {"_within-grace", -60},
          {"_still-valid", 120}
        ] do
      {:ok, _row} =
        SAMLConsumedAssertion.record(
          issuer,
          assertion_id,
          DateTime.add(now, offset_seconds, :second),
          actor: actor
        )
    end

    assert :ok = SAMLAssertionCleanupWorker.perform(%Oban.Job{args: %{}})

    remaining =
      SAMLConsumedAssertion
      |> Ash.Query.filter(issuer == ^issuer)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.assertion_id)
      |> Enum.sort()

    assert remaining == ["_still-valid", "_within-grace"]
  end
end
