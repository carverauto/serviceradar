defmodule ServiceRadar.Credentials.Validations.GrantPrunableForSecretDeletion do
  @moduledoc false

  use Ash.Resource.Validation

  @live_statuses [:issued, :active]

  @impl true
  def validate(changeset, _opts, _context) do
    grant = changeset.data
    cutoff = Ash.Changeset.get_argument(changeset, :cutoff)

    if prunable?(grant.status, grant.expires_at, cutoff) do
      :ok
    else
      {:error, field: :id, message: "credential_grant_not_prunable"}
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "credential grant pruning requires a locked record"}

  defp prunable?(status, _expires_at, _cutoff) when status not in @live_statuses, do: true

  defp prunable?(status, %DateTime{} = expires_at, %DateTime{} = cutoff)
       when status in @live_statuses,
       do: DateTime.compare(expires_at, cutoff) != :gt

  defp prunable?(_status, _expires_at, _cutoff), do: false
end
