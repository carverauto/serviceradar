defmodule ServiceRadar.Plugins.Changes.IssueDirectLeafAccess do
  @moduledoc """
  Persists a short-lived, encrypted direct-leaf identity returned by the
  authenticated agent gateway.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Edge.DirectLeafIdentityIssuer

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    assignment =
      Map.put(changeset.data, :params, Ash.Changeset.get_attribute(changeset, :params) || %{})

    opts = [
      validity_days: Ash.Changeset.get_argument(changeset, :validity_days) || 30,
      actor: Map.get(context, :actor)
    ]

    case DirectLeafIdentityIssuer.issue(assignment, opts) do
      {:ok, %{authorization_status: :ready} = identity} ->
        ready(changeset, identity)

      {:ok, identity} ->
        pending_with_material(changeset, identity, :leaf_authorization_pending)

      {:error, reason} ->
        changeset
        |> pending(reason)
        |> clear_identity_material()
        |> revoke_previous_identity(assignment, "direct leaf identity reissue failed")
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp ready(changeset, identity) do
    changeset
    |> Ash.Changeset.change_attribute(:direct_access_status, :ready)
    |> Ash.Changeset.change_attribute(:direct_access_expires_at, identity.expires_at)
    |> Ash.Changeset.change_attribute(:direct_access_revoked_at, nil)
    |> Ash.Changeset.change_attribute(:direct_access_error, nil)
    |> Ash.Changeset.change_attribute(
      :direct_certificate_fingerprint,
      identity.certificate_fingerprint
    )
    |> Ash.Changeset.change_attribute(:direct_identity_component_id, identity.component_id)
    |> Ash.Changeset.change_attribute(:direct_identity_partition_id, identity.partition_id)
    |> AshCloak.encrypt_and_set(:direct_certificate_pem, identity.certificate_pem)
    |> AshCloak.encrypt_and_set(:direct_private_key_pem, identity.private_key_pem)
    |> AshCloak.encrypt_and_set(:direct_ca_chain_pem, identity.ca_chain_pem)
  end

  defp pending(changeset, reason) do
    changeset
    |> Ash.Changeset.change_attribute(:direct_access_status, :pending)
    |> Ash.Changeset.change_attribute(:direct_access_expires_at, nil)
    |> Ash.Changeset.change_attribute(:direct_access_error, reason_text(reason))
  end

  defp pending_with_material(changeset, identity, reason) do
    changeset
    |> Ash.Changeset.change_attribute(:direct_access_status, :pending)
    |> Ash.Changeset.change_attribute(:direct_access_expires_at, identity.expires_at)
    |> Ash.Changeset.change_attribute(:direct_access_revoked_at, nil)
    |> Ash.Changeset.change_attribute(:direct_access_error, reason_text(reason))
    |> Ash.Changeset.change_attribute(
      :direct_certificate_fingerprint,
      identity.certificate_fingerprint
    )
    |> Ash.Changeset.change_attribute(:direct_identity_component_id, identity.component_id)
    |> Ash.Changeset.change_attribute(:direct_identity_partition_id, identity.partition_id)
    |> AshCloak.encrypt_and_set(:direct_certificate_pem, identity.certificate_pem)
    |> AshCloak.encrypt_and_set(:direct_private_key_pem, identity.private_key_pem)
    |> AshCloak.encrypt_and_set(:direct_ca_chain_pem, identity.ca_chain_pem)
  end

  defp clear_identity_material(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:encrypted_direct_certificate_pem, nil)
    |> Ash.Changeset.force_change_attribute(:encrypted_direct_private_key_pem, nil)
    |> Ash.Changeset.force_change_attribute(:encrypted_direct_ca_chain_pem, nil)
    |> Ash.Changeset.change_attribute(:direct_certificate_fingerprint, nil)
    |> Ash.Changeset.change_attribute(:direct_identity_component_id, nil)
    |> Ash.Changeset.change_attribute(:direct_identity_partition_id, nil)
  end

  defp revoke_previous_identity(changeset, previous, reason) do
    if previous_identity?(previous) do
      AfterAction.after_action(changeset, fn _record ->
        case DirectLeafIdentityIssuer.revoke(previous, reason: reason) do
          :ok ->
            :ok

          {:error, revoke_error} ->
            Logger.warning(
              "Direct-leaf predecessor revocation could not reach the gateway: " <>
                "assignment=#{Map.get(previous, :id)} reason=#{inspect(revoke_error)}"
            )
        end
      end)
    else
      changeset
    end
  end

  defp previous_identity?(previous) when is_map(previous) do
    is_binary(Map.get(previous, :direct_certificate_fingerprint)) or
      is_binary(Map.get(previous, :direct_identity_component_id))
  end

  defp previous_identity?(_previous), do: false

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text({tag, reason}) when is_atom(tag), do: "#{tag}: #{reason_text(reason)}"
  defp reason_text(reason) when is_binary(reason), do: String.slice(reason, 0, 256)
  defp reason_text(_reason), do: "direct_leaf_identity_issue_failed"
end
