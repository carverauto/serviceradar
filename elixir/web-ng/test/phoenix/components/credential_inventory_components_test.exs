defmodule ServiceRadarWebNGWeb.Components.CredentialInventoryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.ProfileForm

  @moduletag :db_free

  test "does not expose a fingerprint derived from an SNMP community payload" do
    fingerprint = "sha256:guessable-community-payload"

    html =
      render_inventory(
        credential_kind: :snmp,
        username: nil,
        public_fingerprint: fingerprint,
        metadata: %{"auth_method" => "community"}
      )

    assert html =~ "Core switches"
    refute html =~ fingerprint
  end

  test "keeps a genuine SSH public-key fingerprint visible" do
    fingerprint = "SHA256:public-ssh-key"

    html =
      render_inventory(
        credential_kind: :ssh_private_key,
        username: nil,
        public_fingerprint: fingerprint,
        metadata: %{"auth_method" => "key_pair"}
      )

    assert html =~ fingerprint
  end

  test "renders unavailable instead of zero when SNMP usage cannot be loaded" do
    html = render_inventory(snmp_profile_usage_counts: :unavailable)

    assert html =~ "SNMP usage unavailable"
    refute html =~ "0 SNMP profiles"
  end

  test "focused credential rows opt into the browser focus hook" do
    html = render_inventory(focused_credential_id: "credential-1")

    assert html =~ ~s(id="credential-secret-credential-1")
    assert html =~ ~s(data-focused="true")
    assert html =~ ~s(aria-current="true")
    assert html =~ ~s(phx-hook="CredentialDeepLinkFocus")
  end

  test "summarizes successful usage reads and preserves failures as unavailable" do
    profiles = [
      %{credential_secret_id: "credential-1"},
      %{credential_secret_id: "credential-1"},
      %{credential_secret_id: "credential-2"}
    ]

    assert NetworkCredentialRulesLive.snmp_profile_usage_counts({:ok, profiles}) == %{
             "credential-1" => 2,
             "credential-2" => 1
           }

    assert NetworkCredentialRulesLive.snmp_profile_usage_counts({:error, :timeout}) ==
             :unavailable
  end

  test "SNMP reusable credential reference links to its focused inventory row" do
    html =
      render_component(&ProfileForm.reusable_credential_reference/1,
        credential: %{id: "credential-1"}
      )

    assert html =~ ~s(id="snmp-profile-reusable-credential-link")

    assert html =~
             ~s(href="/settings/networks/credentials?credential_id=credential-1#credential-secret-credential-1")
  end

  defp render_inventory(overrides) do
    secret_overrides =
      Keyword.drop(overrides, [:focused_credential_id, :snmp_profile_usage_counts])

    secret =
      Map.merge(
        %{
          id: "credential-1",
          name: "Core switches",
          description: nil,
          provider: "snmp",
          credential_kind: :snmp,
          username: "snmp-operator",
          public_fingerprint: nil,
          source_type: :internal_encrypted,
          rotation_state: :active,
          metadata: %{"auth_method" => "v3"}
        },
        Map.new(secret_overrides)
      )

    render_component(&NetworkCredentialRulesLive.credential_inventory_table/1,
      loading?: false,
      secrets: [secret],
      focused_credential_id: Keyword.get(overrides, :focused_credential_id),
      integration_profiles: %{},
      credential_rule_usage_counts: %{},
      snmp_profile_usage_counts: Keyword.get(overrides, :snmp_profile_usage_counts, %{"credential-1" => 0})
    )
  end
end
