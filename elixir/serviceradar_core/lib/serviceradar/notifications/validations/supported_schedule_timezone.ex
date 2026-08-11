defmodule ServiceRadar.Notifications.Validations.SupportedScheduleTimezone do
  @moduledoc """
  Rejects schedule zones the notification runtime cannot evaluate.

  Accepting an arbitrary string here is dangerous because dispatch-time
  schedule errors intentionally fail open: a misspelled zone would therefore
  make a route page at every hour while its configuration claimed otherwise.
  Validation uses the same PostgreSQL IANA catalog as dispatch-time conversion,
  so save-time acceptance and runtime behaviour cannot drift.
  """

  use Ash.Resource.Validation

  alias ServiceRadar.Notifications.TimeZone

  @impl true
  def validate(changeset, opts, _context) do
    changeset
    |> pending_timezone()
    |> validate_timezone(opts)
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp pending_timezone(changeset) do
    with :error <- Keyword.fetch(changeset.atomics, :timezone),
         :error <- Ash.Changeset.fetch_change(changeset, :timezone) do
      case changeset.data do
        %{timezone: timezone} -> timezone
        _other -> nil
      end
    else
      {:ok, value} -> value
    end
  end

  defp validate_timezone(timezone, opts) when is_binary(timezone) do
    if TimeZone.supported?(timezone, opts) do
      :ok
    else
      error(timezone)
    end
  end

  defp validate_timezone(timezone, _opts), do: error(timezone)

  defp error(timezone) do
    {:error,
     field: :timezone,
     message: "%{timezone} is not an installed IANA time zone",
     vars: [timezone: inspect(timezone)]}
  end
end
