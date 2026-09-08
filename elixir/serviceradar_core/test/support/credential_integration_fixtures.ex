defmodule ServiceRadar.TestSupport.CredentialIntegrationFixtures do
  @moduledoc false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Plugins.Manifest

  @plugins_root Path.expand("../../../../go/cmd/wasm-plugins", __DIR__)

  # Resolved at RUNTIME, following AddonConfigContractFixtures.repo_root/0. The
  # compile-time constant is right under plain `mix`, which compiles in place,
  # but under Bazel mix_app compiles in its own build tree and the test then
  # runs in a sandbox holding only declared runfiles -- so the baked path points
  # at a directory that exists on the host and not in the sandbox. The manifests
  # are already declared inputs; only the path needed fixing.
  @spec plugins_root() :: Path.t()
  defp plugins_root do
    [
      System.get_env("SERVICERADAR_REPO_ROOT") &&
        Path.join(System.get_env("SERVICERADAR_REPO_ROOT"), "go/cmd/wasm-plugins"),
      @plugins_root,
      Path.expand("../../go/cmd/wasm-plugins", File.cwd!())
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(@plugins_root, &File.dir?/1)
  end

  @spec profile!(String.t(), String.t() | nil) :: map()
  def profile!(plugin_directory, provider \\ nil) do
    path = Path.join([plugins_root(), plugin_directory, "plugin.yaml"])
    manifest = path |> File.read!() |> Manifest.from_yaml() |> unwrap_manifest!(path)

    case Enum.find(manifest.integrations["credential_profiles"], fn profile ->
           is_nil(provider) or profile["provider"] == provider
         end) do
      nil -> raise "credential profile not found in #{path}"
      profile -> profile
    end
  end

  @doc """
  Creates a real `network_credential_secrets` row and returns it.

  Anything with a foreign key onto that table -- `ansible_controllers` and its
  sync/execution/callback columns, credential broker grants -- needs a row that
  actually exists. Seeding a generated UUID used to work only because nothing
  enforced the reference; it now fails with a foreign key violation, which is
  the constraint doing its job rather than a test to work around.
  """
  @spec secret!(keyword()) :: struct()
  def secret!(opts \\ []) do
    unique = System.unique_integer([:positive])
    actor = Keyword.get(opts, :actor) || SystemActor.system(:credential_integration_fixtures)

    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: Keyword.get(opts, :name, "fixture-secret-#{unique}"),
          provider: Keyword.get(opts, :provider, "test"),
          credential_kind: Keyword.get(opts, :credential_kind, :api_token),
          source_type: :internal_encrypted,
          secret_payload: Keyword.get(opts, :secret_payload, "token-#{unique}"),
          metadata: %{"fixture" => "credential_integration_fixtures"}
        },
        actor: actor
      )

    secret
  end

  @doc """
  The id of a freshly created secret, for callers that only need the reference.
  """
  @spec secret_id!(keyword()) :: String.t()
  def secret_id!(opts \\ []), do: secret!(opts).id

  @doc """
  The shipped manifest's `integrations` block as authored, before validation.

  `profile!/2` returns the validated output shape, which is not valid input to
  `IntegrationDescriptor.validate/2` (validation fills in empty lists that the
  input rejects). Tests that exercise validation itself need the authored map.
  """
  @spec raw_integrations!(String.t()) :: map()
  def raw_integrations!(plugin_directory) do
    path = Path.join([plugins_root(), plugin_directory, "plugin.yaml"])

    case path |> File.read!() |> Manifest.parse_yaml_map() do
      {:ok, %{"integrations" => integrations}} -> integrations
      {:ok, _map} -> raise "no integrations block in #{path}"
      {:error, errors} -> raise "invalid manifest yaml #{path}: #{inspect(errors)}"
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
