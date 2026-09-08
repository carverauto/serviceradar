defmodule ServiceRadarWebNG.CountryCentroidsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CountryCentroids

  @moduletag :unit
  @moduletag :db_free

  test "returns lon/lat for known ISO country codes" do
    assert [-98.58, 39.83] = CountryCentroids.point("us")
    assert [104.20, 35.86] = CountryCentroids.point("CN")
  end

  test "returns nil for blank or unknown codes" do
    assert CountryCentroids.point(nil) == nil
    assert CountryCentroids.point("") == nil
    assert CountryCentroids.point("ZZ") == nil
  end
end
