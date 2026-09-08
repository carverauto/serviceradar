defmodule ServiceRadar.Notifications.Validations.ScheduleWindows do
  @moduledoc """
  Validates the shape of `ServiceRadar.Notifications.NotificationSchedule.windows`.

  The column is `{:array, :map}`, so nothing below the array type inspects the
  entries. An unvalidated window is a silent trap rather than a loud failure: a
  malformed entry makes window evaluation fall through to "outside the window",
  which suppresses every dispatch on the referencing route with
  `suppression_reason: :schedule` and gives no indication that the schedule
  itself is broken.

  Each entry is a `{days, start_time, end_time}` triple and must carry:

    * `days` - a non-empty list of tokens drawn from
      `mon tue wed thu fri sat sun`.
    * `start_time` and `end_time` - wall-clock times as `"HH:MM"` or
      `"HH:MM:SS"`, with `end_time` strictly after `start_time`.

  At least one window is required, because an empty `:active_within` schedule
  suppresses every dispatch forever while reading as configured.

  A window that wraps past midnight is deliberately NOT expressible as a single
  entry: `end_time > start_time` is what keeps evaluation a plain comparison.
  Express "overnight" as `mode: :active_outside` of the daytime window, or as
  two entries on the adjacent days.
  """

  use Ash.Resource.Validation

  @days ~w(mon tue wed thu fri sat sun)
  @keys ~w(days start_time end_time)a

  @impl true
  def validate(changeset, _opts, _context) do
    changeset
    |> pending_windows()
    |> validate_windows()
  end

  # Shape checking is a decision about the incoming value, not an attribute
  # write, so it reports its result directly and the enclosing update stays
  # atomic instead of needing `require_atomic? false`.
  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  # Resolve the value this action is about to persist.
  #
  # In an atomic update the casted value lives in `changeset.atomics` rather
  # than in `changeset.attributes`, so reading only the attributes would see a
  # stale value. `windows` is never written from an atomic expression by the
  # actions on this resource, so a pending value is always a literal list.
  #
  # `Ash.Changeset.get_attribute/2` is deliberately NOT used: it falls through
  # to `get_data/2`, which RAISES when the changeset carries
  # `%OriginalDataNotAvailable{}` - exactly the case a bulk atomic update hits.
  # When the field is neither changing nor readable there is nothing to
  # re-check, because the stored value was validated by the action that wrote
  # it.
  defp pending_windows(changeset) do
    with :error <- Keyword.fetch(changeset.atomics, :windows),
         :error <- Ash.Changeset.fetch_change(changeset, :windows) do
      original_windows(changeset)
    else
      {:ok, value} -> value
    end
  end

  defp original_windows(changeset) do
    case changeset.data do
      %{windows: windows} -> windows
      _other -> nil
    end
  end

  defp validate_windows([]), do: error("a schedule must define at least one window")

  defp validate_windows(windows) when is_list(windows) do
    windows
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {window, index}, :ok ->
      case validate_window(window) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, error("window #{index}: #{reason}")}
      end
    end)
  end

  defp validate_windows(_other), do: :ok

  defp validate_window(window) when is_map(window) do
    with {:ok, days} <- fetch(window, :days),
         :ok <- validate_days(days),
         {:ok, raw_start} <- fetch(window, :start_time),
         {:ok, raw_end} <- fetch(window, :end_time),
         {:ok, start_time} <- parse_time(raw_start, "start_time"),
         {:ok, end_time} <- parse_time(raw_end, "end_time") do
      validate_order(start_time, end_time)
    end
  end

  defp validate_window(_other), do: {:error, "must be a map"}

  defp validate_days(days) when is_list(days) and days != [] do
    case Enum.reject(days, &valid_day?/1) do
      [] ->
        :ok

      invalid ->
        {:error, "days must be drawn from #{Enum.join(@days, ", ")}, got #{inspect(invalid)}"}
    end
  end

  defp validate_days([]), do: {:error, "days must name at least one day of the week"}
  defp validate_days(_other), do: {:error, "days must be a list of day-of-week tokens"}

  defp valid_day?(day) when is_binary(day), do: String.downcase(day) in @days
  defp valid_day?(day) when is_atom(day) and not is_nil(day), do: valid_day?(Atom.to_string(day))
  defp valid_day?(_other), do: false

  defp validate_order(start_time, end_time) do
    if Time.after?(end_time, start_time) do
      :ok
    else
      {:error,
       "end_time #{Time.to_string(end_time)} must be after start_time #{Time.to_string(start_time)}"}
    end
  end

  defp parse_time(%Time{} = value, _field), do: {:ok, value}

  defp parse_time(value, field) when is_binary(value) do
    value
    |> pad_seconds()
    |> Time.from_iso8601()
    |> case do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, "#{field} must be a HH:MM or HH:MM:SS wall-clock time"}
    end
  end

  defp parse_time(_value, field),
    do: {:error, "#{field} must be a HH:MM or HH:MM:SS wall-clock time"}

  defp pad_seconds(value) do
    if Regex.match?(~r/^\d{2}:\d{2}$/, value), do: value <> ":00", else: value
  end

  # Windows arrive as JSON maps with string keys from the API and with atom keys
  # from seeds and tests; accept both without ever calling String.to_atom/1 on
  # operator input.
  defp fetch(window, key) when key in @keys do
    case Map.fetch(window, Atom.to_string(key)) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(window, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, "missing #{key}"}
        end
    end
  end

  defp error(message), do: {:error, field: :windows, message: message}
end
