defmodule ServiceRadar.TestSupport.CredentialIntegrationFixtures do
  @moduledoc false

  alias ServiceRadar.Plugins.Manifest

  @plugins_root Path.expand("../../../../go/cmd/wasm-plugins", __DIR__)

  @spec profile!(String.t(), String.t() | nil) :: map()
  def profile!(plugin_directory, provider \\ nil) do
    path = Path.join([@plugins_root, plugin_directory, "plugin.yaml"])
    manifest = path |> File.read!() |> Manifest.from_yaml() |> unwrap_manifest!(path)

    case Enum.find(manifest.integrations["credential_profiles"], fn profile ->
           is_nil(provider) or profile["provider"] == provider
         end) do
      nil -> raise "credential profile not found in #{path}"
      profile -> profile
    end
  end

  @spec catalog([map()]) :: map()
  def catalog(profiles), do: %{credential_profiles: profiles, inventory_sources: []}

  @spec target_policy_profile(keyword()) :: map()
  def target_policy_profile(opts \\ []) do
    provider = Keyword.get(opts, :provider, "example-network")
    plugin_id = Keyword.get(opts, :plugin_id, "example-network-inventory")

    %{
      "provider" => provider,
      "label" => "Example Network",
      "auth_methods" => [
        %{
          "id" => "api_token",
          "label" => "API token",
          "credential_kind" => "api_token",
          "fields" => [
            %{
              "id" => "token",
              "label" => "Token",
              "control" => "password",
              "required" => true,
              "secret" => true,
              "public" => false
            }
          ],
          "payload" => %{"format" => "scalar", "field" => "token"},
          "tls_policies" => ["verify"],
          "ssh_host_key_policies" => []
        },
        %{
          "id" => "username_password",
          "label" => "Username and password",
          "credential_kind" => "username_password",
          "fields" => [
            %{
              "id" => "username",
              "label" => "Username",
              "control" => "text",
              "required" => true,
              "secret" => false,
              "public" => true
            },
            %{
              "id" => "password",
              "label" => "Password",
              "control" => "password",
              "required" => true,
              "secret" => true,
              "public" => false
            }
          ],
          "payload" => %{
            "format" => "scalar",
            "field" => "password",
            "username_field" => "username"
          },
          "tls_policies" => [],
          "ssh_host_key_policies" => []
        }
      ],
      "purposes" => ["device_inventory", "configuration_read"],
      "scope_types" => ["agent", "gateway", "partition"],
      "rule_defaults" => %{
        "auth_method" => "api_token",
        "purposes" => ["device_inventory"],
        "target_query" => "in:devices vendor:Example",
        "scope_type" => "agent",
        "tls_policy" => "verify"
      },
      "rule_controls" => %{"target_query" => true, "transport" => true},
      "supports_rules" => true,
      "provisioning" => %{
        "mode" => "target_policy",
        "consumers" => [
          %{
            "purpose" => "device_inventory",
            "plugin_id" => plugin_id,
            "auth_methods" => ["api_token"],
            "constraints" => %{
              "tls_policies" => ["verify"],
              "ssh_host_key_policies" => []
            },
            "failure_mode" => "skip",
            "grant" => %{
              "grant_type" => "example_api",
              "resolution_location" => "agent",
              "ttl_seconds" => 300,
              "inject" => %{
                "type" => "http_header",
                "name" => "Authorization",
                "scheme" => "Bearer"
              },
              "allow" => %{
                "methods" => ["GET"],
                "paths" => ["/api/devices"],
                "hosts" => [],
                "ports" => [443]
              },
              "payload" => %{}
            },
            "params" => %{
              "credential_broker" => %{"$source" => "grant"},
              "credential_secret_ref" => %{"$source" => "secret_ref"},
              "timeout_ms" => %{
                "$source" => "metadata",
                "key" => "timeout_ms",
                "type" => "integer",
                "default" => 30_000
              },
              "credential_rule_id" => %{"$source" => "rule", "field" => "id"}
            }
          },
          %{
            "purpose" => "configuration_read",
            "plugin_id" => "example-network-config",
            "auth_methods" => ["username_password"],
            "constraints" => %{"tls_policies" => [], "ssh_host_key_policies" => []},
            "failure_mode" => "error",
            "grant" => %{
              "grant_type" => "example_config",
              "resolution_location" => "control_plane",
              "ttl_seconds" => 300,
              "inject" => %{},
              "allow" => %{"methods" => [], "paths" => [], "hosts" => [], "ports" => []},
              "payload" => %{}
            },
            "params" => %{
              "credential_broker" => %{"$source" => "grant"},
              "password_secret_ref" => %{"$source" => "secret_ref"},
              "username" => %{"$source" => "public_username"},
              "credential_rule_id" => %{"$source" => "rule", "field" => "id"}
            }
          }
        ]
      }
    }
  end

  defp unwrap_manifest!({:ok, manifest}, _path), do: manifest

  defp unwrap_manifest!({:error, errors}, path),
    do: raise("invalid manifest #{path}: #{inspect(errors)}")
end
