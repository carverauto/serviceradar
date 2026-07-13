defmodule ServiceRadar.Credentials.HpnaProfileTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialProviderProfile
  alias ServiceRadar.Credentials.ProviderProfiles.HpnaProfile

  test "registers the HPNA device-inventory provider" do
    assert {:ok, HpnaProfile} = CredentialProviderProfile.profile_for("hpna")
    assert HpnaProfile.purposes() == [:device_inventory]
    assert HpnaProfile.plugin_id(:device_inventory) == "hpna-inventory"
    assert HpnaProfile.host_source() == :static_endpoint_metadata
  end

  test "builds bounded public assignment params with the default switch query" do
    assert {:ok, params} = HpnaProfile.assignment_params(rule(%{}))

    assert params == %{
             "instance_id" => "example-automation-prod",
             "token_url" => "https://hpna.example.test/oauth/token",
             "api_url" => "https://hpna.example.test/api/automation/wrapper",
             "queries" => [
               %{"name" => "switches", "parameters" => %{"type" => "Switch"}}
             ],
             "page_size" => 1_000,
             "max_rows" => 25_000,
             "max_result_bytes" => 10_485_760,
             "request_timeout_seconds" => 30,
             "max_retries" => 2
           }

    refute Map.has_key?(params, "credential_broker")
    refute inspect(params) =~ "password"
  end

  test "accepts allowlisted query filters and rejects plugin-owned or malformed values" do
    assert {:ok, params} =
             HpnaProfile.assignment_params(
               rule(%{
                 "queries" => [
                   %{
                     "name" => "iad-switches",
                     "parameters" => %{
                       "type" => "Switch",
                       "vendor" => "Cisco",
                       "disabled" => false,
                       "ids" => [1, 2]
                     }
                   }
                 ]
               })
             )

    assert hd(params["queries"])["parameters"]["vendor"] == "Cisco"

    assert {:error, {:invalid_hpna_setting, "queries.parameters.command"}} =
             HpnaProfile.assignment_params(
               rule(%{
                 "queries" => [
                   %{"name" => "unsafe", "parameters" => %{"command" => "show device"}}
                 ]
               })
             )

    assert {:error, {:invalid_hpna_setting, "queries.parameters.context"}} =
             HpnaProfile.assignment_params(
               rule(%{
                 "queries" => [
                   %{"name" => "context", "parameters" => %{"context" => "child"}}
                 ]
               })
             )
  end

  test "rejects unsafe endpoints and inconsistent result bounds" do
    assert {:error, {:invalid_hpna_setting, "token_url"}} =
             HpnaProfile.assignment_params(rule(%{"token_url" => "http://hpna.test/token"}))

    assert {:error, {:invalid_hpna_setting, "max_rows"}} =
             HpnaProfile.assignment_params(rule(%{"page_size" => 2_000, "max_rows" => 1_000}))

    assert {:error, {:invalid_hpna_setting, "api_url"}} =
             HpnaProfile.assignment_params(
               rule(%{"api_url" => "https://hpna.example.test/api/automation/wrapper/"})
             )

    assert {:error, {:invalid_hpna_setting, "api_url"}} =
             HpnaProfile.assignment_params(
               rule(%{"api_url" => "https://hpna.example.test:70000/api/automation/wrapper"})
             )
  end

  defp rule(overrides) do
    metadata =
      Map.merge(
        %{
          "instance_id" => "example-automation-prod",
          "token_url" => "https://hpna.example.test/oauth/token",
          "api_url" => "https://hpna.example.test/api/automation/wrapper"
        },
        overrides
      )

    %{
      id: "rule-hpna",
      provider: "hpna",
      auth_method: :username_password,
      purpose: :device_inventory,
      metadata: metadata
    }
  end
end
