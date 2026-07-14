defmodule ServiceRadarWebNGWeb.Components.PluginConfigFormTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.PluginConfigForm

  @moduletag :unit
  @moduletag :db_free

  test "renders fields from schema" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "title" => "Target URL"},
        "timeout" => %{"type" => "integer", "title" => "Timeout"}
      },
      "required" => ["url"]
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{"url" => "https://example.com", "timeout" => 10},
        base_name: "assignment[params]"
      })

    assert html =~ "Target URL"
    assert html =~ "Timeout"
    assert html =~ "assignment[params][url]"
    assert html =~ "assignment[params][timeout]"
  end

  test "renders secret-ref fields without echoing the stored value" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "password_secret_ref" => %{
          "type" => "string",
          "title" => "Password Secret",
          "secretRef" => true
        }
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{"password_secret_ref" => "secretref:password_secret_ref:abc123"},
        base_name: "assignment[params]"
      })

    assert html =~ "Password Secret"
    assert html =~ ~s(type="password")
    assert html =~ "Stored secret ref: secretref:password_secret_ref:abc123"
    refute html =~ ~s(value="secretref:password_secret_ref:abc123")
  end

  test "does not render internal broker fields" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "credential_broker" => %{
          "type" => "object",
          "title" => "Credential Broker",
          "x-serviceradar-internal" => true
        },
        "timeout_ms" => %{"type" => "integer", "title" => "Timeout"}
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{"credential_broker" => %{"credential_secret_ref" => "credentialref:secret"}, "timeout_ms" => 30_000},
        base_name: "assignment[params]"
      })

    assert html =~ "Timeout"
    refute html =~ "Credential Broker"
    refute html =~ "credential_secret_ref"
  end

  test "does not render reserved runtime fields from legacy schemas" do
    schema = %{
      "type" => "object",
      "title" => "Proxmox Console",
      "properties" => %{
        "console" => %{"type" => "object", "title" => "Console"},
        "credential_broker" => %{"type" => "object", "title" => "Credential Broker"},
        "credential_rule_id" => %{"type" => "string", "title" => "Credential Rule"},
        "timeout_ms" => %{"type" => "integer", "title" => "Timeout"}
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{},
        base_name: "assignment[params]"
      })

    assert html =~ "Timeout"
    assert html =~ "Open the configuration guide"
    refute html =~ "Credential Broker"
    refute html =~ "Credential Rule"
    refute html =~ ~s(assignment[params][console])
  end

  test "renders schema documentation link" do
    schema = %{
      "type" => "object",
      "x-serviceradar-docs-url" => "https://docs.serviceradar.cloud/docs/proxmox#console-access",
      "properties" => %{
        "timeout_ms" => %{"type" => "integer", "title" => "Timeout"}
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{},
        base_name: "assignment[params]"
      })

    assert html =~ "Open the configuration guide"
    assert html =~ "https://docs.serviceradar.cloud/docs/proxmox#console-access"
  end

  test "prefers package documentation and rejects unsafe schema links" do
    schema = %{
      "type" => "object",
      "x-serviceradar-docs-url" => "javascript:alert(1)",
      "properties" => %{}
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{},
        base_name: "assignment[params]",
        docs_url: "https://plugins.example.test/example-inventory/v1.0.0/configuration"
      })

    assert html =~ "https://plugins.example.test/example-inventory/v1.0.0/configuration"
    refute html =~ "javascript:alert(1)"
  end
end
