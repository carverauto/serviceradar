defmodule ServiceRadar.Notifications.SupportedScheduleTimezoneTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.NotificationSchedule
  alias ServiceRadar.Notifications.Validations.SupportedScheduleTimezone

  test "accepts a zone present in PostgreSQL's IANA catalog" do
    changeset = changeset("America/New_York")
    query = fn _sql, ["America/New_York"] -> {:ok, %{rows: [[true]]}} end

    assert SupportedScheduleTimezone.validate(changeset, [query: query], %{}) == :ok
  end

  test "rejects a zone the runtime cannot resolve" do
    changeset = changeset("Mars/Olympus_Mons")
    query = fn _sql, ["Mars/Olympus_Mons"] -> {:ok, %{rows: [[false]]}} end

    assert {:error, error} =
             SupportedScheduleTimezone.validate(changeset, [query: query], %{})

    assert error[:field] == :timezone
    assert error[:message] =~ "not an installed IANA time zone"
  end

  defp changeset(timezone) do
    NotificationSchedule
    |> Ash.Changeset.new()
    |> Ash.Changeset.change_attribute(:timezone, timezone)
  end
end
