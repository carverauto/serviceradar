defmodule ServiceRadar.Automation.Ansible.Changes.SyncLegacyControllerCredential do
  @moduledoc """
  Keeps the deprecated controller credential column aligned with the sync
  credential during the one-release rolling-upgrade window.

  A new caller that writes `sync_credential_secret_id` also writes the legacy
  column so an older application pod can still read the row. An old caller
  that writes only `credential_secret_id` populates only the sync purpose. It
  never fills execution or callback credentials, so compatibility cannot turn
  a read principal into a mutating one.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    cond do
      Ash.Changeset.changing_attribute?(changeset, :sync_credential_secret_id) ->
        mirror(
          changeset,
          :credential_secret_id,
          Ash.Changeset.get_attribute(changeset, :sync_credential_secret_id)
        )

      Ash.Changeset.changing_attribute?(changeset, :credential_secret_id) ->
        mirror(
          changeset,
          :sync_credential_secret_id,
          Ash.Changeset.get_attribute(changeset, :credential_secret_id)
        )

      true ->
        changeset
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp mirror(changeset, _attribute, nil), do: changeset

  defp mirror(changeset, attribute, value) do
    Ash.Changeset.force_change_attribute(changeset, attribute, value)
  end
end
