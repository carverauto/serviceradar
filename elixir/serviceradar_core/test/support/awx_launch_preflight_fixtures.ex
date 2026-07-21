defmodule ServiceRadar.Automation.Ansible.AwxLaunchPreflightFixtures do
  @moduledoc false

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  @controller_id "018f0000-0000-7000-8000-000000000001"
  @binding_id "018f0000-0000-7000-8000-000000000101"
  @approval_id "018f0000-0000-7000-8000-000000000102"
  @membership_id "018f0000-0000-7000-8000-000000000201"
  @command_id "018f0000-0000-7000-8000-000000000301"
  @evidence_id "018f0000-0000-7000-8000-000000000302"
  @now ~U[2026-07-14 23:20:00.000000Z]

  def controller_id, do: @controller_id
  def binding_id, do: @binding_id
  def approval_id, do: @approval_id
  def membership_id, do: @membership_id
  def command_id, do: @command_id
  def evidence_id, do: @evidence_id
  def now, do: @now

  def controller(overrides \\ %{}) do
    Map.merge(
      %{
        id: @controller_id,
        name: "farm01-awx",
        base_url: "https://awx.example.test:443",
        agent_id: "edge-agent-1",
        enabled: true,
        sync_credential_secret_id: "018f0000-0000-7000-8000-000000000401",
        execution_credential_secret_id: "018f0000-0000-7000-8000-000000000402",
        callback_credential_secret_id: nil,
        metadata: %{}
      },
      overrides
    )
  end

  def membership(overrides \\ %{}) do
    Map.merge(
      %{
        id: @membership_id,
        controller_id: @controller_id,
        inventory_id: 8,
        awx_host_id: 201,
        canonical_device_uid: "device-web01",
        host_name: "web01.example.test",
        ansible_host: "192.168.2.22",
        source_generation: 5,
        source_fingerprint: "sha256:" <> String.duplicate("a", 64),
        current: true,
        enabled: true,
        link_disposition: :approved
      },
      overrides
    )
  end

  def reviewed_snapshot do
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

  def reviewed_digest do
    {:ok, digest} = AwxLaunchContract.digest(reviewed_snapshot())
    digest
  end

  def reviewed_binding(overrides \\ %{}) do
    snapshot = reviewed_snapshot()
    digest = reviewed_digest()

    Map.merge(
      %{
        id: @binding_id,
        controller_id: @controller_id,
        job_template_id: 42,
        binding_version: 3,
        current: true,
        approval_state: :approved,
        approval_id: @approval_id,
        approval_expires_at: DateTime.add(@now, 10 * 60, :second),
        inventory_id: 8,
        allowed_inventory_ids: [8],
        inventory_group_names: ["linux"],
        ask_inventory_on_launch: true,
        ask_limit_on_launch: true,
        ask_credential_on_launch: false,
        ask_job_type_on_launch: false,
        dispatch_markers_retained: true,
        project_update_on_launch: false,
        project_id: 7,
        scm_revision: String.duplicate("a", 40),
        content_sha256: String.duplicate("b", 64),
        execution_environment_id: 9,
        credentials: [%{"id" => 101, "kind" => "ssh"}, %{"id" => 102, "kind" => "vault"}],
        machine_credential_id: 101,
        run_mode_supported: true,
        check_mode_supported: false,
        awx_created_by_id: 11,
        input_schema: %{
          "version" => %{"type" => "text", "required" => true, "label" => "Package version"}
        },
        input_classifications: %{"version" => "internal"},
        callback_actions: [],
        reviewed_launch_snapshot: snapshot,
        reviewed_launch_snapshot_digest: digest,
        review_metadata: %{
          "review_ticket" => "SEC-1042",
          "awx_snapshot_digest" => digest,
          "dispatch_marker_contract" => DispatchMarkerContract.contract()
        }
      },
      overrides
    )
  end

  def request_host(overrides \\ %{}) do
    membership = membership(overrides)

    %{
      "membership_id" => membership.id,
      "controller_id" => membership.controller_id,
      "inventory_id" => Integer.to_string(membership.inventory_id),
      "awx_host_id" => Integer.to_string(membership.awx_host_id),
      "canonical_device_uid" => membership.canonical_device_uid,
      "host_name" => membership.host_name,
      "ansible_host" => membership.ansible_host,
      "enabled" => true,
      "membership_generation" => Integer.to_string(membership.source_generation),
      "source_fingerprint" => membership.source_fingerprint
    }
  end

  def preflight_request(reviewed_binding \\ reviewed_binding(), hosts \\ [request_host()]) do
    AwxLaunchContract.request_from(reviewed_binding, hosts)
  end

  def controller_security_snapshot(controller \\ controller()) do
    {:ok, snapshot} = ControllerSecuritySnapshot.capture(controller)
    snapshot
  end

  def attestation(overrides \\ %{}) do
    reviewed_binding = reviewed_binding()
    {:ok, request} = preflight_request(reviewed_binding)
    {:ok, request_digest} = AwxLaunchContract.request_digest(request)
    {:ok, target_digest} = AwxLaunchContract.target_snapshot_digest(request)
    {:ok, security_digest} = ControllerSecuritySnapshot.digest(controller_security_snapshot())

    Map.merge(
      %{
        schema: AwxLaunchPreflightAttestation.schema(),
        evidence_id: @evidence_id,
        command_id: @command_id,
        controller_id: @controller_id,
        dispatch_agent_id: "edge-agent-1",
        dispatch_partition_id: "farm01",
        binding_id: @binding_id,
        binding_version: 3,
        approval_id: @approval_id,
        reviewed_launch_snapshot_digest: reviewed_digest(),
        preflight_request_digest: request_digest,
        target_snapshot_digest: target_digest,
        controller_security_snapshot_digest: security_digest,
        live_launch_snapshot_digest: String.duplicate("d", 64),
        command_result_digest: String.duplicate("e", 64),
        verified_at: @now,
        expires_at: DateTime.add(@now, 60, :second)
      },
      overrides
    )
  end

  def evidence(attestation \\ attestation()) do
    %{
      id: value(attestation, :evidence_id),
      command_id: value(attestation, :command_id),
      controller_id: value(attestation, :controller_id),
      dispatch_agent_id: value(attestation, :dispatch_agent_id),
      dispatch_partition_id: value(attestation, :dispatch_partition_id),
      binding_id: value(attestation, :binding_id),
      binding_version: value(attestation, :binding_version),
      approval_id: value(attestation, :approval_id),
      reviewed_launch_snapshot_digest: value(attestation, :reviewed_launch_snapshot_digest),
      preflight_request_digest: value(attestation, :preflight_request_digest),
      target_snapshot_digest: value(attestation, :target_snapshot_digest),
      controller_security_snapshot_digest:
        value(attestation, :controller_security_snapshot_digest),
      live_launch_snapshot_digest: value(attestation, :live_launch_snapshot_digest),
      command_result_digest: value(attestation, :command_result_digest),
      verified_at: value(attestation, :verified_at),
      expires_at: value(attestation, :expires_at)
    }
  end

  def attestation_attrs(attestation \\ attestation()) do
    {:ok, attrs} = AwxLaunchPreflightAttestation.attrs(attestation)
    attrs
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

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end
