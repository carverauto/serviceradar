defmodule ServiceRadar.Credentials.CameraCredentialMaterializerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.PluginAssignmentMaterializer
  alias ServiceRadar.Credentials.ProviderProfiles.AxisProfile
  alias ServiceRadar.Credentials.ProviderProfiles.UnifiProtectProfile
  alias ServiceRadar.Plugins.PluginInputs

  defmodule FakeReconciler do
    @moduledoc false
    def reconcile(policy, input_defs, opts) do
      send(opts[:test_pid], {:reconcile, policy, input_defs, opts})

      {:ok, %{resolved_inputs: 1, desired_assignments: 1, upserted: 1, unchanged: 0, disabled: 0}}
    end
  end

  defp materialize(rule, profile, purpose, opts \\ []) do
    resolver =
      Keyword.get(opts, :username_resolver, fn _secret_id, _actor -> {:ok, "camadmin"} end)

    assert {:ok, _summary} =
             PluginAssignmentMaterializer.reconcile_rules([rule], "agent-cam", %{id: "pkg-cam"},
               reconciler: FakeReconciler,
               actor: %{id: "system"},
               profile: profile,
               purpose: purpose,
               username_resolver: resolver,
               test_pid: self()
             )

    assert_receive {:reconcile, policy, input_defs, reconcile_opts}
    {policy, input_defs, reconcile_opts}
  end

  defp camera_rule(attrs) do
    Map.merge(
      %{
        id: "cam-rule",
        secret_id: "018f3f56-aaaa-7bbb-8ccc-123456789abc",
        enabled: true,
        priority: 100,
        provider: "unifi-protect",
        auth_method: :username_password,
        purpose: :camera_inventory,
        target_query: "in:devices hostname:udm-*",
        tls_policy: :verify,
        scope_type: :agent,
        scope_value: "agent-cam",
        metadata: %{}
      },
      attrs
    )
  end

  test "unifi-protect username_password inventory rule injects host per target and bakes username" do
    rule = camera_rule(%{purpose: :camera_inventory})

    {policy, input_defs, _opts} = materialize(rule, UnifiProtectProfile, :camera_inventory)

    assert policy.policy_id == "network-credential-rule:cam-rule:camera_inventory"

    # Host is never inline: it flows through the SRQL devices input, per target.
    assert input_defs == [
             %{name: "targets", entity: "devices", query: "in:devices hostname:udm-*"}
           ]

    params = policy.params_template
    refute Map.has_key?(params, "host")
    refute Map.has_key?(params, "relay")

    assert params["password_secret_ref"] ==
             "credentialref:network-credential-secret:018f3f56-aaaa-7bbb-8ccc-123456789abc"

    assert params["username"] == "camadmin"
    refute Map.has_key?(params, "api_key_secret_ref")
    assert params["scheme"] == "https"
    assert params["rtsp_port"] == 7447
    assert params["bootstrap_path"] == "/proxy/protect/api/bootstrap"
    assert params["login_path"] == "/api/auth/login"
    assert params["credential_rule_id"] == "cam-rule"

    broker = params["credential_broker"]
    assert broker["schema"] == "serviceradar.edge_credential_broker_grant.v1"
    assert broker["grant_type"] == "unifi_protect_api"
    assert broker["resolution_location"] == "control_plane"
    assert broker["consumer"]["id"] == "unifi-protect-camera"
    assert broker["consumer"]["purpose"] == "camera_inventory"
  end

  test "unifi-protect api_key stream rule uses api_key_secret_ref and no username" do
    rule = camera_rule(%{auth_method: :api_key, purpose: :camera_stream})

    resolver = fn _secret_id, _actor -> flunk("username should not be resolved for api_key") end

    {policy, _input_defs, _opts} =
      materialize(rule, UnifiProtectProfile, :camera_stream, username_resolver: resolver)

    assert policy.policy_id == "network-credential-rule:cam-rule:camera_stream"

    params = policy.params_template
    refute Map.has_key?(params, "host")

    assert params["api_key_secret_ref"] ==
             "credentialref:network-credential-secret:018f3f56-aaaa-7bbb-8ccc-123456789abc"

    refute Map.has_key?(params, "password_secret_ref")
    refute Map.has_key?(params, "username")

    broker = params["credential_broker"]
    assert broker["consumer"]["id"] == "unifi-protect-camera-stream"
    assert broker["consumer"]["purpose"] == "camera_stream"
  end

  test "axis username_password inventory rule uses vapix grant and 554 rtsp port" do
    rule =
      camera_rule(%{
        provider: "axis",
        auth_method: :username_password,
        purpose: :camera_inventory,
        target_query: "in:devices vendor:axis"
      })

    {policy, _input_defs, _opts} = materialize(rule, AxisProfile, :camera_inventory)

    params = policy.params_template
    refute Map.has_key?(params, "host")
    assert params["scheme"] == "https"
    assert params["rtsp_port"] == 554

    assert params["password_secret_ref"] ==
             "credentialref:network-credential-secret:018f3f56-aaaa-7bbb-8ccc-123456789abc"

    assert params["username"] == "camadmin"

    broker = params["credential_broker"]
    assert broker["grant_type"] == "axis_vapix"
    assert broker["consumer"]["id"] == "axis-camera"
  end

  test "camera metadata overrides scheme/rtsp_port/timeout and tls skip-verify" do
    rule =
      camera_rule(%{
        tls_policy: :skip_verify,
        metadata: %{
          "scheme" => "http",
          "rtsp_port" => 8554,
          "timeout_ms" => 15_000,
          "bootstrap_path" => "/custom/bootstrap"
        }
      })

    {policy, _input_defs, _opts} = materialize(rule, UnifiProtectProfile, :camera_inventory)

    params = policy.params_template
    assert params["scheme"] == "http"
    assert params["rtsp_port"] == 8554
    assert params["timeout_ms"] == 15_000
    assert params["insecure_skip_verify"] == true
    assert params["bootstrap_path"] == "/custom/bootstrap"
  end

  test "materialized camera policy output validates against the plugin inputs planner payload" do
    rule = camera_rule(%{})

    {policy, _input_defs, _opts} = materialize(rule, UnifiProtectProfile, :camera_inventory)

    payload = %{
      "schema" => PluginInputs.schema_id(),
      "policy_id" => policy.policy_id,
      "policy_version" => policy.policy_version,
      "agent_id" => "agent-cam",
      "generated_at" => "2026-06-30T00:00:00Z",
      "template" => policy.params_template,
      "inputs" => [
        %{
          "name" => "targets",
          "entity" => "devices",
          "query" => "in:devices hostname:udm-*",
          "chunk_index" => 0,
          "chunk_total" => 1,
          "chunk_hash" => String.duplicate("a", 64),
          "items" => [%{"uid" => "sr:device:1", "ip" => "192.0.2.20", "hostname" => "udm-1"}]
        }
      ]
    }

    assert :ok = PluginInputs.validate(payload)
  end
end
