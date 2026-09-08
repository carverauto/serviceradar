defmodule ServiceRadar.Automation.Ansible.LiveAwxLaunchPreflightTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.LiveAwxLaunchPreflight
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @now ~U[2026-07-14 20:00:00.000000Z]
  @controller_id "018f0000-0000-7000-8000-000000000001"
  @binding_id "018f0000-0000-7000-8000-000000000101"
  @approval_id "018f0000-0000-7000-8000-000000000102"
  @membership_id "018f0000-0000-7000-8000-000000000201"
  @command_id "018f0000-0000-7000-8000-000000000301"
  @evidence_id "018f0000-0000-7000-8000-000000000401"
  @agent_id "agent-farm01-01"
  @partition_id "farm01"

  test "attests the exact reviewed binding, current membership tuple, and durable command result" do
    context = context()

    provenance = fn controller, request, provenance_opts ->
      send(self(), {:preflight, controller, request, provenance_opts})
      {:ok, valid_result(request)}
    end

    evidence_resource = fn attrs, record_opts ->
      send(self(), {:evidence, attrs, record_opts})
      {:ok, %{id: @evidence_id}}
    end

    assert {:ok, attestation} =
             LiveAwxLaunchPreflight.attest(context, options(provenance, evidence_resource))

    assert_receive {:preflight, controller, request, provenance_opts}
    assert controller == context.controller
    assert request["controller_id"] == @controller_id
    assert request["template_id"] == "42"
    assert request["inventory_id"] == "8"

    assert request["selected_hosts"] == [
             %{
               "membership_id" => @membership_id,
               "controller_id" => @controller_id,
               "inventory_id" => "8",
               "awx_host_id" => "201",
               "canonical_device_uid" => "device-web01",
               "host_name" => "web01.example.test",
               "ansible_host" => "192.168.2.22",
               "enabled" => true,
               "membership_generation" => "5",
               "source_fingerprint" => "sha256:" <> String.duplicate("a", 64)
             }
           ]

    assert provenance_opts[:expected_controller_snapshot] == context.controller_security_snapshot
    assert provenance_opts[:expected_partition_id] == @partition_id

    assert_receive {:evidence, attrs, [actor: actor]}
    assert actor.role == :system
    assert actor.id == "system:ansible_live_awx_launch_preflight"
    assert attrs.command_id == @command_id
    assert attrs.controller_id == @controller_id
    assert attrs.dispatch_agent_id == @agent_id
    assert attrs.dispatch_partition_id == @partition_id
    assert attrs.binding_id == @binding_id
    assert attrs.binding_version == 7
    assert attrs.approval_id == @approval_id
    assert attrs.verified_at == @now
    assert attrs.expires_at == DateTime.add(@now, 30, :second)

    {:ok, reviewed_digest} = AwxLaunchContract.digest(context.binding.reviewed_launch_snapshot)
    {:ok, target_digest} = expected_target_digest(request)

    {:ok, security_digest} =
      ControllerSecuritySnapshot.digest(context.controller_security_snapshot)

    result = valid_result(request)

    assert attrs.reviewed_launch_snapshot_digest == reviewed_digest
    assert attrs.preflight_request_digest == result.request_digest
    assert attrs.target_snapshot_digest == target_digest
    assert attrs.controller_security_snapshot_digest == security_digest
    assert attrs.live_launch_snapshot_digest == result.preflight_digest
    assert attrs.command_result_digest == result.command_result_digest

    assert attestation.schema == "serviceradar.awx_live_launch_preflight_attestation.v1"
    assert attestation.evidence_id == @evidence_id
    assert attestation.command_id == @command_id
    assert attestation.controller_id == @controller_id
    assert attestation.binding_id == @binding_id
    assert attestation.binding_version == 7
    assert attestation.approval_id == @approval_id
    assert attestation.dispatch_agent_id == @agent_id
    assert attestation.dispatch_partition_id == @partition_id
    assert attestation.reviewed_launch_snapshot_digest == reviewed_digest
    assert attestation.preflight_request_digest == result.request_digest
    assert attestation.target_snapshot_digest == target_digest
    assert attestation.controller_security_snapshot_digest == security_digest
    assert attestation.live_launch_snapshot_digest == result.preflight_digest
    assert attestation.command_result_digest == result.command_result_digest
    assert attestation.verified_at == @now
    assert attestation.expires_at == DateTime.add(@now, 30, :second)
    refute Map.has_key?(attestation, :preflight)
    refute Map.has_key?(attestation, :request)
  end

  test "fails before evidence when the live static controller contract drifts" do
    provenance = fn _controller, request, _opts ->
      result = valid_result(request)
      preflight = put_in(result.preflight, ["template", "playbook"], "playbooks/unreviewed.yml")
      {:ok, with_preflight(result, preflight)}
    end

    assert {:error, :awx_preflight_template_project_drift} =
             LiveAwxLaunchPreflight.attest(context(), options(provenance, evidence_resource()))

    refute_received {:evidence, _, _}
  end

  test "fails before evidence when AWX returns a different selected target tuple" do
    provenance = fn _controller, request, _opts ->
      result = valid_result(request)

      preflight =
        result.preflight
        |> put_in(["selected_hosts", Access.at(0), "ansible_host"], "192.168.2.99")
        |> refresh_identity_digest()

      {:ok, with_preflight(result, preflight)}
    end

    assert {:error, :awx_preflight_target_drift} =
             LiveAwxLaunchPreflight.attest(context(), options(provenance, evidence_resource()))

    refute_received {:evidence, _, _}
  end

  test "requires the exact provenance request and command result digests and rejects raw result fields" do
    for {result_modifier, expected_error} <- [
          {fn result -> %{result | request_digest: String.duplicate("0", 64)} end,
           :awx_preflight_request_digest_mismatch},
          {fn result -> %{result | command_result_digest: "not-a-digest"} end,
           :awx_preflight_result_invalid},
          {fn result -> Map.put(result, :raw_response, %{"token" => "forbidden"}) end,
           :awx_preflight_result_invalid}
        ] do
      provenance = fn _controller, request, _opts ->
        {:ok, result_modifier.(valid_result(request))}
      end

      assert {:error, ^expected_error} =
               LiveAwxLaunchPreflight.attest(context(), options(provenance, evidence_resource()))

      refute_received {:evidence, _, _}
    end
  end

  test "requires a current approved complete binding and checks expiry before the controller read" do
    no_call = fn _controller, _request, _opts ->
      flunk("the preflight command must not be dispatched")
    end

    legacy = put_in(context(), [:binding, :reviewed_launch_snapshot], nil)

    assert {:error, :reviewed_launch_contract_required} =
             LiveAwxLaunchPreflight.attest(legacy, options(no_call, evidence_resource()))

    expired = put_in(context(), [:binding, :approval_expires_at], @now)

    assert {:error, :binding_approval_expired} =
             LiveAwxLaunchPreflight.attest(expired, options(no_call, evidence_resource()))

    not_current = put_in(context(), [:binding, :current], false)

    assert {:error, :binding_not_current} =
             LiveAwxLaunchPreflight.attest(not_current, options(no_call, evidence_resource()))

    refute_received {:evidence, _, _}
  end

  test "rejects stale, unapproved, or fingerprint-drifted membership tuples before dispatch" do
    no_call = fn _controller, _request, _opts ->
      flunk("the preflight command must not be dispatched")
    end

    for {membership, expected_error} <- [
          {put_in(context(), [:memberships, Access.at(0), :current], false),
           :stale_awx_membership},
          {put_in(context(), [:memberships, Access.at(0), :link_disposition], :quarantined),
           :unapproved_awx_membership},
          {put_in(
             context(),
             [:memberships, Access.at(0), :source_fingerprint],
             "sha256:not-a-fingerprint"
           ), :invalid_awx_preflight_membership}
        ] do
      assert {:error, ^expected_error} =
               LiveAwxLaunchPreflight.attest(membership, options(no_call, evidence_resource()))
    end

    refute_received {:evidence, _, _}
  end

  test "binds the assigned controller agent and clips evidence expiry to the reviewed approval" do
    context = put_in(context(), [:binding, :approval_expires_at], DateTime.add(@now, 10, :second))

    provenance = fn _controller, request, _opts -> {:ok, valid_result(request)} end

    assert {:ok, attestation} =
             LiveAwxLaunchPreflight.attest(context, options(provenance, evidence_resource()))

    assert attestation.expires_at == DateTime.add(@now, 10, :second)
    assert_receive {:evidence, %{expires_at: expires_at}, _}
    assert expires_at == DateTime.add(@now, 10, :second)

    bad_dispatcher = put_in(context(), [:dispatcher_identity, :agent_id], "agent-other")

    assert {:error, :dispatcher_agent_mismatch} =
             LiveAwxLaunchPreflight.attest(
               bad_dispatcher,
               options(provenance, evidence_resource())
             )

    refute_received {:evidence, _, _}
  end

  defp options(provenance, evidence) do
    [
      controller_provenance: provenance,
      evidence_resource: evidence,
      clock: fn -> @now end,
      preflight_ttl_seconds: 30
    ]
  end

  defp evidence_resource do
    fn attrs, record_opts ->
      send(self(), {:evidence, attrs, record_opts})
      {:ok, %{id: @evidence_id}}
    end
  end

  defp context do
    snapshot = reviewed_snapshot()
    {:ok, snapshot_digest} = AwxLaunchContract.digest(snapshot)

    %{
      controller: %{
        id: @controller_id,
        agent_id: @agent_id,
        enabled: true
      },
      binding: %{
        id: @binding_id,
        controller_id: @controller_id,
        binding_version: 7,
        current: true,
        approval_state: :approved,
        approval_id: @approval_id,
        approval_expires_at: DateTime.add(@now, 300, :second),
        job_template_id: 42,
        project_id: 7,
        scm_revision: String.duplicate("a", 40),
        allowed_inventory_ids: [8],
        project_update_on_launch: false,
        execution_environment_id: 9,
        credentials: [%{"id" => 101, "kind" => "ssh"}, %{"id" => 102, "kind" => "vault"}],
        run_mode_supported: true,
        check_mode_supported: false,
        ask_inventory_on_launch: true,
        ask_limit_on_launch: true,
        ask_credential_on_launch: false,
        ask_job_type_on_launch: false,
        review_metadata: %{
          "review_ticket" => "SEC-1042",
          "awx_snapshot_digest" => snapshot_digest,
          "dispatch_marker_contract" => DispatchMarkerContract.contract()
        },
        reviewed_launch_snapshot: snapshot,
        reviewed_launch_snapshot_digest: snapshot_digest
      },
      memberships: [
        %{
          id: @membership_id,
          controller_id: @controller_id,
          inventory_id: 8,
          awx_host_id: 201,
          canonical_device_uid: "device-web01",
          source_generation: 5,
          host_name: "web01.example.test",
          ansible_host: "192.168.2.22",
          enabled: true,
          current: true,
          link_disposition: :approved,
          source_fingerprint: "sha256:" <> String.duplicate("a", 64)
        }
      ],
      controller_security_snapshot: %{
        "schema" => "serviceradar.awx_controller_security_snapshot.v1",
        "controller_id" => @controller_id,
        "name" => "farm01-awx",
        "base_url" => "https://awx.farm01.example.test",
        "agent_id" => @agent_id,
        "enabled" => true,
        "insecure_skip_verify" => false,
        "credential_refs" => %{
          "sync" => "secret:awx-sync",
          "execution" => "secret:awx-execution",
          "callback" => nil
        }
      },
      dispatcher_identity: %{agent_id: @agent_id, partition_id: @partition_id}
    }
  end

  defp valid_result(request) do
    preflight = live_snapshot(request)
    {:ok, request_digest} = AwxLaunchContract.request_digest(request)
    {:ok, preflight_digest} = AwxLaunchContract.digest(preflight)

    %{
      command_id: @command_id,
      preflight: preflight,
      request_digest: request_digest,
      preflight_digest: preflight_digest,
      command_result_digest: String.duplicate("f", 64)
    }
  end

  defp with_preflight(result, preflight) do
    {:ok, preflight_digest} = AwxLaunchContract.digest(preflight)
    %{result | preflight: preflight, preflight_digest: preflight_digest}
  end

  defp expected_target_digest(request), do: AwxLaunchContract.target_snapshot_digest(request)

  defp live_snapshot(request) do
    hosts =
      Enum.map(request["selected_hosts"], fn host ->
        Map.put(
          host,
          "identity_variables_digest",
          identity_variables_digest(host["ansible_host"])
        )
      end)

    Map.put(reviewed_snapshot(), "selected_hosts", hosts)
  end

  defp refresh_identity_digest(snapshot) do
    update_in(snapshot, ["selected_hosts", Access.at(0)], fn host ->
      Map.put(host, "identity_variables_digest", identity_variables_digest(host["ansible_host"]))
    end)
  end

  defp reviewed_snapshot do
    survey = %{"spec" => marker_fields() ++ [reviewed_input_field()]}
    {:ok, survey_digest} = CanonicalJSON.digest(survey)

    %{
      "schema" => AwxLaunchContract.schema(),
      "controller_id" => @controller_id,
      "template" => %{
        "id" => "42",
        "name" => "reviewed-job",
        "modified" => "2026-07-14T20:00:00Z",
        "project_id" => "7",
        "inventory_id" => "8",
        "playbook" => "playbooks/reviewed.yml",
        "job_type" => "run",
        "scm_branch" => "main",
        "timeout" => "600",
        "forks" => "10",
        "job_slice_count" => "1",
        "allow_simultaneous" => false,
        "diff_mode" => false,
        "job_tags" => "",
        "skip_tags" => "",
        "survey_enabled" => true,
        "credential_ids" => ["101", "102"],
        "execution_environment_id" => "9",
        "prompt_on_launch" => prompt_on_launch()
      },
      "survey" => survey,
      "survey_digest" => survey_digest,
      "project" => %{
        "id" => "7",
        "name" => "serviceradar-ansible",
        "modified" => "2026-07-14T20:00:00Z",
        "scm_type" => "git",
        "scm_url" => "https://github.com/CarverAuto/serviceradar-ansible.git",
        "scm_branch" => "main",
        "scm_revision" => String.duplicate("a", 40),
        "scm_clean" => true,
        "status" => "successful"
      },
      "inventory" => %{
        "id" => "8",
        "name" => "farm01-linux",
        "modified" => "2026-07-14T20:00:00Z",
        "kind" => ""
      },
      "credentials" => [
        %{
          "id" => "101",
          "name" => "machine-ssh",
          "modified" => "2026-07-14T19:30:00Z",
          "type" => %{"id" => "1", "name" => "Machine", "kind" => "ssh"}
        },
        %{
          "id" => "102",
          "name" => "vault",
          "modified" => "2026-07-14T19:31:00Z",
          "type" => %{"id" => "2", "name" => "Vault", "kind" => "vault"}
        }
      ],
      "execution_environment" => %{
        "id" => "9",
        "name" => "serviceradar-awx-ee",
        "image_reference" =>
          "registry.carverauto.dev/serviceradar/ansible-ee@sha256:" <> String.duplicate("e", 64),
        "image_digest" => "sha256:" <> String.duplicate("e", 64)
      },
      "selected_hosts" => []
    }
  end

  defp marker_fields do
    DispatchMarkerContract.contract()
    |> Map.fetch!("fields")
    |> Enum.map(fn field ->
      %{
        "variable" => field["variable"],
        "question_name" => field["variable"],
        "type" => field["type"],
        "required" => field["required"],
        "min" => Integer.to_string(field["min"]),
        "max" => Integer.to_string(field["max"])
      }
    end)
  end

  defp reviewed_input_field do
    %{
      "variable" => "version",
      "question_name" => "Version",
      "type" => "text",
      "required" => true,
      "min" => "1",
      "max" => "20"
    }
  end

  defp prompt_on_launch do
    %{
      "ask_credential_on_launch" => false,
      "ask_diff_mode_on_launch" => false,
      "ask_execution_environment_on_launch" => false,
      "ask_forks_on_launch" => false,
      "ask_instance_groups_on_launch" => false,
      "ask_inventory_on_launch" => true,
      "ask_job_slice_count_on_launch" => false,
      "ask_job_type_on_launch" => false,
      "ask_labels_on_launch" => false,
      "ask_limit_on_launch" => true,
      "ask_scm_branch_on_launch" => false,
      "ask_skip_tags_on_launch" => false,
      "ask_tags_on_launch" => false,
      "ask_timeout_on_launch" => false,
      "ask_variables_on_launch" => false,
      "ask_verbosity_on_launch" => false
    }
  end

  defp identity_variables_digest(ansible_host) do
    {:ok, digest} = CanonicalJSON.digest(%{"ansible_host" => ansible_host})
    digest
  end
end
