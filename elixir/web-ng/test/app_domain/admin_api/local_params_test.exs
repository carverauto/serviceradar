defmodule ServiceRadarWebNG.AdminApi.LocalParamsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.AdminApi.LocalParams

  test "accepts integer limits directly" do
    assert LocalParams.normalize_limit(25) == 25
  end

  test "clamps oversized limits" do
    assert LocalParams.normalize_limit("5000") == 1_000
  end

  test "falls back to the default limit for invalid or non-positive inputs" do
    assert LocalParams.normalize_limit(nil) == 100
    assert LocalParams.normalize_limit("not-an-int") == 100
    assert LocalParams.normalize_limit(0) == 100
    assert LocalParams.normalize_limit(-10) == 100
  end
end
