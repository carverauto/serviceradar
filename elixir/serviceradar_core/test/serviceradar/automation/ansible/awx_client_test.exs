defmodule ServiceRadar.Automation.Ansible.AwxClientTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Credentials.CredentialBrokerGrant

  defmodule FakeCommandBus do
    @moduledoc false

    def dispatch(agent_id, command_type, payload, opts) do
      send(opts[:test_pid], {:dispatch, agent_id, command_type, payload, opts})
      {:ok, %{id: "command-1", agent_id: agent_id, command_type: command_type}}
    end
  end

  defp controller(overrides \\ %{}) do
    base = %Controller{
      id: "ctrl-uuid-1",
      name: "Production AWX",
      base_url: "https://awx.example.com",
      agent_id: "agent-a",
      credential_secret_id: "018f3f56-1111-7222-8333-123456789abc",
      run_pulse_interval_ms: 2000,
      inventory_sync_interval_seconds: 300,
      catalog_sync_interval_seconds: 600,
      status: :unknown,
      metadata: %{}
    }

    Map.merge(base, overrides)
  end

  defp dispatch_opts,
    do: [command_bus: FakeCommandBus, test_pid: self(), grant_issuer: &fake_grant/1]

  defp fake_grant(attrs) do
    grant =
      attrs
      |> CredentialBrokerGrant.issue_attrs()
      |> Map.put(:id, "grant-1")

    {:ok, CredentialBrokerGrant.to_payload(grant)}
  end

  describe "dispatchability validation" do
    test "rejects controller with missing agent_id" do
      assert {:error, :controller_agent_id_missing} =
               AwxClient.ping(controller(%{agent_id: nil}), dispatch_opts())
    end

    test "rejects controller with missing credential_secret_id" do
      assert {:error, :controller_credential_missing} =
               AwxClient.ping(controller(%{credential_secret_id: nil}), dispatch_opts())
    end

    test "rejects controller with blank base_url" do
      assert {:error, :controller_base_url_missing} =
               AwxClient.ping(controller(%{base_url: ""}), dispatch_opts())
    end
  end

  describe "ping/2" do
    test "dispatches awx.ping with broker grant carrying secret_ref (no plaintext)" do
      assert {:ok, _cmd} = AwxClient.ping(controller(), dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.ping", payload, opts}

      assert payload["schema"] == "serviceradar.awx_command.v1"
      assert payload["verb"] == "awx.ping"
      assert payload["base_url"] == "https://awx.example.com"
      assert payload["controller_id"] == "ctrl-uuid-1"
      assert payload["args"] == %{}

      grant = payload["credential_broker"]
      assert grant["schema"] == "serviceradar.edge_credential_broker_grant.v1"
      assert grant["grant_id"] == "grant-1"
      assert grant["grant_type"] == "awx_oauth2_token"
      assert {:ok, _expires_at, 0} = DateTime.from_iso8601(grant["expires_at"])

      assert grant["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

      assert grant["inject"] == %{
               "type" => "http_header",
               "name" => "Authorization",
               "scheme" => "Bearer"
             }

      assert grant["allow"]["methods"] == ["GET"]
      assert grant["ttl_seconds"] == 300

      refute inspect(payload) =~ "Bearer "
      refute Map.has_key?(payload, "api_token")

      assert opts[:required_capability] == "http"
      assert opts[:source] == :automation
      assert opts[:context]["controller_id"] == "ctrl-uuid-1"
      assert opts[:context]["verb"] == "awx.ping"
    end
  end

  describe "list_inventories / list_projects / list_templates" do
    test "each verb dispatches with empty args and the GET allow-list" do
      for {fun, verb} <- [
            {:list_inventories, "awx.list_inventories"},
            {:list_projects, "awx.list_projects"},
            {:list_templates, "awx.list_templates"}
          ] do
        assert {:ok, _} = apply(AwxClient, fun, [controller(), dispatch_opts()])
        assert_receive {:dispatch, "agent-a", ^verb, payload, _opts}
        assert payload["args"] == %{}
        assert payload["credential_broker"]["allow"]["methods"] == ["GET"]
      end
    end
  end

  describe "list_hosts/3" do
    test "carries inventory_id in args" do
      assert {:ok, _} = AwxClient.list_hosts(controller(), 7, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.list_hosts", payload, _opts}
      assert payload["args"] == %{"inventory_id" => 7}
    end
  end

  describe "fetch_template/3" do
    test "carries template_id in args" do
      assert {:ok, _} = AwxClient.fetch_template(controller(), 42, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.fetch_template", payload, _opts}
      assert payload["args"] == %{"template_id" => 42}
    end
  end

  describe "launch_job/4" do
    test "happy path: extra_vars + host_limit + inventory_id all included; allow-list is POST" do
      launch_opts = %{
        extra_vars: %{"version" => "1.2.3"},
        host_limit: "web01,web02",
        inventory_id: 7
      }

      assert {:ok, _} = AwxClient.launch_job(controller(), 42, launch_opts, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}

      assert payload["args"] == %{
               "template_id" => 42,
               "extra_vars" => %{"version" => "1.2.3"},
               "host_limit" => "web01,web02",
               "inventory_id" => 7
             }

      assert payload["credential_broker"]["allow"]["methods"] == ["POST"]
    end

    test "omits empty / nil optional args" do
      assert {:ok, _} =
               AwxClient.launch_job(
                 controller(),
                 1,
                 %{extra_vars: %{}, host_limit: "", inventory_id: nil},
                 dispatch_opts()
               )

      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}
      assert payload["args"] == %{"template_id" => 1}
    end

    test "no launch_opts at all means just template_id" do
      assert {:ok, _} = AwxClient.launch_job(controller(), 1, %{}, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}
      assert payload["args"] == %{"template_id" => 1}
    end
  end

  describe "fetch_job/3" do
    test "carries job_id" do
      assert {:ok, _} = AwxClient.fetch_job(controller(), 7331, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.fetch_job", payload, _opts}
      assert payload["args"] == %{"job_id" => 7331}
    end
  end

  describe "cancel_job/3" do
    test "cancel uses POST allow-list" do
      assert {:ok, _} = AwxClient.cancel_job(controller(), 7331, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.cancel_job", payload, _opts}
      assert payload["args"] == %{"job_id" => 7331}
      assert payload["credential_broker"]["allow"]["methods"] == ["POST"]
    end
  end

  describe "fetch_events_for_jobs/3" do
    test "normalizes pairs into string-keyed maps for the plugin" do
      pairs = [
        %{job_id: 7331, since_id: 0},
        %{job_id: 7332, since_id: 142}
      ]

      assert {:ok, _} = AwxClient.fetch_events_for_jobs(controller(), pairs, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.fetch_events_for_jobs", payload, _opts}

      assert payload["args"] == %{
               "pairs" => [
                 %{"job_id" => 7331, "since_id" => 0},
                 %{"job_id" => 7332, "since_id" => 142}
               ]
             }
    end

    test "raises when pair entries are missing required keys" do
      assert_raise ArgumentError, fn ->
        AwxClient.fetch_events_for_jobs(controller(), [%{job_id: 1}], dispatch_opts())
      end
    end

    test "handles empty pair list" do
      assert {:ok, _} = AwxClient.fetch_events_for_jobs(controller(), [], dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.fetch_events_for_jobs", payload, _opts}
      assert payload["args"] == %{"pairs" => []}
    end
  end

  describe "inventory_sync_grant_template/1" do
    test "builds a stable grant template without persisted grant identity or expiry" do
      assert {:ok, payload} = AwxClient.inventory_sync_grant_template(controller())

      assert payload["schema"] == "serviceradar.edge_credential_broker_grant.v1"
      assert payload["grant_type"] == "awx_oauth2_token"

      assert payload["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

      assert payload["consumer"] == %{
               "kind" => "ansible",
               "id" => "ctrl-uuid-1",
               "purpose" => "awx.inventory_sync"
             }

      assert payload["target"]["agent_id"] == "agent-a"
      assert payload["allow"]["methods"] == ["GET"]
      refute Map.has_key?(payload, "grant_id")
      refute Map.has_key?(payload, "expires_at")
    end
  end

  describe "insecure_skip_verify" do
    test "is false by default" do
      assert {:ok, _} = AwxClient.ping(controller(), dispatch_opts())
      assert_receive {:dispatch, _, _, payload, _}
      assert payload["insecure_skip_verify"] == false
    end

    test "honors metadata['insecure_skip_verify'] = true" do
      ctrl = controller(%{metadata: %{"insecure_skip_verify" => true}})
      assert {:ok, _} = AwxClient.ping(ctrl, dispatch_opts())
      assert_receive {:dispatch, _, _, payload, _}
      assert payload["insecure_skip_verify"] == true
    end
  end

  describe "options forwarding" do
    test "caller-supplied opts override defaults" do
      assert {:ok, _} =
               AwxClient.ping(
                 controller(),
                 dispatch_opts() ++
                   [
                     ttl_seconds: 600,
                     context: %{"caller" => "RunPulseWorker", "controller_id" => "override"}
                   ]
               )

      assert_receive {:dispatch, _, _, _payload, opts}
      assert opts[:ttl_seconds] == 600
      assert opts[:context]["caller"] == "RunPulseWorker"
    end
  end
end
