defmodule ServiceRadar.Identity.SAMLPendingRequestTest do
  @moduledoc """
  Server-side SP-initiated SAML logins: a RelayState can be taken once, only a
  hash of it is stored, and the cleanup worker drops expired rows.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.SAMLAssertionCleanupWorker
  alias ServiceRadar.Identity.SAMLPendingRequest
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:saml_pending_request_test)}
  end

  test "a RelayState is taken exactly once", %{actor: actor} do
    relay_state = relay_state()
    request_id = "_req-#{System.unique_integer([:positive])}"
    expires_at = DateTime.add(DateTime.utc_now(), 600, :second)
    params = %{return_to: "/devices"}

    assert {:ok, _pending} =
             SAMLPendingRequest.open(relay_state, request_id, expires_at, params, actor: actor)

    assert {:ok, %SAMLPendingRequest{request_id: ^request_id, return_to: "/devices"}} =
             SAMLPendingRequest.take(relay_state, actor: actor)

    assert {:ok, nil} = SAMLPendingRequest.take(relay_state, actor: actor)
    assert {:ok, nil} = SAMLPendingRequest.take(relay_state(), actor: actor)
  end

  test "stores a hash of the RelayState, not the RelayState", %{actor: actor} do
    relay_state = relay_state()
    request_id = "_req-#{System.unique_integer([:positive])}"
    expires_at = DateTime.add(DateTime.utc_now(), 600, :second)

    {:ok, _pending} = SAMLPendingRequest.open(relay_state, request_id, expires_at, actor: actor)

    [row] =
      SAMLPendingRequest
      |> Ash.Query.filter(request_id == ^request_id)
      |> Ash.read!(actor: actor)

    assert row.relay_state_hash =~ ~r/\A[0-9a-f]{64}\z/
    refute row.relay_state_hash == relay_state
  end

  test "cleanup deletes expired pending requests and keeps live ones", %{actor: actor} do
    now = DateTime.utc_now()
    expired_id = "_req-expired-#{System.unique_integer([:positive])}"
    live_id = "_req-live-#{System.unique_integer([:positive])}"

    {:ok, _} =
      SAMLPendingRequest.open(relay_state(), expired_id, DateTime.add(now, -3_600, :second),
        actor: actor
      )

    {:ok, _} =
      SAMLPendingRequest.open(relay_state(), live_id, DateTime.add(now, 600, :second),
        actor: actor
      )

    assert :ok = SAMLAssertionCleanupWorker.perform(%Oban.Job{args: %{}})

    remaining =
      SAMLPendingRequest
      |> Ash.Query.filter(request_id in ^[expired_id, live_id])
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.request_id)

    assert remaining == [live_id]
  end

  defp relay_state, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
