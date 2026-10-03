defmodule ServiceRadarWebNGWeb.DeviceLive.SourceRetiredData do
  @moduledoc """
  The `source_retired` mark on the device detail view (change `add-source-id-succession`,
  design D5): when the record was marked, and when the grace pass soft-deletes it.

  Loaded on the connected path only, because it reads the device cleanup settings and the
  review hold. The settings are read with the viewer's scope; a viewer who may not read them,
  like a deployment with no settings row, sees the mark without a date.
  """

  alias ServiceRadar.Inventory.DeviceCleanupSettings
  alias ServiceRadar.Inventory.SourceRetiredExpiry

  @typedoc """
  `schedule` is `:scheduled` with a `deletes_after` time; `:held` while an open
  de-duplication task names the device; `:paused` while source retirement is disabled, when
  no grace pass runs; `:unknown` when the settings or the hold could not be read.
  """
  @type t :: %{
          marked_at: DateTime.t(),
          deletes_after: DateTime.t() | nil,
          schedule: :scheduled | :held | :paused | :unknown
        }

  @doc "Render-time predicate: whether the device row carries the mark."
  @spec marked?(map() | nil) :: boolean()
  def marked?(device_row) when is_map(device_row), do: not is_nil(marked_at(device_row))
  def marked?(_device_row), do: false

  @spec load(map() | nil, term()) :: t() | nil
  def load(device_row, scope) do
    with %{} <- device_row,
         uid when is_binary(uid) <- Map.get(device_row, "uid"),
         %DateTime{} = marked_at <- marked_at(device_row) do
      schedule(
        marked_at,
        SourceRetiredExpiry.held_for_review(uid),
        DeviceCleanupSettings.get_settings(scope: scope)
      )
    else
      _ -> nil
    end
  end

  @doc false
  @spec schedule(DateTime.t(), {:ok, boolean()} | {:error, term()}, {:ok, map()} | term()) :: t()
  def schedule(%DateTime{} = marked_at, held, settings) do
    case {held, settings} do
      {{:ok, true}, _settings} ->
        entry(marked_at, nil, :held)

      {{:ok, false}, {:ok, %{source_retirement_enabled: false}}} ->
        entry(marked_at, nil, :paused)

      {{:ok, false}, {:ok, %{source_retired_grace_days: days}}}
      when is_integer(days) and days > 0 ->
        entry(marked_at, SourceRetiredExpiry.deletes_after(marked_at, days), :scheduled)

      _unreadable ->
        entry(marked_at, nil, :unknown)
    end
  end

  defp entry(marked_at, deletes_after, schedule),
    do: %{marked_at: marked_at, deletes_after: deletes_after, schedule: schedule}

  # A soft delete clears the mark, so a tombstone row carries none.
  defp marked_at(device_row) do
    with value when is_binary(value) <- Map.get(device_row, "source_retired_at"),
         {:ok, marked_at, _offset} <- DateTime.from_iso8601(value) do
      marked_at
    else
      _ -> nil
    end
  end
end
