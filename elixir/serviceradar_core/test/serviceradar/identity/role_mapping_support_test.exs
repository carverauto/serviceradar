defmodule ServiceRadar.Identity.RoleMappingSupportTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Identity.RoleMappingSupport

  test "normalize_role accepts allowed atoms and strings" do
    assert RoleMappingSupport.normalize_role(:viewer) == :viewer
    assert RoleMappingSupport.normalize_role("admin") == :admin
    assert RoleMappingSupport.normalize_role("unknown") == nil
  end

  test "get_key reads string and atom keyed maps safely" do
    assert RoleMappingSupport.get_key(%{"role" => "viewer"}, "role") == "viewer"
    assert RoleMappingSupport.get_key(%{role: :admin}, "role") == :admin
    assert RoleMappingSupport.get_key(%{}, "missing") == nil
  end
end
