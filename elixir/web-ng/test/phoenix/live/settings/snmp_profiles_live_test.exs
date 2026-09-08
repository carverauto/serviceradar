defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders SNMP profile credentials fields", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/snmp/new")

    assert html =~ "SNMP Credentials"
    assert has_element?(lv, "select[name='form[version]']")
    assert has_element?(lv, "input[name='form[community]']")
  end

  test "reuse-credential checkbox stays checked after validate", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/snmp/new")

    html =
      lv
      |> form("form[phx-submit='save_profile']", %{
        "form" => %{
          "name" => "Reusable",
          "save_credential_as_reusable" => "true",
          "credential_name" => "Core switches"
        }
      })
      |> render_change()

    assert html =~ ~s(name="form[save_credential_as_reusable]")
    assert html =~ ~s(value="true")
    assert html =~ "checked"
    assert html =~ ~s(value="Core switches")
  end

  test "edit form keeps stored credentials masked", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{name: "Profile #{unique}", community: "secret"})
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp/#{profile.id}/edit")

    assert has_element?(
             lv,
             "input[name='form[community]'][placeholder='Leave blank to keep existing']"
           )
  end

  test "new profile form renders the agent targeting selector", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/snmp/new")

    assert html =~ "Agent Targeting"
    # Hidden empty entry guarantees unchecking all submits [] (legacy all-agents).
    assert has_element?(lv, "input[type='hidden'][name='form[agent_ids][]']")
  end

  test "agent targeting renders a checkbox per active agent", %{conn: conn} do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: "agent-snmp-#{System.unique_integer([:positive])}"})

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp/new")

    assert has_element?(lv, "input[type='checkbox'][name='form[agent_ids][]'][value='#{agent.uid}']")
  end

  test "editing a profile pre-checks its pinned agents", %{conn: conn, scope: scope} do
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: "agent-pin-#{System.unique_integer([:positive])}"})

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Pinned #{System.unique_integer([:positive])}",
        agent_ids: [agent.uid]
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp/#{profile.id}/edit")

    assert has_element?(
             lv,
             "input[type='checkbox'][name='form[agent_ids][]'][value='#{agent.uid}'][checked]"
           )
  end

  test "saving with no agents checked persists empty agent_ids (legacy)", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp/new")

    lv
    |> form("form[phx-submit='save_profile']", %{
      "form" => %{"name" => "Legacy Profile #{unique}", "agent_ids" => [""]}
    })
    |> render_submit()

    {:ok, profile} =
      SNMPProfile
      |> Ash.Query.for_read(:by_name, %{name: "Legacy Profile #{unique}"})
      |> Ash.read_one(scope: scope)

    assert profile.agent_ids == []
  end

  test "saving with an agent checked persists that agent_id", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    gateway = gateway_fixture()
    agent = agent_fixture(gateway, %{uid: "agent-save-#{unique}"})

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp/new")

    lv
    |> form("form[phx-submit='save_profile']", %{
      "form" => %{"name" => "Pinned Save #{unique}", "agent_ids" => ["", agent.uid]}
    })
    |> render_submit()

    {:ok, profile} =
      SNMPProfile
      |> Ash.Query.for_read(:by_name, %{name: "Pinned Save #{unique}"})
      |> Ash.read_one(scope: scope)

    assert profile.agent_ids == [agent.uid]
  end

  test "renders target counts for SNMP profiles", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    device_fixture(%{hostname: "target#{unique}"})

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Profile #{unique}",
        poll_interval: 60,
        timeout: 5,
        retries: 3,
        enabled: true,
        target_query: "in:devices hostname:target#{unique}"
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp")

    assert has_element?(lv, "#snmp-profile-#{profile.id}-targets", "1 target")
  end

  test "renders target counts for duplicate SNMP profile target queries", %{
    conn: conn,
    scope: scope
  } do
    unique = System.unique_integer([:positive])
    device_fixture(%{hostname: "target-duplicate-#{unique}"})
    target_query = "in:devices hostname:target-duplicate-#{unique}"

    {:ok, first_profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "First Duplicate #{unique}",
        target_query: target_query
      })
      |> Ash.create(scope: scope)

    {:ok, second_profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Second Duplicate #{unique}",
        target_query: target_query
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp")

    assert has_element?(lv, "#snmp-profile-#{first_profile.id}-targets", "1 target")
    assert has_element?(lv, "#snmp-profile-#{second_profile.id}-targets", "1 target")
  end

  test "interface target counts fail closed for unsupported filters", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Unsupported Interface Filter #{unique}",
        target_query: "in:interfaces unsupported_field:edge"
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp")

    assert has_element?(lv, "#snmp-profile-#{profile.id}-targets", "Unknown")
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  describe "reusable SNMP credential selection" do
    # A profile can bind a shared credential instead of holding its own encrypted
    # copy. SNMPProfile already carried `credential_secret_id` and
    # SNMPProfiles.CredentialResolver already branched on it; until now nothing
    # in the UI could set it, so every profile was necessarily profile-local.

    test "the form offers a credential selector defaulting to profile-local", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/settings/snmp/new")

      assert has_element?(lv, "select[name='form[credential_secret_id]']")
      assert html =~ "Store on this profile"
      refute has_element?(lv, "#snmp-profile-reusable-credential-link")
      # Nothing selected, so the profile-local fields are still the ones to fill in.
      assert has_element?(lv, "input[name='form[community]']")
    end

    test "an edit form links directly to its reusable credential", %{conn: conn, scope: scope} do
      unique = System.unique_integer([:positive])

      {:ok, secret} =
        NetworkCredentialSecret
        |> Ash.Changeset.for_create(:create, %{
          name: "SNMP v3 #{unique}",
          provider: "snmp",
          credential_kind: :snmp,
          username: "snmp-operator",
          secret_payload: Jason.encode!(%{"username" => "snmp-operator"}),
          metadata: %{"auth_method" => "v3"}
        })
        |> Ash.create(scope: scope)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(:create, %{
          name: "Linked Credential #{unique}",
          version: :v3,
          credential_secret_id: secret.id
        })
        |> Ash.create(scope: scope)

      {:ok, lv, _html} = live(conn, ~p"/settings/snmp/#{profile.id}/edit")

      href =
        "/settings/networks/credentials?credential_id=#{secret.id}" <>
          "#credential-secret-#{secret.id}"

      assert has_element?(
               lv,
               ~s(#snmp-profile-reusable-credential-link[href="#{href}"]),
               "View reusable credential"
             )
    end

    test "blank selection persists as nil rather than failing to cast", %{
      conn: conn,
      scope: scope
    } do
      # The empty option submits "", and credential_secret_id is a :uuid. Ash does
      # not cast "" to nil for that type, so without normalization this errors
      # instead of meaning "no shared credential".
      unique = System.unique_integer([:positive])

      {:ok, lv, _html} = live(conn, ~p"/settings/snmp/new")

      lv
      |> form("form[phx-submit='save_profile']", %{
        "form" => %{
          "name" => "Blank Credential #{unique}",
          "credential_secret_id" => "",
          "agent_ids" => [""]
        }
      })
      |> render_submit()

      {:ok, profile} =
        SNMPProfile
        |> Ash.Query.for_read(:by_name, %{name: "Blank Credential #{unique}"})
        |> Ash.read_one(scope: scope)

      assert profile.credential_secret_id == nil
    end

    test "credential promotion failures expose only a fixed redacted message", %{
      conn: conn,
      scope: scope
    } do
      unique = System.unique_integer([:positive])
      credential_name = "Duplicate SNMP credential #{unique}"
      submitted_secret = "community-must-not-render-#{unique}"

      {:ok, _secret} =
        NetworkCredentialSecret
        |> Ash.Changeset.for_create(:create, %{
          name: credential_name,
          provider: "snmp",
          credential_kind: :snmp,
          secret_payload: Jason.encode!(%{"community" => "already-stored"}),
          metadata: %{"auth_method" => "community"}
        })
        |> Ash.create(scope: scope)

      {:ok, lv, _html} = live(conn, ~p"/settings/snmp/new")

      html =
        lv
        |> form("form[phx-submit='save_profile']", %{
          "form" => %{
            "name" => "Profile with duplicate credential #{unique}",
            "version" => "v2c",
            "community" => submitted_secret,
            "save_credential_as_reusable" => "true",
            "credential_name" => credential_name,
            "agent_ids" => [""]
          }
        })
        |> render_submit()

      assert html =~ "Could not save the credential for reuse. Check the fields and try again."
      refute html =~ submitted_secret
      refute html =~ "Ash.Error"
      refute html =~ "already been taken"
    end
  end
end
