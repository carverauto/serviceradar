defmodule ServiceRadarWebNGWeb.Components.CredentialInventoryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.CredentialUsage.LiveGrant
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialInventoryComponents
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.ProfileForm

  @moduletag :db_free

  test "one SNMP profile preserves profile and rule counts and exposes one exact named edit link" do
    document =
      render_inventory(
        usage_by_id: %{
          "credential-1" => usage([consumer(:snmp_profile, "profile-1", "Default SNMP")])
        }
      )

    usage_cell = LazyHTML.query(document, "#credential-usage-credential-1")

    assert usage_cell
           |> LazyHTML.query("[data-role='credential-usage-counts']")
           |> LazyHTML.text()
           |> normalize_text() == "1 SNMP profile · 0 rules"

    link =
      LazyHTML.query(
        usage_cell,
        ~s(#credential-usage-credential-1 a[href="/settings/snmp/profile-1/edit"])
      )

    assert link |> LazyHTML.text() |> normalize_text() == "1 SNMP profile · Default SNMP"

    assert LazyHTML.attribute(link, "aria-label") == [
             "Edit SNMP profile Default SNMP"
           ]
  end

  test "multiple SNMP profiles expose every named accessible edit link" do
    document =
      render_inventory(
        usage_by_id: %{
          "credential-1" =>
            usage([
              consumer(:snmp_profile, "profile-1", "Access switches"),
              consumer(:snmp_profile, "profile-2", "Core routers")
            ])
        }
      )

    summary = LazyHTML.query(document, "#credential-usage-credential-1 summary")
    assert summary |> LazyHTML.text() |> normalize_text() == "2 SNMP profiles · 0 rules"

    links = LazyHTML.query(document, "#credential-usage-credential-1 a")

    assert LazyHTML.attribute(links, "href") == [
             "/settings/snmp/profile-1/edit",
             "/settings/snmp/profile-2/edit"
           ]

    assert LazyHTML.attribute(links, "aria-label") == [
             "Edit SNMP profile Access switches",
             "Edit SNMP profile Core routers"
           ]
  end

  test "zero and unavailable usage remain distinct" do
    zero_document =
      render_inventory(usage_by_id: %{"credential-1" => usage([])})

    unavailable_document = render_inventory(usage_by_id: :unavailable)

    assert zero_document
           |> LazyHTML.query("#credential-usage-credential-1")
           |> LazyHTML.text()
           |> normalize_text() == "No consumers"

    assert unavailable_document
           |> LazyHTML.query("#credential-usage-credential-1")
           |> LazyHTML.text()
           |> normalize_text() == "Usage unavailable"

    refute LazyHTML.text(unavailable_document) =~ "0 SNMP profiles"
  end

  test "credential row has an accessible actions dropdown with all management events" do
    document = render_inventory()
    actions = LazyHTML.query(document, "#credential-actions-credential-1")

    assert LazyHTML.attribute(LazyHTML.query(actions, "summary"), "aria-label") == [
             "Actions for Core switches"
           ]

    assert LazyHTML.attribute(LazyHTML.query(actions, "button"), "phx-click") == [
             "edit_credential",
             "rotate_credential",
             "delete_credential"
           ]
  end

  test "edit details exposes only safe mutable fields and immutable context" do
    document =
      render_modal(
        :edit,
        form: %{
          "id" => "credential-1",
          "name" => "Core switches",
          "description" => "Datacenter switching"
        }
      )

    modal = LazyHTML.query(document, "#credential-edit-modal")

    assert LazyHTML.attribute(LazyHTML.query(modal, "form"), "phx-submit") == [
             "save_credential_details"
           ]

    assert LazyHTML.attribute(LazyHTML.query(modal, "input"), "name") == [
             "credential_details[id]",
             "credential_details[name]"
           ]

    assert LazyHTML.attribute(LazyHTML.query(modal, "textarea"), "name") == [
             "credential_details[description]"
           ]

    text = LazyHTML.text(modal)
    assert text =~ "SNMP"
    assert text =~ "SNMPv3 user"
    assert text =~ "Encrypted here"
    refute text =~ "secret_payload"
  end

  test "rotation renders descriptor fields blank even after a rejected secret submission" do
    marker = "ui-secret-marker-rotate"

    document =
      render_modal(
        :rotate,
        form: %{
          "id" => "credential-1",
          "fields" => %{"username" => "operator", "auth_password" => marker}
        },
        error: "Authentication password is required"
      )

    modal = LazyHTML.query(document, "#credential-rotate-modal")
    inputs = LazyHTML.query(modal, "input[data-credential-rotation-field]")

    assert LazyHTML.attribute(inputs, "value") == ["", ""]
    assert LazyHTML.attribute(inputs, "autocomplete") == ["off", "new-password"]

    assert LazyHTML.attribute(LazyHTML.query(modal, "form"), "phx-submit") == [
             "save_credential_rotation"
           ]

    refute LazyHTML.to_html(modal) =~ marker
  end

  test "rotation preserves the descriptor textarea control without retaining its value" do
    marker = "ui-secret-marker-private-key"

    descriptor = %{
      profile: Map.fetch!(integration_profiles(), "snmp"),
      method: %{
        "id" => "key_pair",
        "label" => "Key pair",
        "fields" => [
          %{
            "id" => "private_key",
            "label" => "Private key",
            "control" => "textarea",
            "secret" => true,
            "required" => true
          }
        ]
      }
    }

    document =
      render_modal(
        :rotate,
        descriptor: descriptor,
        form: %{
          "id" => "credential-1",
          "fields" => %{"private_key" => marker}
        },
        error: "Private key is invalid"
      )

    modal = LazyHTML.query(document, "#credential-rotate-modal")
    textarea = LazyHTML.query(modal, "textarea[data-credential-rotation-field]")

    assert LazyHTML.attribute(textarea, "name") == [
             "credential_rotation[fields][private_key]"
           ]

    assert textarea |> LazyHTML.text() |> String.trim() == ""
    refute LazyHTML.to_html(modal) =~ marker
    assert LazyHTML.to_html(LazyHTML.query(modal, "input[data-credential-rotation-field]")) == ""
  end

  test "credential action dialogs have stable accessible names" do
    for kind <- [:edit, :rotate, :delete] do
      document = render_modal(kind, [])
      modal_id = "credential-#{kind}-modal"
      title_id = "#{modal_id}-title"
      modal = LazyHTML.query(document, "##{modal_id}")

      assert LazyHTML.attribute(modal, "aria-labelledby") == [title_id]
      assert LazyHTML.attribute(LazyHTML.query(modal, "##{title_id}"), "id") == [title_id]
    end
  end

  test "delete modal fails closed for unavailable and used credentials" do
    unavailable = render_modal(:delete, usage: :unavailable)

    assert unavailable
           |> LazyHTML.query("#credential-delete-modal")
           |> LazyHTML.text() =~ "Usage unavailable"

    assert unavailable
           |> LazyHTML.query("form[phx-submit='confirm_delete_credential']")
           |> LazyHTML.to_html() == ""

    used =
      render_modal(
        :delete,
        usage:
          usage([
            consumer(:snmp_profile, "profile-1", "Default SNMP"),
            consumer(:credential_rule, "rule-1", "Datacenter discovery")
          ])
      )

    used_modal = LazyHTML.query(used, "#credential-delete-modal")
    assert LazyHTML.text(used_modal) =~ "Can't delete Core switches"

    assert LazyHTML.attribute(LazyHTML.query(used_modal, "a"), "href") == [
             "/settings/snmp/profile-1/edit",
             "/settings/networks/credentials/rule-1/edit"
           ]

    assert used_modal
           |> LazyHTML.query("form[phx-submit='confirm_delete_credential']")
           |> LazyHTML.to_html() == ""
  end

  test "unused delete requires the exact credential id before permanent deletion" do
    document = render_modal(:delete, usage: usage([]))
    modal = LazyHTML.query(document, "#credential-delete-modal")
    form = LazyHTML.query(modal, "form[phx-submit='confirm_delete_credential']")

    assert LazyHTML.attribute(LazyHTML.query(form, "input"), "name") == [
             "credential_delete[id]",
             "credential_delete[confirmation_id]"
           ]

    assert LazyHTML.attribute(
             LazyHTML.query(form, "input[name='credential_delete[confirmation_id]']"),
             "placeholder"
           ) == ["credential-1"]

    assert LazyHTML.text(form) =~ "Delete permanently"
  end

  test "active grants block delete without rendering grant internals" do
    grant = %LiveGrant{
      id: "grant-1",
      status: :active,
      consumer_kind: "plugin",
      consumer_id: "plugin-1",
      purpose: "inventory",
      expires_at: ~U[2026-09-01 00:00:00Z]
    }

    document = render_modal(:delete, usage: %Result{consumers: [], live_grants: [grant]})
    modal = LazyHTML.query(document, "#credential-delete-modal")

    assert LazyHTML.text(modal) =~ "1 active grant"
    refute LazyHTML.to_html(modal) =~ "secret_payload"
    refute LazyHTML.to_html(modal) =~ "confirm_delete_credential"
  end

  test "does not expose a fingerprint derived from an SNMP community payload" do
    fingerprint = "sha256:guessable-community-payload"

    document =
      render_inventory(
        credential_kind: :snmp,
        username: nil,
        public_fingerprint: fingerprint,
        metadata: %{"auth_method" => "community"}
      )

    assert LazyHTML.text(document) =~ "Core switches"
    refute LazyHTML.to_html(document) =~ fingerprint
  end

  test "keeps a genuine SSH public-key fingerprint visible" do
    fingerprint = "SHA256:public-ssh-key"

    document =
      render_inventory(
        credential_kind: :ssh_private_key,
        username: nil,
        public_fingerprint: fingerprint,
        metadata: %{"auth_method" => "key_pair"}
      )

    assert LazyHTML.text(document) =~ fingerprint
  end

  test "focused credential rows opt into the browser focus hook" do
    document = render_inventory(focused_credential_id: "credential-1")
    row = LazyHTML.query(document, "#credential-secret-credential-1")

    assert LazyHTML.attribute(row, "data-focused") == ["true"]
    assert LazyHTML.attribute(row, "aria-current") == ["true"]
    assert LazyHTML.attribute(row, "phx-hook") == ["CredentialDeepLinkFocus"]
  end

  test "SNMP reusable credential reference links to its focused inventory row" do
    document =
      (&ProfileForm.reusable_credential_reference/1)
      |> render_component(credential: %{id: "credential-1"})
      |> LazyHTML.from_fragment()

    link = LazyHTML.query(document, "#snmp-profile-reusable-credential-link")

    assert LazyHTML.attribute(link, "href") == [
             "/settings/networks/credentials?credential_id=credential-1#credential-secret-credential-1"
           ]
  end

  defp render_inventory(overrides \\ []) do
    secret_overrides =
      Keyword.drop(overrides, [:focused_credential_id, :usage_by_id])

    secret = Map.merge(secret(), Map.new(secret_overrides))

    (&CredentialInventoryComponents.credential_inventory_table/1)
    |> render_component(
      loading?: false,
      secrets: [secret],
      focused_credential_id: Keyword.get(overrides, :focused_credential_id),
      integration_profiles: integration_profiles(),
      usage_by_id: Keyword.get(overrides, :usage_by_id, %{"credential-1" => usage([])})
    )
    |> LazyHTML.from_fragment()
  end

  defp render_modal(kind, overrides) do
    descriptor =
      Keyword.get(overrides, :descriptor, %{
        profile: Map.fetch!(integration_profiles(), "snmp"),
        method: %{
          "id" => "v3",
          "label" => "SNMPv3 user",
          "fields" => [
            %{
              "id" => "username",
              "label" => "Username",
              "control" => "text",
              "secret" => false,
              "required" => true
            },
            %{
              "id" => "auth_password",
              "label" => "Authentication password",
              "control" => "password",
              "secret" => true,
              "required" => true
            }
          ]
        }
      })

    form =
      overrides
      |> Keyword.get(:form, %{"id" => "credential-1"})
      |> Phoenix.Component.to_form(as: modal_form_name(kind))

    (&CredentialInventoryComponents.credential_action_modal/1)
    |> render_component(
      modal: %{kind: kind, secret: secret()},
      form: form,
      descriptor: descriptor,
      usage: Keyword.get(overrides, :usage, usage([])),
      error: Keyword.get(overrides, :error)
    )
    |> LazyHTML.from_fragment()
  end

  defp secret do
    %{
      id: "credential-1",
      name: "Core switches",
      description: "Datacenter switching",
      provider: "snmp",
      credential_kind: :snmp,
      username: "snmp-operator",
      public_fingerprint: nil,
      source_type: :internal_encrypted,
      rotation_state: :active,
      metadata: %{"auth_method" => "v3"}
    }
  end

  defp integration_profiles do
    %{
      "snmp" => %{
        "provider" => "snmp",
        "label" => "SNMP",
        "auth_methods" => [
          %{"id" => "v3", "label" => "SNMPv3 user", "credential_kind" => "snmp"},
          %{"id" => "community", "label" => "Community string", "credential_kind" => "snmp"}
        ]
      }
    }
  end

  defp consumer(kind, id, label), do: %Consumer{kind: kind, id: id, label: label}

  defp usage(consumers), do: %Result{status: :available, consumers: consumers, live_grants: []}

  defp modal_form_name(:edit), do: :credential_details
  defp modal_form_name(:rotate), do: :credential_rotation
  defp modal_form_name(:delete), do: :credential_delete

  defp normalize_text(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
