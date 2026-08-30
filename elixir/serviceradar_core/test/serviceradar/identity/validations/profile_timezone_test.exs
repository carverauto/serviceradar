defmodule ServiceRadar.Identity.Validations.ProfileTimezoneTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.Changes.NormalizeTimezonePreference
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Validations.ProfileTimezone

  test "normalizes the pending timezone without changing the stored timezone" do
    changeset = changeset(" GMT ")

    normalized = NormalizeTimezonePreference.change(changeset, [], %{})

    assert Ash.Changeset.get_attribute(normalized, :timezone) == "Etc/UTC"
    assert normalized.data.timezone == "America/New_York"
  end

  test "returns a timezone field error for an invalid profile timezone" do
    assert ProfileTimezone.validate(changeset("Etc/GMT+5"), [], %{}) ==
             {:error, field: :timezone, message: "is not a supported timezone"}
  end

  test "does not change stored timezone when the catalog is unavailable" do
    catalog_down = fn _sql, _params -> {:error, :catalog_unavailable} end

    changeset =
      "America/Chicago"
      |> changeset()
      |> put_time_zone_query(catalog_down)

    assert ProfileTimezone.validate(changeset, [], %{}) ==
             {:error, field: :timezone, message: "timezone catalog is unavailable"}

    assert changeset.data.timezone == "America/New_York"
  end

  test "reports the PostgreSQL catalog read as non-atomic" do
    assert ProfileTimezone.atomic(changeset("America/Chicago"), [], %{}) ==
             {:not_atomic, "profile timezone validation requires a PostgreSQL catalog read"}
  end

  defp changeset(timezone) do
    User
    |> Ash.Changeset.new()
    |> Map.put(:data, %{timezone: "America/New_York"})
    |> Map.put(:attributes, %{timezone: timezone})
  end

  defp put_time_zone_query(changeset, query) do
    private = changeset.context |> Map.get(:private, %{}) |> Map.put(:time_zone_query, query)
    %{changeset | context: Map.put(changeset.context, :private, private)}
  end
end
