defmodule ServiceRadar.Camera.Checks.QualifyingLocalStorage do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "qualification principal scoped to this storage lifetime"

  @impl true
  def match?(
        %{role: :system, id: id, nvr_storage_purpose: :qualify, nvr_storage_id: storage_id},
        %{changeset: %Ash.Changeset{} = changeset},
        _opts
      )
      when is_binary(id) and byte_size(id) in 1..128 and is_binary(storage_id) do
    report = Ash.Changeset.get_attribute(changeset, :report) || %{}
    Regex.match?(~r/\A[!-~]+\z/, id) and report["storage_id"] == storage_id
  end

  def match?(_actor, _context, _opts), do: false
end
