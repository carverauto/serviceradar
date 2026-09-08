defmodule ServiceRadarWebNGWeb.AuthoredDashboardVariablesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables

  test "substitute escapes string variables as SRQL literals" do
    variables = [
      %{name: "site", label: "Site", options: [], default: "", type: :string}
    ]

    values = %{"site" => ~s(ZZA" in:flows time:last_30d)}

    assert DashboardVariables.substitute("in:devices site:${site}", values, variables) ==
             ~s(in:devices site:"ZZA\\" in:flows time:last_30d")
  end

  test "substitute replaces quoted placeholders with one escaped literal" do
    variables = [
      %{name: "site", label: "Site", options: [], default: "", type: :string}
    ]

    assert DashboardVariables.substitute(~s(in:devices site:"${site}"), %{"site" => "MSP"}, variables) ==
             ~s(in:devices site:"MSP")
  end

  test "substitute preserves embedded variables inside quoted literals" do
    variables = [
      %{name: "q", label: "Search", options: [], default: "", type: :string}
    ]

    values = %{"q" => ~s(a" in:devices b)}

    assert DashboardVariables.substitute(~s(in:logs message like:"%${q}%"), values, variables) ==
             ~s(in:logs message like:"%a\\" in:devices b%")
  end

  test "values reject option-backed variable values outside the allowed set" do
    dashboard = %{
      variables: %{
        "site" => %{"label" => "Site", "default" => "ZZA", "options" => ["ZZA", "MSP"]}
      }
    }

    assert DashboardVariables.values(dashboard, %{"site" => ~s(MSP" in:flows)}) == %{"site" => "ZZA"}
    assert DashboardVariables.values(dashboard, %{"site" => "MSP"}) == %{"site" => "MSP"}
  end

  test "declared numeric and boolean variables substitute without string grammar" do
    variables = [
      %{name: "limit", label: "Limit", options: [], default: "25", type: :integer},
      %{name: "active", label: "Active", options: [], default: "true", type: :boolean}
    ]

    values = %{"limit" => "50", "active" => "false"}

    assert DashboardVariables.substitute("in:devices is_active:${active} limit:${limit}", values, variables) ==
             "in:devices is_active:false limit:50"
  end
end
