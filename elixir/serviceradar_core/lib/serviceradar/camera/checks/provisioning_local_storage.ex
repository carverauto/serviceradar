defmodule ServiceRadar.Camera.Checks.ProvisioningLocalStorage do
  @moduledoc """
  Requires a trusted provisioning actor scoped to the requested storage lifetime.

  Actor fields come from authenticated deployment configuration, never from the
  binding document or recorder-supplied claims. A generic system actor has no
  provisioning authority.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "provisioner is authorized for this storage lifetime"

  @impl true
  def match?(
        %{role: :system, id: id, nvr_storage_purpose: :provision, nvr_storage_id: storage_id},
        %{changeset: %Ash.Changeset{} = changeset},
        _opts
      )
      when is_binary(id) and byte_size(id) in 1..128 and is_binary(storage_id) do
    Regex.match?(~r/\A[!-~]+\z/, id) and
      Ash.Changeset.get_attribute(changeset, :storage_id) == storage_id
  end

  def match?(_actor, _context, _opts), do: false
end
