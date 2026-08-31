defmodule ServiceRadar.Identity.Changes.NormalizeTimezonePreference do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.TimeZone

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :timezone) do
      {:ok, timezone} ->
        normalize_change(changeset, timezone)

      :error ->
        changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case pending_timezone(changeset) do
      {:ok, timezone} ->
        case TimeZone.normalize_preference(timezone) do
          {:ok, normalized} -> {:atomic, %{timezone: normalized}}
          {:error, :invalid_timezone} -> {:error, timezone_error()}
        end

      :error ->
        :ok
    end
  end

  defp pending_timezone(changeset) do
    with :error <- Keyword.fetch(changeset.atomics, :timezone) do
      Ash.Changeset.fetch_change(changeset, :timezone)
    end
  end

  defp normalize_change(changeset, timezone) do
    case TimeZone.normalize_preference(timezone) do
      {:ok, normalized} ->
        Ash.Changeset.force_change_attribute(changeset, :timezone, normalized)

      {:error, :invalid_timezone} ->
        Ash.Changeset.add_error(changeset, timezone_error())
    end
  end

  defp timezone_error do
    [field: :timezone, message: "is not a valid timezone"]
  end
end
