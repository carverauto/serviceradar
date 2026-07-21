defmodule ServiceRadar.Automation.Ansible.AwxClientTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Edge.AgentCommandBus

  @callback_command_id "018f3f56-aaaa-4bbb-8ccc-123456789abc"
  @preflight_controller_id "018f3f56-0000-7222-8333-123456789abc"
  @preflight_membership_id "018f3f56-1111-7222-8333-123456789abc"

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
      credential_secret_id: "018f3f56-0000-7222-8333-123456789abc",
      sync_credential_secret_id: "018f3f56-1111-7222-8333-123456789abc",
      execution_credential_secret_id: "018f3f56-2222-7222-8333-123456789abc",
      callback_credential_secret_id: "018f3f56-3333-7222-8333-123456789abc",
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

  defp preflight_controller, do: controller(%{id: @preflight_controller_id})

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

  defp launch_preflight_request(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "serviceradar.awx_launch_preflight_request.v1",
        "controller_id" => @preflight_controller_id,
        "template_id" => "42",
        "project_id" => "73",
        "inventory_id" => "7",
        "credential_ids" => ["5", "91"],
        "execution_environment_id" => "14",
        "selected_hosts" => [
          %{
            "membership_id" => @preflight_membership_id,
            "controller_id" => @preflight_controller_id,
            "inventory_id" => "7",
            "awx_host_id" => "101",
            "canonical_device_uid" => "sr:device-101",
            "host_name" => "node-101",
            "ansible_host" => "192.168.2.101",
            "enabled" => true,
            "membership_generation" => "9",
            "source_fingerprint" => "sha256:" <> String.duplicate("a", 64)
          }
        ]
      },
      overrides
    )
  end

  describe "dispatchability validation" do
    test "rejects controller with missing agent_id" do
      assert {:error, :controller_agent_id_missing} =
               AwxClient.ping(controller(%{agent_id: nil}), dispatch_opts())
    end

    test "rejects controller with no sync credential or legacy compatibility reference" do
      assert {:error, {:controller_credential_missing, :sync}} =
               AwxClient.ping(
                 controller(%{sync_credential_secret_id: nil, credential_secret_id: nil}),
                 dispatch_opts()
               )
    end

    test "rejects controller with blank base_url" do
      assert {:error, :controller_base_url_missing} =
               AwxClient.ping(controller(%{base_url: ""}), dispatch_opts())
    end

    test "normalizes the controller origin and pins every grant to its effective port" do
      ctrl = controller(%{base_url: "  HTTPS://AWX.EXAMPLE.COM:8443/  "})

      assert {:ok, _} = AwxClient.ping(ctrl, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.ping", payload, _opts}

      assert payload["base_url"] == "https://awx.example.com:8443"

      assert payload["credential_broker"]["allow"] == %{
               "hosts" => ["awx.example.com"],
               "methods" => ["GET"],
               "paths" => ["=/api/v2/ping/"],
               "ports" => [8443],
               "schemes" => ["https"]
             }
    end

    test "derives default HTTPS and HTTP ports from valid origin-only URLs" do
      for {base_url, normalized, scheme, port} <- [
            {"https://awx.example.com", "https://awx.example.com", "https", 443},
            {"http://awx.internal", "http://awx.internal", "http", 80}
          ] do
        assert {:ok, scope} = AwxClient.broker_scope(base_url, "awx.ping", %{})
        assert scope.base_url == normalized
        assert scope.allowed_schemes == [scheme]
        assert scope.allowed_ports == [port]
        assert scope.allow["schemes"] == [scheme]
        assert scope.allow["ports"] == [port]
      end
    end

    test "rejects malformed controller origins before grant issuance or dispatch" do
      test_pid = self()

      issuer = fn _attrs ->
        send(test_pid, :grant_issued)
        flunk("grant issuer must not run for a malformed controller origin")
      end

      opts = Keyword.put(dispatch_opts(), :grant_issuer, issuer)

      for base_url <- [
            "awx.example.com",
            "ftp://awx.example.com",
            "https://:443",
            "https://user@awx.example.com",
            "https://awx.example.com/controller",
            "https://awx.example.com?tenant=prod",
            "https://awx.example.com#fragment",
            "https://awx.example.com:0",
            "https://awx.example.com:65536",
            "https://awx.example.com:not-a-port",
            "https://awx example.com"
          ] do
        assert {:error, :invalid_controller_base_url} =
                 AwxClient.ping(controller(%{base_url: base_url}), opts)
      end

      refute_received :grant_issued
      refute_received {:dispatch, _, _, _, _}
    end
  end

  describe "credential-broker HTTP attenuation" do
    test "maps every supported plugin verb to its exact reviewed AWX endpoints" do
      digest = String.duplicate("a", 64)

      cases = [
        {"awx.ping", %{}, ["GET"], ["=/api/v2/ping/"]},
        {"awx.list_inventories", %{}, ["GET"], ["=/api/v2/inventories/"]},
        {"awx.list_hosts", %{"inventory_id" => 7}, ["GET"], ["=/api/v2/inventories/7/hosts/"]},
        {"awx.list_inventory_groups", %{"inventory_id" => 7}, ["GET"],
         ["=/api/v2/inventories/7/groups/"]},
        {"awx.current_user", %{}, ["GET"], ["=/api/v2/me/"]},
        {"awx.list_projects", %{}, ["GET"], ["=/api/v2/projects/"]},
        {"awx.list_templates", %{}, ["GET"], ["=/api/v2/job_templates/"]},
        {"awx.fetch_template", %{"template_id" => 42}, ["GET"],
         ["=/api/v2/job_templates/42/", "=/api/v2/job_templates/42/survey_spec/"]},
        {"awx.fetch_launch_preflight", launch_preflight_request(), ["GET"],
         [
           "=/api/v2/job_templates/42/",
           "=/api/v2/job_templates/42/survey_spec/",
           "=/api/v2/projects/73/",
           "=/api/v2/inventories/7/",
           "=/api/v2/execution_environments/14/",
           "=/api/v2/credentials/5/",
           "=/api/v2/credentials/91/",
           "=/api/v2/hosts/101/"
         ]},
        {"awx.inventory_sync", %{}, ["GET"], ["=/api/v2/inventories/", "/api/v2/inventories/*"]},
        {"awx.launch_job", %{"template_id" => 42, "host_limit" => "node-1"}, ["POST"],
         ["=/api/v2/job_templates/42/launch/"]},
        {"awx.fetch_job", %{"job_id" => 7331}, ["GET"], ["=/api/v2/jobs/7331/"]},
        {"awx.fetch_job_host_summaries", %{"job_id" => 7331, "max_hosts" => 1_000}, ["GET"],
         ["=/api/v2/jobs/7331/job_host_summaries/"]},
        {"awx.list_recent_jobs",
         %{
           "template_id" => 42,
           "inventory_id" => 7,
           "created_by_id" => 11,
           "created_after" => "2026-07-12T20:00:00Z",
           "page_size" => 25,
           "max_candidates" => 5_000
         }, ["GET"], ["=/api/v2/jobs/"]},
        {"awx.cancel_job", %{"job_id" => 7331}, ["POST"], ["=/api/v2/jobs/7331/cancel/"]},
        {"awx.fetch_events_for_jobs",
         %{
           "pairs" => [
             %{"job_id" => 7331, "since_id" => 0},
             %{"job_id" => 7332, "since_id" => 10}
           ]
         }, ["GET"], ["=/api/v2/jobs/7331/job_events/", "=/api/v2/jobs/7332/job_events/"]},
        {"awx.create_callback_credential",
         %{
           "credential_type_id" => 91,
           "organization_id" => 2,
           "credential_name" => "sr-callback-test",
           "injector_sha256" => digest
         }, ["GET", "POST"], ["=/api/v2/credential_types/91/", "=/api/v2/credentials/"]},
        {"awx.fetch_callback_credential",
         %{
           "credential_type_id" => 91,
           "organization_id" => 2,
           "credential_name" => "sr-callback-test"
         }, ["GET"], ["=/api/v2/credentials/"]},
        {"awx.verify_callback_credential",
         %{
           "credential_id" => 401,
           "credential_type_id" => 91,
           "organization_id" => 2,
           "credential_name" => "sr-callback-test"
         }, ["GET"], ["=/api/v2/credentials/401/"]},
        {"awx.list_callback_credentials",
         %{
           "credential_type_id" => 91,
           "organization_id" => 2,
           "credential_name" => "sr-callback-test",
           "max_credentials" => 5_000
         }, ["GET"], ["=/api/v2/credentials/"]},
        {"awx.delete_callback_credential",
         %{
           "credential_id" => 401,
           "credential_type_id" => 91,
           "organization_id" => 2,
           "credential_name" => "sr-callback-test"
         }, ["GET", "DELETE"], ["=/api/v2/credentials/401/"]}
      ]

      for {verb, args, methods, paths} <- cases do
        assert {:ok, scope} = AwxClient.broker_scope("https://awx.example.com", verb, args)
        assert scope.allow["methods"] == methods
        assert scope.allow["paths"] == paths
        assert scope.allow["hosts"] == ["awx.example.com"]
        assert scope.allow["ports"] == [443]
        refute "/api/v2/" in paths
      end
    end

    test "unsupported verbs and malformed path arguments fail closed" do
      malformed = [
        {"awx.unreviewed_admin_action", %{}},
        {"awx.ping", %{"unexpected" => true}},
        {"awx.list_hosts", %{"inventory_id" => 0}},
        {"awx.fetch_template", %{"template_id" => -1}},
        {"awx.fetch_launch_preflight", Map.delete(launch_preflight_request(), "schema")},
        {"awx.fetch_launch_preflight", launch_preflight_request(%{"template_id" => 42})},
        {"awx.fetch_launch_preflight",
         launch_preflight_request(%{"credential_ids" => ["91", "5"]})},
        {"awx.fetch_launch_preflight",
         launch_preflight_request(%{
           "selected_hosts" => [
             launch_preflight_request()["selected_hosts"] |> hd() |> Map.put("enabled", "true")
           ]
         })},
        {"awx.fetch_launch_preflight",
         launch_preflight_request(%{
           "selected_hosts" => [
             launch_preflight_request()["selected_hosts"] |> hd() |> Map.put("enabled", false)
           ]
         })},
        {"awx.fetch_launch_preflight",
         launch_preflight_request(%{
           "selected_hosts" => [
             launch_preflight_request()["selected_hosts"]
             |> hd()
             |> Map.put("host_name", "NODE-101")
           ]
         })},
        {"awx.fetch_launch_preflight",
         launch_preflight_request(%{
           "selected_hosts" => [
             launch_preflight_request()["selected_hosts"] |> hd() |> Map.put("ansible_host", nil)
           ]
         })},
        {"awx.fetch_launch_preflight",
         launch_preflight_request(%{
           "selected_hosts" => [
             launch_preflight_request()["selected_hosts"] |> hd() |> Map.put("ansible_host", "")
           ]
         })},
        {"awx.launch_job", %{"template_id" => 0}},
        {"awx.launch_job", %{"template_id" => 42, "unreviewed" => true}},
        {"awx.launch_job", %{"template_id" => 42, "inventory_id" => "7"}},
        {"awx.launch_job", %{"template_id" => 42, "credential_ids" => [5, 5]}},
        {"awx.launch_job", %{"template_id" => 42, "job_type" => "admin"}},
        {"awx.launch_job",
         %{
           "template_id" => 42,
           "extra_vars" => %{"serviceradar_dispatch_id" => ""}
         }},
        {"awx.fetch_job", %{"job_id" => -1}},
        {"awx.fetch_job_host_summaries", %{"job_id" => 1, "max_hosts" => 10_001}},
        {"awx.list_recent_jobs", %{"template_id" => 42}},
        {"awx.list_recent_jobs",
         %{
           "template_id" => 42,
           "inventory_id" => 7,
           "created_by_id" => 11,
           "created_after" => "not-rfc3339",
           "page_size" => 25,
           "max_candidates" => 5_000
         }},
        {"awx.cancel_job", %{"job_id" => 0}},
        {"awx.fetch_events_for_jobs", %{"pairs" => []}},
        {"awx.fetch_events_for_jobs", %{"pairs" => [%{"job_id" => 1, "since_id" => -1}]}},
        {"awx.fetch_callback_credential", %{"credential_type_id" => 91, "organization_id" => 2}},
        {"awx.verify_callback_credential",
         %{
           "credential_id" => 0,
           "credential_type_id" => 91,
           "organization_id" => 2,
           "credential_name" => "sr-callback-test"
         }},
        {"awx.list_callback_credentials",
         %{
           "credential_type_id" => 91,
           "organization_id" => 2,
           "credential_name" => "sr-callback-test",
           "max_credentials" => 5_001
         }}
      ]

      for {verb, args} <- malformed do
        assert {:error, :invalid_awx_broker_scope} =
                 AwxClient.broker_scope("https://awx.example.com", verb, args)
      end
    end

    test "preflight broker scope rejects non-string map keys without raising" do
      malformed = Map.put(launch_preflight_request(), {:untrusted, :selector}, "value")

      assert {:error, :invalid_awx_broker_scope} =
               AwxClient.broker_scope(
                 "https://awx.example.com",
                 "awx.fetch_launch_preflight",
                 malformed
               )

      assert {:error, :invalid_awx_launch_preflight_request} =
               AwxClient.fetch_launch_preflight(controller(), malformed, dispatch_opts())

      refute_received {:dispatch, _, "awx.fetch_launch_preflight", _, _}
    end

    test "preflight binds the request controller to the dispatched controller" do
      mismatched_controller =
        Map.put(preflight_controller(), :id, "018f3f56-0000-7222-8333-123456789abd")

      assert {:error, :controller_launch_preflight_identity_mismatch} =
               AwxClient.fetch_launch_preflight(
                 mismatched_controller,
                 launch_preflight_request(),
                 dispatch_opts()
               )

      refute_received {:dispatch, _, "awx.fetch_launch_preflight", _, _}
    end

    test "event polling accepts only ten unique exact job pairs" do
      ten_pairs =
        Enum.map(1..10, fn job_id ->
          %{"job_id" => job_id, "since_id" => job_id - 1}
        end)

      assert {:ok, scope} =
               AwxClient.broker_scope(
                 "https://awx.example.com",
                 "awx.fetch_events_for_jobs",
                 %{"pairs" => ten_pairs}
               )

      assert length(scope.allowed_paths) == 10

      invalid_pair_sets = [
        ten_pairs ++ [%{"job_id" => 11, "since_id" => 10}],
        [%{"job_id" => 1, "since_id" => 0}, %{"job_id" => 1, "since_id" => 0}],
        [%{"job_id" => 1, "since_id" => 0}, %{"job_id" => 1, "since_id" => 10}],
        [%{"job_id" => 1, "since_id" => 0, "unexpected" => true}]
      ]

      for pairs <- invalid_pair_sets do
        assert {:error, :invalid_awx_broker_scope} =
                 AwxClient.broker_scope(
                   "https://awx.example.com",
                   "awx.fetch_events_for_jobs",
                   %{"pairs" => pairs}
                 )
      end
    end
  end

  describe "purpose-specific credential selection" do
    test "every supported verb has one explicit privilege purpose" do
      for verb <- [
            "awx.ping",
            "awx.list_inventories",
            "awx.list_hosts",
            "awx.list_inventory_groups",
            "awx.current_user",
            "awx.list_projects",
            "awx.list_templates",
            "awx.fetch_template",
            "awx.inventory_sync"
          ] do
        assert {:ok, :sync} = AwxClient.credential_purpose_for_verb(verb)
      end

      for verb <- [
            "awx.fetch_launch_preflight",
            "awx.launch_job",
            "awx.fetch_job",
            "awx.fetch_job_host_summaries",
            "awx.list_recent_jobs",
            "awx.cancel_job",
            "awx.fetch_events_for_jobs"
          ] do
        assert {:ok, :execution} = AwxClient.credential_purpose_for_verb(verb)
      end

      for verb <- [
            "awx.create_callback_credential",
            "awx.fetch_callback_credential",
            "awx.verify_callback_credential",
            "awx.list_callback_credentials",
            "awx.delete_callback_credential"
          ] do
        assert {:ok, :callback} = AwxClient.credential_purpose_for_verb(verb)
      end

      assert {:error, :unsupported_awx_verb} =
               AwxClient.credential_purpose_for_verb("awx.unreviewed_admin_action")

      assert {:error, :unsupported_awx_verb} = AwxClient.credential_purpose_for_verb(nil)

      assert {:error, :unsupported_awx_verb} =
               AwxClient.credential_secret_id_for_verb(controller(), nil)
    end

    test "sync, execution, and callback grants carry only their selected secret" do
      assert {:ok, _} = AwxClient.ping(controller(), dispatch_opts())
      assert_receive {:dispatch, _, "awx.ping", sync_payload, _}

      assert sync_payload["credential_broker"]["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

      assert {:ok, _} = AwxClient.launch_job(controller(), 42, %{}, dispatch_opts())
      assert_receive {:dispatch, _, "awx.launch_job", execution_payload, _}

      assert execution_payload["credential_broker"]["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-2222-7222-8333-123456789abc"

      assert {:ok, _} =
               AwxClient.fetch_launch_preflight(
                 preflight_controller(),
                 launch_preflight_request(),
                 dispatch_opts()
               )

      assert_receive {:dispatch, _, "awx.fetch_launch_preflight", preflight_payload, _}

      assert preflight_payload["args"] == launch_preflight_request()

      assert preflight_payload["credential_broker"]["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-2222-7222-8333-123456789abc"

      assert {:ok, _} =
               AwxClient.fetch_callback_credential(
                 controller(),
                 %{
                   credential_type_id: 91,
                   organization_id: 2,
                   credential_name: "sr-callback-test"
                 },
                 dispatch_opts()
               )

      assert_receive {:dispatch, _, "awx.fetch_callback_credential", callback_payload, _}

      assert callback_payload["credential_broker"]["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-3333-7222-8333-123456789abc"
    end

    test "legacy compatibility is sync-only and cannot elevate into execution or callback" do
      legacy_only =
        controller(%{
          sync_credential_secret_id: nil,
          execution_credential_secret_id: nil,
          callback_credential_secret_id: nil
        })

      assert {:ok, _} = AwxClient.ping(legacy_only, dispatch_opts())
      assert_receive {:dispatch, _, "awx.ping", payload, _}

      assert payload["credential_broker"]["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-0000-7222-8333-123456789abc"

      assert {:error, {:controller_credential_missing, :execution}} =
               AwxClient.launch_job(legacy_only, 42, %{}, dispatch_opts())

      assert {:error, {:controller_credential_missing, :callback}} =
               AwxClient.fetch_callback_credential(
                 legacy_only,
                 %{
                   credential_type_id: 91,
                   organization_id: 2,
                   credential_name: "sr-callback-test"
                 },
                 dispatch_opts()
               )

      refute_received {:dispatch, _, "awx.launch_job", _, _}
      refute_received {:dispatch, _, "awx.fetch_callback_credential", _, _}
    end

    test "callback may deliberately reuse the execution credential" do
      shared = "018f3f56-2222-7222-8333-123456789abc"
      ctrl = controller(%{callback_credential_secret_id: shared})

      assert {:ok, _} =
               AwxClient.fetch_callback_credential(
                 ctrl,
                 %{
                   credential_type_id: 91,
                   organization_id: 2,
                   credential_name: "sr-callback-test"
                 },
                 dispatch_opts()
               )

      assert_receive {:dispatch, _, "awx.fetch_callback_credential", payload, _}

      assert payload["credential_broker"]["credential_secret_ref"] ==
               "credentialref:network-credential-secret:#{shared}"
    end

    test "execution-principal discovery uses only the execution secret and exact me endpoint" do
      assert {:ok, _} = AwxClient.current_execution_user(controller(), dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.current_user", payload, _opts}

      broker = payload["credential_broker"]

      assert broker["credential_secret_ref"] ==
               "credentialref:network-credential-secret:018f3f56-2222-7222-8333-123456789abc"

      assert broker["allow"]["methods"] == ["GET"]
      assert broker["allow"]["paths"] == ["=/api/v2/me/"]
      assert payload["verb"] == "awx.current_user"
      assert payload["args"] == %{}
    end

    test "callers cannot override credential purpose on current_user or another verb" do
      for {fun, purpose} <- [{:current_user, :execution}, {:ping, :callback}] do
        opts = Keyword.put(dispatch_opts(), :credential_purpose, purpose)

        assert {:error, :credential_purpose_override_not_allowed} =
                 apply(AwxClient, fun, [controller(), opts])
      end

      refute_received {:dispatch, _, _, _, _}
    end

    test "execution-principal discovery never falls back to the legacy sync bridge" do
      legacy_only =
        controller(%{
          sync_credential_secret_id: nil,
          execution_credential_secret_id: nil,
          callback_credential_secret_id: nil
        })

      assert {:error, {:controller_credential_missing, :execution}} =
               AwxClient.current_execution_user(legacy_only, dispatch_opts())

      refute_received {:dispatch, _, "awx.current_user", _, _}
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
      assert grant["allow"]["paths"] == ["=/api/v2/ping/"]
      assert grant["allow"]["hosts"] == ["awx.example.com"]
      assert grant["allow"]["ports"] == [443]
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

        expected_path =
          case verb do
            "awx.list_inventories" -> "=/api/v2/inventories/"
            "awx.list_projects" -> "=/api/v2/projects/"
            "awx.list_templates" -> "=/api/v2/job_templates/"
            "awx.current_user" -> "=/api/v2/me/"
          end

        assert payload["credential_broker"]["allow"]["paths"] == [expected_path]
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

      assert payload["credential_broker"]["allow"]["paths"] == [
               "=/api/v2/job_templates/42/launch/"
             ]

      assert payload["credential_broker"]["schema"] ==
               "serviceradar.edge_credential_broker_grant.v2"

      request_policy = payload["credential_broker"]["allow"]["request_body"]
      assert request_policy["mode"] == "bound_bytes"
      assert request_policy["source"] == "command.authorized_request_body_b64"
      assert request_policy["content_type"] == "application/json"
      assert request_policy["max_mutations"] == 1

      authorized_body = Base.decode64!(payload["authorized_request_body_b64"])

      assert Jason.decode!(authorized_body) == %{
               "extra_vars" => %{"version" => "1.2.3"},
               "limit" => "web01,web02",
               "inventory" => 7
             }

      assert request_policy["sha256"] ==
               authorized_body
               |> then(&:crypto.hash(:sha256, &1))
               |> Base.encode16(case: :lower)
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

      assert Jason.decode!(Base.decode64!(payload["authorized_request_body_b64"])) == %{
               "credentials" => [5, 9],
               "execution_environment" => 12,
               "job_type" => "check",
               "diff_mode" => true,
               "verbosity" => 2,
               "forks" => 10,
               "job_slice_count" => 1,
               "timeout" => 600,
               "job_tags" => "preflight,enroll",
               "skip_tags" => "destructive",
               "labels" => [4],
               "instance_groups" => [8]
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
      assert Base.decode64!(payload["authorized_request_body_b64"]) == "{}"
    end

    test "no launch_opts at all means just template_id" do
      assert {:ok, _} = AwxClient.launch_job(controller(), 1, %{}, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}
      assert payload["args"] == %{"template_id" => 1}
      assert Base.decode64!(payload["authorized_request_body_b64"]) == "{}"
    end

    test "preserves floating-point and unicode values without cross-runtime re-encoding" do
      assert {:ok, _} =
               AwxClient.launch_job(
                 controller(),
                 42,
                 %{extra_vars: %{"ratio" => 1.0, "message" => "café"}},
                 dispatch_opts()
               )

      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}
      body = Base.decode64!(payload["authorized_request_body_b64"])

      assert Jason.decode!(body) == %{
               "extra_vars" => %{"ratio" => 1.0, "message" => "café"}
             }

      assert payload["credential_broker"]["allow"]["request_body"]["sha256"] ==
               body |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    end

    test "allows public certificate material while private key material remains forbidden" do
      public_ca = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyPublicCA serviceradar-user-ca"

      assert {:ok, _} =
               AwxClient.launch_job(
                 controller(),
                 42,
                 %{extra_vars: %{"certificate" => public_ca}},
                 dispatch_opts()
               )

      assert_receive {:dispatch, "agent-a", "awx.launch_job", payload, _opts}

      assert payload["authorized_request_body_b64"]
             |> Base.decode64!()
             |> Jason.decode!() == %{"extra_vars" => %{"certificate" => public_ca}}
    end

    test "rejects secret-like and transport-retargeting extra vars before grant issuance" do
      for extra_vars <- [
            %{"password" => "must-not-dispatch"},
            %{"api_token" => "must-not-dispatch"},
            %{"ansible_user" => "must-not-dispatch"},
            %{"inventory_hostname" => "must-not-dispatch"},
            %{"config" => %{"password" => "nested-secret"}},
            %{"endpoint" => "PVEAPIToken=operator@pve!automation=secret"},
            %{"serviceradar_dispatch_id" => "PVEAPIToken=operator@pve!automation=secret"},
            %{
              "serviceradar_snapshot_digest" => "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret"
            }
          ] do
        assert {:error, :invalid_awx_broker_scope} =
                 AwxClient.launch_job(
                   controller(),
                   42,
                   %{extra_vars: extra_vars},
                   dispatch_opts()
                 )
      end

      refute_received {:dispatch, _, "awx.launch_job", _, _}
    end

    test "rejects redactor-changing launch fields outside extra vars before Base64 binding" do
      for launch_opts <- [
            %{host_limit: "PVEAPIToken=operator@pve!automation=secret"},
            %{
              job_tags: Base.decode64!("LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0Kc2VjcmV0")
            }
          ] do
        assert {:error, :invalid_awx_request_body_policy} =
                 AwxClient.launch_job(controller(), 42, launch_opts, dispatch_opts())
      end

      refute_received {:dispatch, _, "awx.launch_job", _, _}
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
      assert grant["schema"] == "serviceradar.edge_credential_broker_grant.v2"
      assert grant["allow"]["methods"] == ["GET", "POST"]

      assert grant["allow"]["request_body"] == %{
               "mode" => "trusted_rewrite",
               "handler" => "awx_callback_credential.v1",
               "content_type" => "application/json",
               "max_bytes" => 256 * 1024,
               "max_mutations" => 1
             }

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
               "paths" => ["=/api/v2/credentials/401/"],
               "ports" => [443],
               "schemes" => ["https"],
               "request_body" => %{
                 "mode" => "empty",
                 "content_type" => "application/json",
                 "max_mutations" => 1
               }
             }

      assert payload["credential_broker"]["schema"] ==
               "serviceradar.edge_credential_broker_grant.v2"

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

  describe "callback credential provenance reads" do
    test "verify_callback_credential/3 carries one exact ID and immutable scope" do
      request = %{
        credential_id: 401,
        credential_type_id: 91,
        organization_id: 2,
        credential_name: "sr-callback-test"
      }

      assert {:ok, _} =
               AwxClient.verify_callback_credential(controller(), request, dispatch_opts())

      assert_receive {:dispatch, "agent-a", "awx.verify_callback_credential", payload, _opts}

      assert payload["args"] == %{
               "credential_id" => 401,
               "credential_type_id" => 91,
               "organization_id" => 2,
               "credential_name" => "sr-callback-test"
             }

      assert payload["credential_broker"]["allow"]["paths"] == [
               "=/api/v2/credentials/401/"
             ]
    end

    test "list_callback_credentials/3 carries a complete bounded selector" do
      request = %{
        credential_type_id: 91,
        organization_id: 2,
        credential_name: "sr-callback-test",
        max_credentials: 5_000
      }

      assert {:ok, _} =
               AwxClient.list_callback_credentials(controller(), request, dispatch_opts())

      assert_receive {:dispatch, "agent-a", "awx.list_callback_credentials", payload, _opts}

      assert payload["args"] == %{
               "credential_type_id" => 91,
               "organization_id" => 2,
               "credential_name" => "sr-callback-test",
               "max_credentials" => 5_000
             }

      assert payload["credential_broker"]["allow"]["paths"] == ["=/api/v2/credentials/"]
    end

    test "callback provenance bounds fail before grant issuance" do
      assert_raise ArgumentError, fn ->
        AwxClient.list_callback_credentials(
          controller(),
          %{
            credential_type_id: 91,
            organization_id: 2,
            credential_name: "sr-callback-test",
            max_credentials: 5_001
          },
          dispatch_opts()
        )
      end

      refute_received {:dispatch, _, "awx.list_callback_credentials", _, _}
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
        page_size: 25,
        max_candidates: 5_000
      }

      assert {:ok, _} = AwxClient.list_recent_jobs(controller(), filters, dispatch_opts())
      assert_receive {:dispatch, "agent-a", "awx.list_recent_jobs", payload, _opts}

      assert payload["args"] == %{
               "template_id" => 42,
               "inventory_id" => 7,
               "created_by_id" => 11,
               "created_after" => "2026-07-12T20:00:00Z",
               "page_size" => 25,
               "max_candidates" => 5_000
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
            page_size: 101,
            max_candidates: 5_000
          },
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
            page_size: 50,
            max_candidates: 4_999
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

      assert payload["credential_broker"]["allow"]["paths"] == [
               "=/api/v2/jobs/7331/cancel/"
             ]

      assert payload["credential_broker"]["schema"] ==
               "serviceradar.edge_credential_broker_grant.v2"

      assert payload["credential_broker"]["allow"]["request_body"] == %{
               "mode" => "empty",
               "content_type" => "application/json",
               "max_mutations" => 1
             }
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

    test "rejects an empty pair list before issuing an unscoped grant" do
      assert {:error, :invalid_awx_broker_scope} =
               AwxClient.fetch_events_for_jobs(controller(), [], dispatch_opts())

      refute_received {:dispatch, _, "awx.fetch_events_for_jobs", _, _}
    end

    test "rejects oversized or duplicate-job batches before dispatch" do
      oversized = Enum.map(1..11, &%{job_id: &1, since_id: 0})
      duplicate_job = [%{job_id: 1, since_id: 0}, %{job_id: 1, since_id: 10}]

      for pairs <- [oversized, duplicate_job] do
        assert {:error, :invalid_awx_broker_scope} =
                 AwxClient.fetch_events_for_jobs(controller(), pairs, dispatch_opts())
      end

      refute_received {:dispatch, _, "awx.fetch_events_for_jobs", _, _}
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

      assert payload["allow"]["paths"] == [
               "=/api/v2/inventories/",
               "/api/v2/inventories/*"
             ]

      assert payload["allow"]["hosts"] == ["awx.example.com"]
      assert payload["allow"]["ports"] == [443]
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

    test "requires literal boolean true and accepts the atom metadata key" do
      for value <- ["false", "true", 1, nil, false] do
        ctrl = controller(%{metadata: %{"insecure_skip_verify" => value}})
        assert {:ok, _} = AwxClient.ping(ctrl, dispatch_opts())
        assert_receive {:dispatch, _, _, payload, _}
        assert payload["insecure_skip_verify"] == false
        refute Map.has_key?(payload["credential_broker"]["inject"], "allow_insecure_tls")
      end

      ctrl = controller(%{metadata: %{insecure_skip_verify: true}})
      assert {:ok, _} = AwxClient.ping(ctrl, dispatch_opts())
      assert_receive {:dispatch, _, _, payload, _}
      assert payload["insecure_skip_verify"] == true
      assert payload["credential_broker"]["inject"]["allow_insecure_tls"] == "true"
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
