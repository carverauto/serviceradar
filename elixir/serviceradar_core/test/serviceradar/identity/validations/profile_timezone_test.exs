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

  test "normalizes the pending timezone in the atomic update path" do
    changeset =
      "America/New_York"
      |> changeset()
      |> Map.put(:attributes, %{})
      |> Map.put(:atomics, timezone: " GMT ")

    assert {:atomic, %{timezone: "Etc/UTC"}} =
             NormalizeTimezonePreference.atomic(changeset, [], %{})
  end

  test "normalizes the effective value in a fully atomic timezone action" do
    catalog_query = fn _sql, _params -> {:ok, %{rows: [["Etc/UTC"]]}} end

    for assume_casted? <- [false, true] do
      changeset =
        Ash.Changeset.fully_atomic_changeset(
          User,
          :update_timezone_preference,
          %{timezone: " Z "},
          context: %{private: %{time_zone_query: catalog_query}},
          assume_casted?: assume_casted?
        )

      assert %Ash.Changeset{} = changeset
      assert Ash.Changeset.get_attribute(changeset, :timezone) == "Etc/UTC"
      refute Keyword.get(changeset.atomics, :timezone) == " Z "
    end
  end

  test "returns an Ash change error for an invalid atomic timezone" do
    changeset =
      "America/New_York"
      |> changeset()
      |> Map.put(:attributes, %{})
      |> Map.put(:atomics, timezone: "Etc/GMT+5")

    assert {:error, [field: :timezone, message: "is not a valid timezone"]} =
             NormalizeTimezonePreference.atomic(changeset, [], %{})
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

  test "validates the pending timezone during an atomic update" do
    catalog_query = fn _sql, _params -> {:ok, %{rows: [["America/Chicago"]]}} end

    valid = "America/Chicago" |> changeset() |> put_time_zone_query(catalog_query)
    invalid = "America/New_York" |> changeset() |> put_time_zone_query(catalog_query)

    assert ProfileTimezone.atomic(valid, [], %{}) == :ok

    assert ProfileTimezone.atomic(invalid, [], %{}) ==
             {:error, field: :timezone, message: "is not a supported timezone"}
  end

  test "keeps the user timezone update action atomic" do
    assert Ash.Resource.Info.action(User, :update_timezone_preference).require_atomic?
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
