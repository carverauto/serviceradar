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
        "webhook_url" => %{
          "type" => "string",
          "title" => "Webhook URL",
          "secretRef" => true
        }
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{"webhook_url" => "secretref:webhook_url:abc123"},
        base_name: "assignment[params]"
      })

    assert html =~ "Webhook URL"
    assert html =~ ~s(type="password")
    assert html =~ "Stored secret ref: secretref:webhook_url:abc123"
    refute html =~ ~s(value="secretref:webhook_url:abc123")
  end

  test "does not render assignment-owned password or API-key secret refs" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "password_secret_ref" => %{
          "type" => "string",
          "title" => "Password Secret",
          "secretRef" => true
        },
        "api_key_secret_ref" => %{
          "type" => "string",
          "title" => "API Key Secret",
          "secretRef" => true
        },
        "timeout_ms" => %{"type" => "integer", "title" => "Timeout"}
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{
          "password_secret_ref" => "secretref:password_secret_ref:abc123",
          "api_key_secret_ref" => "secretref:api_key_secret_ref:def456"
        },
        base_name: "assignment[params]"
      })

    assert html =~ "Timeout"
    refute html =~ "Password Secret"
    refute html =~ "API Key Secret"
    refute html =~ ~s(assignment[params][password_secret_ref])
    refute html =~ ~s(assignment[params][api_key_secret_ref])
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

  test "renders OpenText NOM schema docs and wrapper help text" do
    schema = opentext_nom_schema_path() |> File.read!() |> Jason.decode!()

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{},
        base_name: "credential_rule[plugin_config]"
      })

    assert html =~ "Open the configuration guide"
    assert html =~ "https://docs.serviceradar.cloud/docs/opentext-nom"
    assert html =~ "Automation wrapper URL"
    assert html =~ "https://na.example.com/nom/api/automation/v1/wrapper"
    assert html =~ "https://nnm.example.com:443"
    assert html =~ "Advanced settings (optional)"
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

  test "advanced fields stay in a DetailsState disclosure so typing does not collapse it" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "enabled" => %{"type" => "boolean", "title" => "Enabled"},
        "capture_interfaces" => %{
          "type" => "array",
          "title" => "Capture interfaces",
          "items" => %{"type" => "string"},
          "x-serviceradar-ui-advanced" => true
        }
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{"enabled" => true},
        base_name: "profile[params]"
      })

    assert html =~ ~s(id="profile-params-advanced-settings")
    assert html =~ ~s(phx-hook="DetailsState")
    assert html =~ "Advanced settings (optional)"
    assert html =~ "Capture interfaces"
    assert html =~ ~s(name="profile[params][capture_interfaces]")
  end

  test "JSON Schema prefix patterns become HTML full-string prefix matches" do
    schema = %{
      "type" => "object",
      "required" => ["api_url"],
      "properties" => %{
        "api_url" => %{
          "type" => "string",
          "format" => "uri",
          "title" => "Automation wrapper URL",
          "pattern" => "^https://"
        },
        "instance_id" => %{
          "type" => "string",
          "title" => "OpenText NOM instance ID",
          "pattern" => "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
        }
      }
    }

    html =
      render_component(&PluginConfigForm.plugin_config_fields/1, %{
        schema: schema,
        params: %{"api_url" => "https://na.example.com/nom/api/automation/v1/wrapper"},
        base_name: "assignment[params]"
      })

    assert html =~ ~s(type="url")
    assert html =~ ~s(pattern="https://.*")
    refute html =~ ~s(pattern="^https://")
    assert html =~ ~s(pattern="[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
  end

  defp opentext_nom_schema_path do
    relative = "go/cmd/wasm-plugins/opentext-nom/config.schema.json"

    Enum.find(
      [
        Path.expand("../../../../../" <> relative, __DIR__),
        Path.join(File.cwd!(), relative),
        Path.join([
          System.get_env("TEST_SRCDIR") || "",
          System.get_env("TEST_WORKSPACE") || "_main",
          relative
        ])
      ],
      &File.exists?/1
    ) ||
      raise """
      OpenText NOM config.schema.json was not staged. Declare \
      //go/cmd/wasm-plugins/opentext-nom:config.schema.json as test data.
      """
  end
end
