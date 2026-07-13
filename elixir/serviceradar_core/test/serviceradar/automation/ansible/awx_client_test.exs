defmodule ServiceRadar.Automation.Ansible.AwxClientTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Edge.AgentCommandBus

  @callback_command_id "018f3f56-aaaa-4bbb-8ccc-123456789abc"

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

  defp callback_credential_binding(overrides \\ %{}) do
    Map.merge(
      %{
        envelope_ref: "launch-envelope:v1:abcdefghijklmnopqrstuvwxyz012345",
        child_execution_id: "018f3f56-1111-7222-8333-123456789abc",
        inventory_id: 7,
        job_template_id: 42,
        credential_type_id: 91,
        organization_id: 2,
        credential_slot: "ssh_ca_callback",
        injector_sha256: String.duplicate("a", 64)
      },
      overrides
    )
  end

  defp callback_credential_cleanup_binding(overrides \\ %{}) do
    overrides
    |> callback_credential_binding()
    |> Map.delete(:envelope_ref)
  end

  defp callback_dispatch_opts, do: dispatch_opts() ++ [command_id: @callback_command_id]

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

      # The dispatch capability gate was dropped (agents don't advertise an
      # "http" capability; the gate only blocked dispatch) — see 28090014c.
      assert opts[:required_capability] == nil
      assert opts[:source] == :automation
      assert opts[:context]["controller_id"] == "ctrl-uuid-1"
      assert opts[:context]["verb"] == "awx.ping"
    end
  end

  describe "list_inventories / list_projects / list_templates / current_user" do
    test "each verb dispatches with empty args and the GET allow-list" do
      for {fun, verb} <- [
            {:list_inventories, "awx.list_inventories"},
            {:list_projects, "awx.list_projects"},
            {:list_templates, "awx.list_templates"},
            {:current_user, "awx.current_user"}
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

  describe "list_inventory_groups/3" do
    test "carries inventory_id in args" do
      assert {:ok, _} = AwxClient.list_inventory_groups(controller(), 7, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.list_inventory_groups", payload, _opts}
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

    test "passes reviewed immutable execution fields" do
      launch_opts = %{
        credential_ids: [5, 9],
        execution_environment_id: 12,
        job_type: "check",
        diff_mode: true,
        verbosity: 2,
        forks: 10,
        job_slice_count: 1,
        timeout: 600,
        job_tags: "preflight,enroll",
        skip_tags: "destructive",
        labels: [4],
        instance_group_ids: [8]
      }

      assert {:ok, _} = AwxClient.launch_job(controller(), 42, launch_opts, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}

      assert payload["args"] == %{
               "template_id" => 42,
               "credential_ids" => [5, 9],
               "execution_environment_id" => 12,
               "job_type" => "check",
               "diff_mode" => true,
               "verbosity" => 2,
               "forks" => 10,
               "job_slice_count" => 1,
               "timeout" => 600,
               "job_tags" => "preflight,enroll",
               "skip_tags" => "destructive",
               "labels" => [4],
               "instance_group_ids" => [8]
             }
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

  describe "ephemeral callback credentials" do
    test "create carries only an opaque envelope binding and exact credential endpoint grant" do
      assert {:ok, _} =
               AwxClient.create_callback_credential(
                 controller(),
                 callback_credential_binding(),
                 callback_dispatch_opts()
               )

      assert_receive {:dispatch, "agent-a", "awx.create_callback_credential", payload, opts}
      assert opts[:command_id] == @callback_command_id

      assert payload["args"] == %{
               "credential_type_id" => 91,
               "organization_id" => 2,
               "credential_name" => "sr-callback-018f3f56-1111-7222-8333-123456789abc",
               "injector_sha256" => String.duplicate("a", 64)
             }

      assert payload["callback_credential_binding"] == %{
               "schema" => "serviceradar.awx_callback_credential_binding.v1",
               "envelope_ref" => "launch-envelope:v1:abcdefghijklmnopqrstuvwxyz012345",
               "dispatch_agent_id" => "agent-a",
               "controller_id" => "ctrl-uuid-1",
               "child_execution_id" => "018f3f56-1111-7222-8333-123456789abc",
               "inventory_id" => 7,
               "job_template_id" => 42,
               "credential_type_id" => 91,
               "organization_id" => 2,
               "credential_name" => "sr-callback-018f3f56-1111-7222-8333-123456789abc",
               "credential_slot" => "ssh_ca_callback",
               "injector_sha256" => String.duplicate("a", 64)
             }

      grant = payload["credential_broker"]
      assert grant["allow"]["methods"] == ["GET", "POST"]

      assert grant["allow"]["paths"] == [
               "=/api/v2/credential_types/91/",
               "=/api/v2/credentials/"
             ]

      serialized = inspect(payload)
      refute serialized =~ "callback_grant"
      refute serialized =~ "idempotency_key"
      refute serialized =~ "user_token"
      refute serialized =~ "Bearer "
    end

    test "delete is exact-ID scoped and carries deterministic cleanup identity" do
      assert {:ok, _} =
               AwxClient.delete_callback_credential(
                 controller(),
                 401,
                 callback_credential_cleanup_binding(),
                 dispatch_opts()
               )

      assert_receive {:dispatch, "agent-a", "awx.delete_callback_credential", payload, _opts}

      assert payload["args"] == %{
               "credential_id" => 401,
               "credential_type_id" => 91,
               "organization_id" => 2,
               "credential_name" => "sr-callback-018f3f56-1111-7222-8333-123456789abc"
             }

      assert payload["credential_broker"]["allow"] == %{
               "hosts" => ["awx.example.com"],
               "methods" => ["GET", "DELETE"],
               "paths" => ["=/api/v2/credentials/401/"]
             }

      assert payload["callback_credential_binding"] == %{
               "schema" => "serviceradar.awx_callback_credential_cleanup_binding.v1",
               "dispatch_agent_id" => "agent-a",
               "controller_id" => "ctrl-uuid-1",
               "child_execution_id" => "018f3f56-1111-7222-8333-123456789abc",
               "inventory_id" => 7,
               "job_template_id" => 42,
               "credential_type_id" => 91,
               "organization_id" => 2,
               "credential_name" => "sr-callback-018f3f56-1111-7222-8333-123456789abc",
               "credential_slot" => "ssh_ca_callback",
               "injector_sha256" => String.duplicate("a", 64)
             }

      refute Map.has_key?(payload["callback_credential_binding"], "envelope_ref")
      refute inspect(payload) =~ "launch-envelope:"
    end

    test "delete rejects a launch envelope or any unreviewed cleanup binding field" do
      for invalid <- [
            callback_credential_binding(),
            Map.put(callback_credential_cleanup_binding(), :envelope_ref, "opaque-ref"),
            Map.put(callback_credential_cleanup_binding(), :callback_grant, "must-not-pass")
          ] do
        assert {:error, :invalid_callback_credential_binding} =
                 AwxClient.delete_callback_credential(controller(), 401, invalid, dispatch_opts())

        refute_received {:dispatch, _, _, _, _}
      end
    end

    test "requires exact reviewed binding including explicit organization" do
      for invalid <- [
            callback_credential_binding(%{organization_id: nil}),
            callback_credential_binding(%{credential_type_id: 0}),
            callback_credential_binding(%{credential_slot: "arbitrary"}),
            callback_credential_binding(%{injector_sha256: "moving"}),
            Map.put(callback_credential_binding(), :callback_grant, "must-not-pass")
          ] do
        assert {:error, :invalid_callback_credential_binding} =
                 AwxClient.create_callback_credential(
                   controller(),
                   invalid,
                   callback_dispatch_opts()
                 )

        refute_received {:dispatch, _, _, _, _}
      end
    end

    test "create requires the command ID sealed into the launch envelope" do
      assert {:error, :preallocated_callback_command_id_required} =
               AwxClient.create_callback_credential(
                 controller(),
                 callback_credential_binding(),
                 dispatch_opts()
               )

      refute_received {:dispatch, _, _, _, _}
    end

    test "command bus reserves explicit IDs for callback credential creation" do
      assert {:error, :preallocated_command_id_required} =
               AgentCommandBus.dispatch(
                 "agent-a",
                 "awx.create_callback_credential",
                 %{}
               )

      assert {:error, :invalid_command_id} =
               AgentCommandBus.dispatch(
                 "agent-a",
                 "awx.create_callback_credential",
                 %{},
                 command_id: "not-a-uuid"
               )

      assert {:error, :preallocated_callback_attempt_context_required} =
               AgentCommandBus.dispatch(
                 "agent-a",
                 "awx.launch_job",
                 %{},
                 command_id: @callback_command_id
               )
    end

    test "returned credential ID remains an ordinary reviewed launch credential ID" do
      assert {:ok, _} =
               AwxClient.launch_job(
                 controller(),
                 42,
                 %{credential_ids: [5, 401]},
                 dispatch_opts()
               )

      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}
      assert payload["args"]["credential_ids"] == [5, 401]
    end
  end

  describe "fetch_job/3" do
    test "carries job_id" do
      assert {:ok, _} = AwxClient.fetch_job(controller(), 7331, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.fetch_job", payload, _opts}
      assert payload["args"] == %{"job_id" => 7331}
    end
  end

  describe "fetch_job_host_summaries/3" do
    test "carries job_id and a bounded default" do
      assert {:ok, _} = AwxClient.fetch_job_host_summaries(controller(), 7331, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.fetch_job_host_summaries", payload, _opts}
      assert payload["args"] == %{"job_id" => 7331, "max_hosts" => 1_000}
    end

    test "accepts an exact upper bound for scope verification" do
      assert {:ok, _} =
               AwxClient.fetch_job_host_summaries(controller(), 7331, 3, dispatch_opts())

      assert_receive {:dispatch, "agent-a", "awx.fetch_job_host_summaries", payload, _opts}
      assert payload["args"] == %{"job_id" => 7331, "max_hosts" => 3}
    end
  end

  describe "list_recent_jobs/3" do
    test "requires exact controller integration identity and bounded window" do
      filters = %{
        template_id: 42,
        inventory_id: 7,
        created_by_id: 11,
        created_after: "2026-07-12T20:00:00Z",
        page_size: 25
      }

      assert {:ok, _} = AwxClient.list_recent_jobs(controller(), filters, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.list_recent_jobs", payload, _opts}

      assert payload["args"] == %{
               "template_id" => 42,
               "inventory_id" => 7,
               "created_by_id" => 11,
               "created_after" => "2026-07-12T20:00:00Z",
               "page_size" => 25
             }
    end

    test "rejects absent identity and oversized enumeration" do
      assert_raise ArgumentError, fn ->
        AwxClient.list_recent_jobs(
          controller(),
          %{template_id: 42, inventory_id: 7, created_after: "2026-07-12T20:00:00Z"},
          dispatch_opts()
        )
      end

      assert_raise ArgumentError, fn ->
        AwxClient.list_recent_jobs(
          controller(),
          %{
            template_id: 42,
            inventory_id: 7,
            created_by_id: 11,
            created_after: "2026-07-12T20:00:00Z",
            page_size: 101
          },
          dispatch_opts()
        )
      end
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
