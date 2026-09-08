defmodule ServiceRadar.Automation.Ansible.ControllerProvenanceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ControllerProvenance
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Credentials.CredentialBrokerGrant

  defmodule FakeCommandBus do
    @moduledoc false

    def dispatch(agent_id, command_type, payload, opts) do
      Process.put(:controller_provenance_dispatch, {agent_id, command_type, payload, opts})
      send(self(), {:edge_dispatch, agent_id, command_type, payload, opts})
      {:ok, "018f3f56-aaaa-4bbb-8ccc-123456789abc"}
    end
  end

  setup do
    Process.delete(:controller_provenance_dispatch)
    Process.delete(:controller_provenance_result)
    Process.delete(:controller_provenance_statuses)
    Process.delete(:controller_provenance_command_mutator)
    :ok
  end

  test "production default uses AwxClient edge dispatch with the frozen agent and partition" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)

    set_result(%{
      "verb" => "awx.fetch_job",
      "ok" => true,
      "job_id" => 42,
      "job" => job(42)
    })

    assert {:ok, %{"id" => 42, "status" => "running"}} =
             ControllerProvenance.verify_job(
               controller,
               42,
               base_opts(snapshot) ++
                 [
                   request_fun: fn _ -> flunk("core must never dial AWX") end,
                   credential_resolver: fn _, _ ->
                     flunk("core must never resolve the AWX bearer")
                   end
                 ]
             )

    assert_receive {:edge_dispatch, "edge-agent-1", "awx.fetch_job", payload, opts}
    assert opts[:required_partition] == "farm01"
    assert payload["args"] == %{"job_id" => 42}
    assert payload["credential_broker"]["consumer"]["purpose"] == "awx.fetch_job"
    assert payload["credential_broker"]["resolution_location"] == "agent"
    refute inspect(payload) =~ "execution-token"
  end

  test "snapshot drift and a missing immutable partition fail before edge dispatch" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)
    drifted = %{controller | base_url: "https://other-awx.example.test:8443"}

    assert {:error, :controller_security_snapshot_drift} =
             ControllerProvenance.verify_job(drifted, 42, base_opts(snapshot))

    refute_received {:edge_dispatch, _, _, _, _}

    assert {:error, :controller_dispatch_partition_required} =
             ControllerProvenance.verify_job(
               controller,
               42,
               Keyword.delete(base_opts(snapshot), :expected_partition_id)
             )

    refute_received {:edge_dispatch, _, _, _, _}
  end

  test "persisted command identity and terminal state are validated exactly" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)

    result = %{
      "verb" => "awx.fetch_job",
      "ok" => true,
      "job_id" => 42,
      "job" => job(42)
    }

    for mutation <- [
          &Map.put(&1, :agent_id, "other-agent"),
          &Map.put(&1, :partition_id, "tonka01"),
          &Map.put(&1, :command_type, "awx.cancel_job"),
          &Map.put(&1, :status, :succeeded),
          &update_in(&1.payload["args"], fn _ -> %{"job_id" => 99} end)
        ] do
      set_result(result)
      Process.put(:controller_provenance_command_mutator, mutation)

      assert {:error, :controller_provenance_command_mismatch} =
               ControllerProvenance.verify_job(controller, 42, base_opts(snapshot))
    end

    set_result(result, [:failed])
    Process.delete(:controller_provenance_command_mutator)

    assert {:error, :controller_provenance_command_failed} =
             ControllerProvenance.verify_job(controller, 42, base_opts(snapshot))
  end

  test "active persisted commands are polled to completion with a bounded adapter" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)

    set_result(
      %{
        "verb" => "awx.fetch_job",
        "ok" => true,
        "job_id" => 42,
        "job" => job(42)
      },
      [:sent, :running, :completed]
    )

    assert {:ok, %{"id" => 42}} =
             ControllerProvenance.verify_job(
               controller,
               42,
               base_opts(snapshot) ++ [sleep: fn _ -> :ok end, poll_interval_ms: 1]
             )
  end

  test "job result cannot substitute a result-selected object ID" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)

    set_result(%{
      "verb" => "awx.fetch_job",
      "ok" => true,
      "job_id" => 42,
      "job" => job(99)
    })

    assert {:error, :controller_job_id_mismatch} =
             ControllerProvenance.verify_job(controller, 42, base_opts(snapshot))
  end

  test "recent-job provenance requests and validates the complete 5000-candidate window" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)
    request = recent_request()

    jobs = [job(42_001, request), job(42_002, request)]

    set_result(%{
      "verb" => "awx.list_recent_jobs",
      "ok" => true,
      "template_id" => request.template_id,
      "inventory_id" => request.inventory_id,
      "created_by_id" => request.created_by_id,
      "created_after" => request.created_after,
      "page_size" => request.page_size,
      "max_candidates" => 5_000,
      "count" => 2,
      "complete" => true,
      "jobs" => jobs
    })

    assert {:ok, %{complete?: true, jobs: verified}} =
             ControllerProvenance.list_recent_jobs(
               controller,
               request,
               base_opts(snapshot)
             )

    assert Enum.map(verified, & &1["id"]) == [42_001, 42_002]
    assert_receive {:edge_dispatch, _, "awx.list_recent_jobs", payload, _}
    assert payload["args"]["max_candidates"] == 5_000
    assert payload["args"]["created_by_id"] == request.created_by_id
  end

  test "incomplete, duplicate, or out-of-scope recent-job sets fail closed" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)
    request = recent_request()

    base = %{
      "verb" => "awx.list_recent_jobs",
      "ok" => true,
      "template_id" => request.template_id,
      "inventory_id" => request.inventory_id,
      "created_by_id" => request.created_by_id,
      "created_after" => request.created_after,
      "page_size" => request.page_size,
      "max_candidates" => 5_000,
      "count" => 1,
      "complete" => true,
      "jobs" => [job(42_001, request)]
    }

    for result <- [
          %{base | "complete" => false},
          %{base | "count" => 2, "jobs" => [job(42_001, request), job(42_001, request)]},
          %{base | "jobs" => [job(42_001, %{request | inventory_id: 999})]}
        ] do
      set_result(result)

      assert {:error, _reason} =
               ControllerProvenance.list_recent_jobs(
                 controller,
                 request,
                 base_opts(snapshot)
               )
    end
  end

  test "callback credential verification uses an exact read-only ID and scope" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)
    expected = credential_request()

    set_result(%{
      "verb" => "awx.verify_callback_credential",
      "ok" => true,
      "credential_id" => 401,
      "credential" => credential(expected, 401)
    })

    assert {:ok, %{"id" => 401} = verified} =
             ControllerProvenance.verify_callback_credential(
               controller,
               401,
               expected,
               base_opts(snapshot)
             )

    refute Map.has_key?(verified, "inputs")
    assert_receive {:edge_dispatch, _, "awx.verify_callback_credential", payload, _}
    assert payload["args"]["credential_id"] == 401
    assert payload["args"]["credential_name"] == expected.credential_name
  end

  test "callback lookup accepts only a complete, sorted, exact credential set" do
    controller = controller()
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)
    expected = credential_request()

    result = %{
      "verb" => "awx.list_callback_credentials",
      "ok" => true,
      "credential_type_id" => expected.credential_type_id,
      "organization_id" => expected.organization_id,
      "credential_name" => expected.credential_name,
      "max_credentials" => 5_000,
      "count" => 2,
      "complete" => true,
      "credentials" => [credential(expected, 501), credential(expected, 502)]
    }

    set_result(result)

    assert {:ok, %{complete?: true, credentials: credentials}} =
             ControllerProvenance.find_callback_credentials(
               controller,
               expected,
               base_opts(snapshot)
             )

    assert Enum.map(credentials, & &1["id"]) == [501, 502]

    set_result(%{result | "credentials" => Enum.reverse(result["credentials"])})

    assert {:error, :controller_credential_lookup_result_mismatch} =
             ControllerProvenance.find_callback_credentials(
               controller,
               expected,
               base_opts(snapshot)
             )
  end

  defp base_opts(snapshot) do
    [
      expected_controller_snapshot: snapshot,
      expected_partition_id: "farm01",
      awx_client_opts: [command_bus: FakeCommandBus, grant_issuer: &fake_grant/1],
      command_reader: &command_reader/1
    ]
  end

  defp command_reader(command_id) do
    {agent_id, command_type, payload, opts} =
      Process.get(:controller_provenance_dispatch)

    statuses = Process.get(:controller_provenance_statuses, [:completed])
    [status | remaining] = statuses

    Process.put(
      :controller_provenance_statuses,
      if(remaining == [], do: [status], else: remaining)
    )

    command = %{
      id: command_id,
      agent_id: agent_id,
      partition_id: opts[:required_partition],
      command_type: command_type,
      status: status,
      payload: payload,
      context: opts[:context],
      result_payload: Process.get(:controller_provenance_result)
    }

    command =
      case Process.get(:controller_provenance_command_mutator) do
        mutator when is_function(mutator, 1) -> mutator.(command)
        _ -> command
      end

    {:ok, command}
  end

  defp set_result(result, statuses \\ [:completed]) do
    Process.put(:controller_provenance_result, result)
    Process.put(:controller_provenance_statuses, statuses)
    Process.delete(:controller_provenance_command_mutator)
  end

  defp fake_grant(attrs) do
    grant =
      attrs
      |> CredentialBrokerGrant.issue_attrs()
      |> Map.put(:id, "grant-1")

    {:ok, CredentialBrokerGrant.to_payload(grant)}
  end

  defp recent_request do
    %{
      template_id: 42,
      inventory_id: 7,
      created_by_id: 17,
      created_after: "2026-07-12T21:00:00Z",
      page_size: 100,
      max_candidates: 5_000
    }
  end

  defp job(id, request \\ recent_request()) do
    %{
      "id" => id,
      "status" => "running",
      "created" => "2026-07-12T21:03:00Z",
      "job_template" => request.template_id,
      "inventory" => request.inventory_id,
      "launched_by" => %{"id" => request.created_by_id, "type" => "user"},
      "dispatch_markers" => %{"serviceradar_dispatch_id" => "dispatch-1"},
      "credentials" => [],
      "labels" => [],
      "label_count" => 0
    }
  end

  defp credential_request do
    %{
      credential_name: "sr-callback-018f3f56-1111-7222-8333-123456789aff",
      credential_type_id: 17,
      organization_id: 3
    }
  end

  defp credential(expected, id) do
    %{
      "id" => id,
      "name" => expected.credential_name,
      "credential_type_id" => expected.credential_type_id,
      "organization_id" => expected.organization_id,
      "inputs" => %{"secret" => "must-not-project"}
    }
  end

  defp controller do
    %Controller{
      id: "018f3f56-1111-7222-8333-123456789abc",
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: "edge-agent-1",
      enabled: true,
      credential_secret_id: "018f3f56-1111-7222-8333-123456789abd",
      sync_credential_secret_id: "018f3f56-1111-7222-8333-123456789abd",
      execution_credential_secret_id: "018f3f56-1111-7222-8333-123456789abe",
      callback_credential_secret_id: "018f3f56-1111-7222-8333-123456789aff",
      metadata: %{}
    }
  end
end
