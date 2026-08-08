defmodule ServiceRadar.Credentials.PluginAssignmentMaterializerDryRunTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @secret_id "018f3f56-aaaa-7bbb-8ccc-123456789abc"

  defmodule FakeResolver do
    @moduledoc false

    def resolve(input_defs, opts) do
      send(opts[:test_pid], {:resolve, input_defs})
      {:ok, [%{name: "targets", entity: "devices", rows: Keyword.get(opts, :fake_rows, [])}]}
    end
  end

  test "renders a package-declared purpose and bounded target sample" do
    rows = [%{"uid" => "dev-1", "ip" => "10.0.0.5", "agent_id" => "agent-a"}]

    assert {:ok, result} = dry_run(rule(%{}), fake_rows: rows)
    assert result.provider == "example-network"
    assert result.targets == %{total: 1, sample: rows, truncated?: false}

    assert_receive {:resolve,
                    [%{name: "targets", entity: "devices", query: "in:devices vendor:Example"}]}

    assert [inventory] = result.purposes
    assert inventory.purpose == "device_inventory"
    assert inventory.plugin_id == "example-network-inventory"
    assert inventory.package_found?

    params = inventory.params_template

    assert params["credential_secret_ref"] ==
             "credentialref:network-credential-secret:#{@secret_id}"

    assert params["credential_broker"]["grant_id"] == "(issued at materialization)"
  end

  test "public username is rendered without exposing secret material" do
    rule =
      rule(%{
        auth_method: "username_password",
        purpose: "configuration_read",
        metadata: %{"purposes" => ["configuration_read"]}
      })

    assert {:ok, result} = dry_run(rule)
    assert [configuration] = result.purposes
    params = configuration.params_template
    assert params["username"] == "operator"
    assert String.starts_with?(params["password_secret_ref"], "credentialref:")
    assert CredentialRedactor.redact(params) == params

    encoded = Jason.encode!(params)
    refute encoded =~ "password-value"
    refute encoded =~ "PRIVATE KEY"
  end

  test "bounds and scope-filters resolved targets" do
    rows =
      for i <- 1..60 do
        %{"uid" => "dev-#{i}", "agent_id" => if(i == 60, do: "agent-b", else: "agent-a")}
      end

    assert {:ok, result} = dry_run(rule(%{}), fake_rows: rows, target_limit: 50)
    assert result.targets.total == 59
    assert length(result.targets.sample) == 50
    assert result.targets.truncated?
  end

  test "unknown provider is rejected by the package catalog" do
    assert {:error, {:unknown_credential_provider, "nope"}} = dry_run(rule(%{provider: "nope"}))
  end

  test "auth methods that do not reference public_username do not resolve it" do
    resolver = fn _secret_id, _actor -> flunk("username must not be resolved") end
    assert {:ok, result} = dry_run(rule(%{}), username_resolver: resolver)
    refute Map.has_key?(hd(result.purposes).params_template, "username")
  end

  defp dry_run(rule, opts \\ []) do
    profile = CredentialIntegrationFixtures.target_policy_profile()

    PluginAssignmentMaterializer.dry_run_rule(
      rule,
      Keyword.merge(
        [
          resolver: FakeResolver,
          actor: %{id: "operator"},
          plugin_package: %{id: "pkg-example"},
          integration_catalog: CredentialIntegrationFixtures.catalog([profile]),
          username_resolver: fn _secret_id, _actor -> {:ok, "operator"} end,
          test_pid: self()
        ],
        opts
      )
    )
  end

  defp rule(attrs) do
    Map.merge(
      %{
        id: "rule-1",
        name: "Example inventory",
        secret_id: @secret_id,
        enabled: true,
        priority: 100,
        provider: "example-network",
        auth_method: "api_token",
        purpose: "device_inventory",
        target_query: "in:devices vendor:Example",
        tls_policy: :verify,
        scope_type: :agent,
        scope_value: "agent-a",
        metadata: %{"purposes" => ["device_inventory"]}
      },
      attrs
    )
  end
end
