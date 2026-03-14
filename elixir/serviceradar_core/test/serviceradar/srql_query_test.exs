defmodule ServiceRadar.SRQLQueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SRQLQuery

  test "ensure_target prefixes a default entity when missing" do
    assert SRQLQuery.ensure_target("hostname:router-1", :devices) ==
             "in:devices hostname:router-1"
  end

  test "ensure_target preserves an explicit target" do
    assert SRQLQuery.ensure_target(" in:interfaces type:ethernet ", :devices) ==
             "in:interfaces type:ethernet"
  end

  test "ensure_target turns blank queries into the bare target selector" do
    assert SRQLQuery.ensure_target("   ", :devices) == "in:devices"
  end
end
