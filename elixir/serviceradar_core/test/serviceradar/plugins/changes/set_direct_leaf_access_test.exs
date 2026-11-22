defmodule ServiceRadar.Plugins.Changes.SetDirectLeafAccessTest do
  @moduledoc """
  An atomic update of an assignment keeps the direct-access attribute changes
  and drops the hook `change/3` registered. `atomic/3` therefore has to arrange
  the revocation of an identity the update replaces or clears; otherwise that
  identity stays valid on the gateway.

  No gateway runs here, so an attempted revocation is visible as the warning
  that it could not reach one.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.Changes.SetDirectLeafAccess

  @unreachable "Direct-leaf identity revocation could not reach the gateway"
  @fingerprint "aa:bb:cc:dd:ee:ff:00:11"
  @component "direct-leaf-component-01"

  defp atomic_changeset(previous) do
    previous
    |> Ash.Changeset.new()
    |> Map.put(:action_type, :update)
    |> SetDirectLeafAccess.atomic([], %{})
  end

  defp identified do
    %AddonAssignment{
      id: Ash.UUID.generate(),
      direct_certificate_fingerprint: @fingerprint,
      direct_identity_component_id: @component,
      direct_access_status: :ready
    }
  end

  defp run_hook(changeset, record) do
    [hook] = changeset.after_action
    hook.(changeset, record)
  end

  test "an identity the update cleared is revoked" do
    assert {:ok, changeset} = atomic_changeset(identified())

    saved = %{
      identified()
      | direct_certificate_fingerprint: nil,
        direct_identity_component_id: nil,
        direct_access_status: :not_requested
    }

    log = capture_log(fn -> assert {:ok, ^saved} = run_hook(changeset, saved) end)

    assert log =~ @unreachable
  end

  test "an identity the update left in place is not revoked" do
    previous = identified()
    assert {:ok, changeset} = atomic_changeset(previous)

    log = capture_log(fn -> assert {:ok, ^previous} = run_hook(changeset, previous) end)

    refute log =~ @unreachable
  end

  test "an assignment that never had an identity registers nothing" do
    assert {:ok, %Ash.Changeset{after_action: []}} =
             atomic_changeset(%AddonAssignment{id: Ash.UUID.generate()})
  end
end
