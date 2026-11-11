defmodule ServiceRadarWebNGWeb.Components.CredentialFieldComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias ServiceRadar.Credentials.NativeDescriptors
  alias ServiceRadar.SNMPProfiles.ProtocolFormatter
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive
  alias ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialFieldComponents

  @moduletag :db_free

  @protocol_fields ~w(security_level auth_protocol priv_protocol)

  describe "a new SNMPv3 credential" do
    test "offers each level and protocol as a select holding the names core offers" do
      document = render_fields(new_credential_values())

      for {field, options} <- [
            {"security_level", ProtocolFormatter.security_level_options()},
            {"auth_protocol", ProtocolFormatter.auth_protocol_options()},
            {"priv_protocol", ProtocolFormatter.priv_protocol_options()}
          ] do
        rendered = LazyHTML.query(document, "select#credential_secret_fields_#{field} option")

        assert LazyHTML.attribute(rendered, "value") == Enum.map(options, & &1.value), field
        assert document |> LazyHTML.query("input#credential_secret_fields_#{field}") |> Enum.empty?(), field
      end
    end

    test "starts on authPriv with SHA-256 and AES-128" do
      document = render_fields(new_credential_values())

      assert selected_values(document) == %{
               "security_level" => ["authPriv"],
               "auth_protocol" => ["SHA256"],
               "priv_protocol" => ["AES"]
             }
    end

    test "says what each choice means and which ones are legacy" do
      document = render_fields(new_credential_values())

      assert option_label(document, "security_level", "authPriv") ==
               "authPriv (authentication and encryption)"

      assert option_label(document, "priv_protocol", "AES") == "AES (AES-128)"

      for {field, value} <- [{"auth_protocol", "MD5"}, {"auth_protocol", "SHA"}, {"priv_protocol", "DES"}] do
        assert option_label(document, field, value) =~ "legacy, weak", "#{field} #{value}"
      end

      refute option_label(document, "auth_protocol", "SHA256") =~ "legacy"
    end
  end

  describe "the security level" do
    test "decides which fields are shown and required" do
      for {level, shown} <- [
            {"noAuthNoPriv", []},
            {"authNoPriv", ~w(auth_protocol auth_password)},
            {"authPriv", ~w(auth_protocol auth_password priv_protocol priv_password)}
          ] do
        document = render_fields(%{new_credential_values() | "security_level" => level})

        for field <- ~w(auth_protocol auth_password priv_protocol priv_password) do
          control = LazyHTML.query(document, "#credential_secret_fields_#{field}")

          if field in shown do
            assert LazyHTML.attribute(control, "required") == [""], "#{field} at #{level}"
          else
            assert Enum.empty?(control), "#{field} at #{level}"
          end
        end

        # The level itself and the username are always there.
        assert Enum.count(LazyHTML.query(document, "#credential_secret_fields_security_level")) == 1
        assert Enum.count(LazyHTML.query(document, "#credential_secret_fields_username")) == 1
      end
    end

    test "switching away from a level drops its secrets and switching back restores the default protocol" do
      marker = "ui-secret-marker-level-switch"

      {:noreply, without_auth} =
        NetworkCredentialRulesLive.handle_event(
          "change_secret",
          %{
            "credential_secret" =>
              secret_form_params(%{
                "username" => "monitor",
                "security_level" => "noAuthNoPriv",
                # A hidden field is not submitted by a browser; a forged or stale
                # one must still not survive in the form.
                "auth_password" => marker
              })
          },
          secret_form_socket()
        )

      refute inspect(without_auth.assigns) =~ marker
      assert without_auth.assigns.secret_form.params["fields"]["username"] == "monitor"

      {:noreply, with_auth} =
        NetworkCredentialRulesLive.handle_event(
          "change_secret",
          %{
            "credential_secret" => secret_form_params(%{"username" => "monitor", "security_level" => "authPriv"})
          },
          without_auth
        )

      document = render_fields(with_auth.assigns.secret_form.params["fields"])

      assert selected_values(document) == %{
               "security_level" => ["authPriv"],
               "auth_protocol" => ["SHA256"],
               "priv_protocol" => ["AES"]
             }

      assert LazyHTML.attribute(password_inputs(document), "value") == ["", ""]
    end
  end

  describe "saving" do
    test "a name the form does not offer is rejected on its field and nothing is kept" do
      marker = "ui-secret-marker-rejected-save"

      {:noreply, socket} =
        NetworkCredentialRulesLive.handle_event(
          "save_secret",
          %{
            "credential_secret" =>
              secret_form_params(%{
                "username" => "monitor",
                "security_level" => "authPriv",
                "auth_protocol" => "SHA-256",
                "auth_password" => marker,
                "priv_protocol" => "AES",
                "priv_password" => marker
              })
          },
          secret_form_socket()
        )

      message = "Authentication protocol must be one of the listed options"

      assert socket.assigns.secret_field_errors == %{"auth_protocol" => message}
      assert socket.assigns.flash["error"] == message
      refute inspect(socket.assigns) =~ marker

      document =
        render_fields(socket.assigns.secret_form.params["fields"], errors: socket.assigns.secret_field_errors)

      assert document |> LazyHTML.text() |> String.contains?(message)
      # The rejected name is not an option, so the select falls back to "choose".
      assert selected_values(document)["auth_protocol"] == []
    end

    test "a field the chosen level requires is named when it is missing" do
      {:noreply, socket} =
        NetworkCredentialRulesLive.handle_event(
          "save_secret",
          %{
            "credential_secret" =>
              secret_form_params(%{
                "username" => "monitor",
                "security_level" => "authPriv",
                "auth_protocol" => "SHA256",
                "auth_password" => "auth-secret",
                "priv_protocol" => "AES",
                "priv_password" => ""
              })
          },
          secret_form_socket()
        )

      assert socket.assigns.secret_field_errors == %{"priv_password" => "Privacy password is required"}
    end
  end

  describe "rotation" do
    test "starts with no level or protocol chosen and never renders a submitted secret" do
      marker = "ui-secret-marker-rotation-fields"
      method = snmp_v3_method()

      blank = render_fields(CredentialFieldComponents.values(method, %{}, false), form_name: "credential_rotation")

      assert selected_values(blank, "credential_rotation") == %{
               "security_level" => [],
               "auth_protocol" => [],
               "priv_protocol" => []
             }

      submitted = %{
        "username" => "monitor",
        "security_level" => "authNoPriv",
        "auth_protocol" => "SHA512",
        "auth_password" => marker
      }

      kept = CredentialFieldComponents.values(method, submitted, false)
      document = render_fields(kept, form_name: "credential_rotation")

      refute inspect(kept) =~ marker
      refute LazyHTML.to_html(document) =~ marker

      assert selected_values(document, "credential_rotation") == %{
               "security_level" => ["authNoPriv"],
               "auth_protocol" => ["SHA512"],
               "priv_protocol" => []
             }

      assert Enum.empty?(LazyHTML.query(document, "#credential_rotation_fields_priv_password"))
    end
  end

  defp render_fields(values, opts \\ []) do
    (&CredentialFieldComponents.descriptor_fields/1)
    |> render_component(
      method: snmp_v3_method(),
      form_name: Keyword.get(opts, :form_name, "credential_secret"),
      values: values,
      errors: Keyword.get(opts, :errors, %{})
    )
    |> LazyHTML.from_fragment()
  end

  defp new_credential_values, do: CredentialFieldComponents.values(snmp_v3_method(), %{}, true)

  defp snmp_v3_method do
    Enum.find(NativeDescriptors.snmp()["auth_methods"], &(&1["id"] == "v3"))
  end

  defp selected_values(document, form_name \\ "credential_secret") do
    Map.new(@protocol_fields, fn field ->
      selected = LazyHTML.query(document, "select##{form_name}_fields_#{field} option[selected]")
      {field, selected |> LazyHTML.attribute("value") |> Enum.reject(&(&1 == ""))}
    end)
  end

  defp option_label(document, field, value) do
    document
    |> LazyHTML.query(~s(select#credential_secret_fields_#{field} option[value="#{value}"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  defp password_inputs(document), do: LazyHTML.query(document, "input[type='password']")

  defp secret_form_params(fields) do
    %{
      "kind" => "descriptor",
      "provider" => "snmp",
      "auth_method" => "v3",
      "name" => "Core switches",
      "description" => "",
      "fields" => fields
    }
  end

  defp secret_form_socket do
    profile = NativeDescriptors.snmp()

    %Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        integration_profiles: %{"snmp" => profile},
        secret_descriptor: %{provider: "snmp", profile: profile, method: snmp_v3_method()}
      },
      private: %{live_temp: %{}}
    }
  end
end
