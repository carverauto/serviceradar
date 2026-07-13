defmodule ServiceRadar.Automation.Ansible.CallbackCommandDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadar.Plugins.SecretRefs

  @now ~U[2026-07-13 12:00:00.000000Z]
  @controller_id "018f3f56-1111-7222-8333-123456789abe"
  @execution_secret "018f3f56-2222-7222-8333-123456789abe"

  test "a fast terminal result may take the processing lease before dispatch returns" do
    execution = %{
      id: Ash.UUID.generate(),
      dispatch_id: Ash.UUID.generate(),
      snapshot_digest: String.duplicate("a", 64)
    }

    base = %{
      grant_id: Ash.UUID.generate(),
      operation_id: Ash.UUID.generate(),
      execution_id: execution.id,
      controller_id: Ash.UUID.generate(),
      dispatch_agent_id: "agent-farm01"
    }

    {:ok, request} = CallbackCommandContract.fetch_job_request(42)

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(base, execution, request,
        stage: :fetch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.fetch_job",
        expected_job_id: 42,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    assert {:ok, :result_already_processing} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt ->
                 {:ok,
                  %{
                    operation: %{},
                    execution: execution,
                    controller: %{id: base.controller_id},
                    grant: %{}
                  }}
               end,
               claim: fn ^attempt, lease_token, lease_expires_at, now ->
                 assert now == @now

                 {:ok,
                  %{
                    attempt
                    | state: :dispatching,
                      lease_token: lease_token,
                      lease_expires_at: lease_expires_at
                  }}
               end,
               awx_dispatcher: fn claimed, _controller, ^request, context, _opts ->
                 assert claimed.state == :dispatching
                 assert context["verb"] == "awx.fetch_job"
                 {:ok, %{id: claimed.command_id}}
               end,
               mark_dispatched: fn _claimed, _token, now ->
                 assert now == @now
                 {:error, :stale_lease}
               end,
               attempt_fetcher: fn id ->
                 assert id == attempt.id
                 {:ok, %{attempt | state: :processing}}
               end
             )
  end

  test "dispatch crash-window reconciliation requires the full persisted callback command" do
    {attempt, resources, request} = fetch_job_attempt()
    context = CallbackCommandContract.context(attempt, resources.execution)
    command = persisted_command(attempt, resources.controller, request, context)

    assert CallbackCommandContract.context_matches?(attempt, resources.execution, command.context)

    assert CallbackCommandContract.persisted_payload_matches?(
             attempt,
             resources.execution,
             resources.controller,
             request,
             command.payload
           )

    assert {:ok, :persisted_for_recovery} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn _ -> {:ok, resources} end,
               claim: &claim/4,
               awx_dispatcher: fn _, _, _, _, _ -> {:error, :transport_interrupted} end,
               command_fetcher: fn _ -> {:ok, command} end,
               mark_dispatched: fn claimed, _token, _now ->
                 {:ok, %{claimed | state: :dispatched}}
               end
             )
  end

  test "dispatch crash-window reconciliation rejects tampered callback payload and context" do
    for tamper <- [:payload, :context] do
      {attempt, resources, request} = fetch_job_attempt()
      context = CallbackCommandContract.context(attempt, resources.execution)
      command = persisted_command(attempt, resources.controller, request, context)

      command =
        case tamper do
          :payload ->
            command.payload
            |> put_in(["credential_broker", "allow", "paths"], ["/api/v2/"])
            |> then(&%{command | payload: &1})

          :context ->
            %{command | context: Map.put(context, "snapshot_digest", String.duplicate("f", 64))}
        end

      assert {:error, :callback_command_persisted_correlation_mismatch} =
               CallbackCommandDispatcher.dispatch(attempt,
                 now: @now,
                 resource_loader: fn _ -> {:ok, resources} end,
                 claim: &claim/4,
                 awx_dispatcher: fn _, _, _, _, _ ->
                   {:error, {:transport_interrupted, "Bearer must-not-escape"}}
                 end,
                 command_fetcher: fn _ -> {:ok, command} end,
                 mark_dispatched: fn _, _, _ -> flunk("tampered command must not be accepted") end
               )
    end
  end

  defp fetch_job_attempt do
    execution = %{
      id: "018f3f56-1111-7222-8333-123456789abd",
      operation_id: "018f3f56-1111-7222-8333-123456789abc",
      controller_id: @controller_id,
      dispatch_id: "018f3f56-1111-7222-8333-123456789abf",
      snapshot_digest: String.duplicate("a", 64)
    }

    base = %{
      grant_id: "018f3f56-1111-7222-8333-123456789ac0",
      operation_id: execution.operation_id,
      execution_id: execution.id,
      controller_id: @controller_id,
      dispatch_agent_id: "edge-agent-1"
    }

    controller = %{
      id: @controller_id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: "edge-agent-1",
      credential_secret_id: Ash.UUID.generate(),
      sync_credential_secret_id: Ash.UUID.generate(),
      execution_credential_secret_id: @execution_secret,
      callback_credential_secret_id: Ash.UUID.generate(),
      metadata: %{}
    }

    {:ok, request} = CallbackCommandContract.fetch_job_request(42)

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(base, execution, request,
        stage: :fetch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.fetch_job",
        expected_job_id: 42,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    resources = %{
      operation: %{
        id: execution.operation_id,
        callback_actions: ["remote_access.ssh_ca.bundle.read"]
      },
      execution: execution,
      controller: controller,
      grant: %{}
    }

    {attempt, resources, request}
  end

  defp persisted_command(attempt, controller, request, context) do
    args = %{"job_id" => request.job_id}
    {:ok, scope} = AwxClient.broker_scope(controller.base_url, attempt.command_type, args)

    broker = %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_id" => Ash.UUID.generate(),
      "grant_type" => "awx_oauth2_token",
      "credential_secret_ref" => SecretRefs.network_credential_ref(@execution_secret),
      "consumer" => %{
        "kind" => "ansible",
        "id" => @controller_id,
        "purpose" => attempt.command_type
      },
      "target" => %{
        "kind" => "awx_controller",
        "id" => @controller_id,
        "agent_id" => attempt.dispatch_agent_id
      },
      "resolution_location" => "agent",
      "inject" => %{
        "type" => "http_header",
        "name" => "Authorization",
        "scheme" => "Bearer"
      },
      "allow" => scope.allow,
      "ttl_seconds" => 300,
      "expires_at" => @now |> DateTime.add(300, :second) |> DateTime.to_iso8601()
    }

    struct!(AgentCommand, %{
      id: attempt.command_id,
      command_type: attempt.command_type,
      agent_id: attempt.dispatch_agent_id,
      context: context,
      payload: %{
        "schema" => "serviceradar.awx_command.v1",
        "verb" => attempt.command_type,
        "args" => args,
        "base_url" => scope.base_url,
        "controller_id" => @controller_id,
        "controller_name" => controller.name,
        "insecure_skip_verify" => false,
        "credential_broker" => broker
      }
    })
  end

  defp claim(claimed, _token, _expires, _now), do: {:ok, %{claimed | state: :dispatching}}
end
