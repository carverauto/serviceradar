defmodule ServiceRadar.Credentials.PluginAssignmentMaterializerDryRunTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.PluginAssignmentMaterializer

  @secret_id "018f3f56-aaaa-7bbb-8ccc-123456789abc"

  defmodule FakeResolver do
    @moduledoc false
    def resolve(input_defs, opts) do
      send(opts[:test_pid], {:resolve, input_defs})
      rows = Keyword.get(opts, :fake_rows, [])
      {:ok, [%{name: "targets", entity: "devices", rows: rows}]}
    end
  end

  defp camera_rule(attrs) do
    Map.merge(
      %{
        id: "cam-rule",
        name: "Cameras",
        secret_id: @secret_id,
        enabled: true,
        priority: 100,
        provider: "unifi-protect",
        auth_method: :api_key,
        purpose: :camera_inventory,
        target_query: "in:devices hostname:udm-*",
        tls_policy: :verify,
        scope_type: :agent,
        scope_value: "agent-cam",
        metadata: %{"purposes" => ["camera_inventory", "camera_stream"]}
      },
      attrs
    )
  end

  defp dry_run(rule, opts \\ []) do
    PluginAssignmentMaterializer.dry_run_rule(
      rule,
      Keyword.merge(
        [
          resolver: FakeResolver,
          actor: %{id: "operator"},
          plugin_package: %{id: "pkg-cam"},
          username_resolver: fn _secret_id, _actor -> {:ok, "camadmin"} end,
          test_pid: self()
        ],
        opts
      )
    )
  end

  test "renders per-purpose redacted templates and resolved targets" do
    rows = [%{"uid" => "dev-1", "ip" => "10.0.0.5", "agent_id" => "agent-cam"}]

    assert {:ok, result} = dry_run(camera_rule(%{}), fake_rows: rows)

    assert result.rule_id == "cam-rule"
    assert result.provider == "unifi-protect"
    assert result.target_query == "in:devices hostname:udm-*"
    assert result.targets == %{total: 1, sample: rows, truncated?: false}

    assert_receive {:resolve,
                    [%{name: "targets", entity: "devices", query: "in:devices hostname:udm-*"}]}

    assert [inventory, stream] = result.purposes
    assert inventory.purpose == :camera_inventory
    assert inventory.plugin_id == "unifi-protect-camera"
    assert inventory.policy_id == "network-credential-rule:cam-rule:camera_inventory"
    assert inventory.package_found?
    assert inventory.enabled

    assert stream.purpose == :camera_stream
    assert stream.plugin_id == "unifi-protect-camera-stream"

    params = inventory.params_template
    refute Map.has_key?(params, "host")
    assert params["api_key_secret_ref"] == "credentialref:network-credential-secret:#{@secret_id}"

    # The grant is ephemeral (never persisted) and its id is masked for display.
    assert params["credential_broker"]["grant_id"] == "(issued at materialization)"
  end

  test "output contains no secret material and is redaction-stable" do
    assert {:ok, result} =
             %{auth_method: :username_password}
             |> camera_rule()
             |> dry_run(fake_rows: [])

    for entry <- result.purposes do
      params = entry.params_template

      # Username is public; the password never appears — only the secret ref.
      assert params["username"] == "camadmin"
      assert String.starts_with?(params["password_secret_ref"], "credentialref:")

      # Redaction fixpoint: redacting the rendered output changes nothing,
      # i.e. nothing sensitive survived rendering.
      assert CredentialRedactor.redact(params) == params

      encoded = Jason.encode!(params)
      refute encoded =~ "PVEAPIToken="
      refute encoded =~ "PRIVATE KEY"
    end
  end

  test "bounds the resolved target list" do
    rows = for i <- 1..60, do: %{"uid" => "dev-#{i}", "agent_id" => "agent-cam"}

    assert {:ok, result} = dry_run(camera_rule(%{}), fake_rows: rows, target_limit: 50)

    assert result.targets.total == 60
    assert length(result.targets.sample) == 50
    assert result.targets.truncated?
  end

  test "scopes resolved targets before rendering the dry-run sample" do
    rows = [
      %{"uid" => "dev-1", "hostname" => "cam-a", "agent_id" => "agent-cam"},
      %{"uid" => "dev-2", "hostname" => "cam-b", "agent_id" => "other-agent"}
    ]

    assert {:ok, result} = dry_run(camera_rule(%{}), fake_rows: rows)

    assert result.targets.total == 1
    assert [%{"hostname" => "cam-a"}] = result.targets.sample
    refute inspect(result.targets.sample) =~ "cam-b"
  end

  test "unknown provider is an error" do
    assert {:error, {:unknown_credential_provider, "nope"}} =
             dry_run(camera_rule(%{provider: "nope"}))
  end

  test "api_key rules never resolve a username" do
    resolver = fn _secret_id, _actor -> flunk("username must not be resolved for api_key") end

    assert {:ok, result} =
             dry_run(camera_rule(%{auth_method: :api_key}), username_resolver: resolver)

    for entry <- result.purposes do
      refute Map.has_key?(entry.params_template, "username")
      refute Map.has_key?(entry.params_template, "password_secret_ref")
    end
  end

  test "static unifi controller host is visible in dry-run templates" do
    assert {:ok, result} =
             dry_run(camera_rule(%{metadata: %{"host" => "protect-controller.local"}}),
               fake_rows: [%{"uid" => "camera-1", "ip" => "10.40.1.25"}]
             )

    for entry <- result.purposes do
      assert entry.params_template["host"] == "protect-controller.local"
    end
  end
end
