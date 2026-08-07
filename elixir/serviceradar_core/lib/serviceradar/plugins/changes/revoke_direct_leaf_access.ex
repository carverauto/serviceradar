defmodule ServiceRadar.Plugins.Changes.RevokeDirectLeafAccess do
  @moduledoc """
  Revokes an assignment's current direct-leaf identity and removes the
  encrypted certificate material from the assignment.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Edge.DirectLeafIdentityIssuer

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    previous = changeset.data
    reason = Ash.Changeset.get_argument(changeset, :reason) || "direct leaf access revoked"

    changeset =
      changeset
      |> Ash.Changeset.change_attribute(:direct_access_status, :revoked)
      |> Ash.Changeset.change_attribute(:direct_access_revoked_at, DateTime.utc_now())
      |> Ash.Changeset.change_attribute(:direct_access_expires_at, nil)
      |> Ash.Changeset.change_attribute(:direct_access_error, reason)
      |> Ash.Changeset.force_change_attribute(:encrypted_direct_certificate_pem, nil)
      |> Ash.Changeset.force_change_attribute(:encrypted_direct_private_key_pem, nil)
      |> Ash.Changeset.force_change_attribute(:encrypted_direct_ca_chain_pem, nil)
      |> Ash.Changeset.change_attribute(:direct_certificate_fingerprint, nil)
      |> Ash.Changeset.change_attribute(:direct_identity_component_id, nil)
      |> Ash.Changeset.change_attribute(:direct_identity_partition_id, nil)

    if previous_identity?(previous) do
      AfterAction.after_action(changeset, fn _record ->
        case DirectLeafIdentityIssuer.revoke(previous, reason: reason) do
          :ok ->
            :ok

          {:error, revoke_error} ->
            Logger.warning(
              "Direct-leaf identity revocation could not reach the gateway: " <>
                "assignment=#{Map.get(previous, :id)} reason=#{inspect(revoke_error)}"
            )
        end
      end)
    else
      changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp previous_identity?(previous) when is_map(previous) do
    is_binary(Map.get(previous, :direct_certificate_fingerprint)) or
      is_binary(Map.get(previous, :direct_identity_component_id))
  end

  defp previous_identity?(_previous), do: false
end
