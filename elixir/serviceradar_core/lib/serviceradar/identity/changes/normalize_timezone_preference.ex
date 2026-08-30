defmodule ServiceRadar.Identity.Changes.NormalizeTimezonePreference do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.TimeZone

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :timezone) do
      {:ok, timezone} ->
        case TimeZone.normalize_preference(timezone) do
          {:ok, normalized} ->
            Ash.Changeset.force_change_attribute(changeset, :timezone, normalized)

          {:error, :invalid_timezone} ->
            Ash.Changeset.add_error(changeset,
              field: :timezone,
              message: "is not a valid timezone"
            )
        end

      :error ->
        changeset
    end
  end
end
