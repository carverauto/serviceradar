defmodule ServiceRadarWebNGWeb.DashboardPackagePreferencesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DashboardPackageLive.Preferences

  # Pure map manipulation — no repo, so this runs in the DB-free suite too.
  @moduletag :db_free

  doctest Preferences

  describe "merge/2" do
    test "user preferences win over the instance seed" do
      settings = %{"preferences" => %{"rids.layout" => "airports"}, "other" => 1}

      assert Preferences.merge(settings, %{"rids.layout" => "gates"}) == %{
               "preferences" => %{"rids.layout" => "gates"},
               "other" => 1
             }
    end

    test "seed keys the user has not set are preserved" do
      settings = %{"preferences" => %{"a" => 1, "b" => 2}}

      assert Preferences.merge(settings, %{"b" => 3, "c" => 4}) == %{
               "preferences" => %{"a" => 1, "b" => 3, "c" => 4}
             }
    end

    test "an atom-keyed seed is normalized to the string form the renderer reads" do
      # Instance settings can round-trip through either shape depending on how
      # they were persisted; leaving both keys in place would let the renderer
      # read a stale value.
      merged = Preferences.merge(%{preferences: %{"a" => 1}}, %{"b" => 2})

      assert merged == %{"preferences" => %{"a" => 1, "b" => 2}}
      refute Map.has_key?(merged, :preferences)
    end

    test "settings without any preferences gain them" do
      assert Preferences.merge(%{"mapbox" => %{}}, %{"a" => 1}) == %{
               "mapbox" => %{},
               "preferences" => %{"a" => 1}
             }
    end

    test "a non-map seed is replaced rather than crashing" do
      assert Preferences.merge(%{"preferences" => "nonsense"}, %{"a" => 1}) == %{
               "preferences" => %{"a" => 1}
             }
    end

    test "empty preferences leave settings untouched, atom key and all" do
      settings = %{preferences: %{"a" => 1}}
      assert Preferences.merge(settings, %{}) == settings
    end

    test "non-map inputs degrade instead of raising" do
      assert Preferences.merge(%{"a" => 1}, nil) == %{"a" => 1}
      assert Preferences.merge(nil, %{"a" => 1}) == %{}
    end
  end

  describe "put/3" do
    test "sets a key" do
      assert Preferences.put(%{}, "rids.layout", "table") == %{"rids.layout" => "table"}
    end

    test "overwrites an existing key" do
      assert Preferences.put(%{"a" => 1}, "a", 2) == %{"a" => 2}
    end

    test "trims the key" do
      assert Preferences.put(%{}, "  a  ", 1) == %{"a" => 1}
    end

    test "ignores a blank key" do
      # The event is client-supplied, so an empty key must not create one.
      assert Preferences.put(%{"a" => 1}, "", 2) == %{"a" => 1}
      assert Preferences.put(%{"a" => 1}, "   ", 2) == %{"a" => 1}
    end

    test "ignores a non-binary key" do
      assert Preferences.put(%{"a" => 1}, :b, 2) == %{"a" => 1}
    end

    test "stores structured values, which favorites lists need" do
      assert Preferences.put(%{}, "rids.favorites", ["a", "b"]) == %{
               "rids.favorites" => ["a", "b"]
             }
    end
  end
end
