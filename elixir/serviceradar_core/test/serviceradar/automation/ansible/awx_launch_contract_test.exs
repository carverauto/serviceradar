defmodule ServiceRadar.Automation.Ansible.AwxLaunchContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.CallbackGrants.CanonicalJSON

  test "normalizes, digests, and compares the complete v1 plugin projection" do
    snapshot = valid_snapshot()

    assert {:ok, ^snapshot} = AwxLaunchContract.normalize(snapshot)
    assert {:ok, digest} = AwxLaunchContract.digest(snapshot)
    assert {:ok, ^snapshot} = AwxLaunchContract.verify(snapshot, digest)
    assert AwxLaunchContract.equivalent?(snapshot, snapshot)

    refute AwxLaunchContract.equivalent?(
             snapshot,
             put_in(snapshot, ["template", "timeout"], "901")
           )
  end

  test "rejects atom keys, floats, unknown fields, and secret material" do
    snapshot = valid_snapshot()

    assert {:error, :awx_launch_contract_keys_must_be_strings} =
             AwxLaunchContract.validate(Map.put(snapshot, :schema, AwxLaunchContract.schema()))

    assert {:error, :awx_launch_contract_floats_forbidden} =
             AwxLaunchContract.validate(put_in(snapshot, ["template", "timeout"], 1.0))

    assert {:error, :invalid_awx_launch_contract_fields} =
             AwxLaunchContract.validate(Map.put(snapshot, "unreviewed", true))

    assert {:error, :awx_launch_contract_must_be_secret_free} =
             AwxLaunchContract.validate(
               put_in(snapshot, ["template", "name"], "-----BEGIN OPENSSH PRIVATE KEY-----")
             )
  end

  test "rejects UUID binaries that Ecto normalizes instead of preserving exactly" do
    raw_uuid = "abcdefghijklmnop"
    assert {:ok, canonical_uuid} = Ecto.UUID.cast(raw_uuid)
    refute canonical_uuid == raw_uuid

    assert {:error, :invalid_awx_controller_id} =
             valid_snapshot()
             |> Map.put("controller_id", raw_uuid)
             |> AwxLaunchContract.validate()
  end

  test "matches the plugin's AWX ID and template numeric bounds" do
    snapshot = valid_snapshot()

    assert {:error, :invalid_awx_resource_id} =
             snapshot
             |> put_in(["template", "id"], "2147483648")
             |> AwxLaunchContract.validate()

    assert {:error, :invalid_awx_numeric_setting} =
             snapshot
             |> put_in(["template", "timeout"], "604801")
             |> AwxLaunchContract.validate()

    assert {:error, :invalid_awx_numeric_setting} =
             snapshot
             |> put_in(["template", "forks"], "10001")
             |> AwxLaunchContract.validate()

    assert {:error, :invalid_awx_numeric_setting} =
             snapshot
             |> put_in(["template", "job_slice_count"], "1001")
             |> AwxLaunchContract.validate()

    request = valid_request(snapshot)

    assert {:error, :invalid_awx_resource_id} =
             request
             |> put_in(["selected_hosts", Access.at(0), "membership_generation"], "2147483648")
             |> AwxLaunchContract.validate_request()
  end

  test "requires plugin-normalized target host and address spellings" do
    request = valid_request(valid_snapshot())

    assert {:ok, _request} = AwxLaunchContract.validate_request(request)

    assert {:error, :invalid_awx_selected_host_name} =
             request
             |> put_in(["selected_hosts", Access.at(0), "host_name"], "Web01.Example.Test")
             |> AwxLaunchContract.validate_request()

    assert {:error, :invalid_awx_selected_host_name} =
             request
             |> put_in(["selected_hosts", Access.at(0), "host_name"], "all")
             |> AwxLaunchContract.validate_request()

    assert {:error, :invalid_awx_selected_host_address} =
             request
             |> put_in(["selected_hosts", Access.at(0), "ansible_host"], "HOST.EXAMPLE.TEST")
             |> AwxLaunchContract.validate_request()

    assert {:error, :invalid_awx_selected_host_address} =
             request
             |> put_in(["selected_hosts", Access.at(0), "ansible_host"], "[fe80::1]")
             |> AwxLaunchContract.validate_request()

    assert {:ok, _request} =
             request
             |> put_in(["selected_hosts", Access.at(0), "host_name"], "web-01.example_test")
             |> put_in(["selected_hosts", Access.at(0), "ansible_host"], "fe80::1")
             |> AwxLaunchContract.validate_request()
  end

  test "rejects control, format, line-separator, and paragraph-separator text" do
    for forbidden <- ["\u0001", "\u200E", "\u2028", "\u2029"] do
      assert {:error, :invalid_awx_launch_contract_text} =
               valid_snapshot()
               |> put_in(["template", "name"], "reviewed#{forbidden}job")
               |> AwxLaunchContract.validate()
    end
  end

  test "requires the complete restricted survey marker contract and disables unsupported prompts" do
    snapshot = valid_snapshot()

    assert {:error, :awx_dispatch_marker_survey_incomplete} =
             snapshot
             |> put_in(["survey", "spec"], [])
             |> refresh_survey_digest()
             |> AwxLaunchContract.validate()

    assert {:error, :unsupported_awx_prompt_enabled} =
             AwxLaunchContract.validate(
               put_in(snapshot, ["template", "prompt_on_launch", "ask_tags_on_launch"], true)
             )
  end

  test "requires a full reviewed snapshot on the binding and cross-checks binding references" do
    snapshot = valid_snapshot()
    {:ok, digest} = AwxLaunchContract.digest(snapshot)
    binding = valid_binding(snapshot, digest)

    assert {:ok, ^snapshot} = AwxLaunchContract.from_binding(binding)
    assert AwxLaunchContract.launchable?(binding)

    assert {:error, :reviewed_launch_snapshot_required} =
             binding
             |> Map.put(:reviewed_launch_snapshot, nil)
             |> Map.put(:reviewed_launch_snapshot_digest, nil)
             |> AwxLaunchContract.from_binding()

    assert {:error, :review_metadata_snapshot_digest_mismatch} =
             AwxLaunchContract.from_binding(
               put_in(
                 binding,
                 [:review_metadata, "awx_snapshot_digest"],
                 String.duplicate("f", 64)
               )
             )

    assert {:error, :reviewed_launch_snapshot_binding_mismatch} =
             AwxLaunchContract.from_binding(Map.put(binding, :project_id, 999))
  end

  test "accepts the complete plugin result envelope and compares only dynamic hosts separately" do
    reviewed_snapshot = valid_snapshot()
    live_snapshot = valid_live_snapshot(reviewed_snapshot)
    {:ok, reviewed_digest} = AwxLaunchContract.digest(reviewed_snapshot)
    binding = valid_binding(reviewed_snapshot, reviewed_digest)

    request_target =
      live_snapshot["selected_hosts"]
      |> List.first()
      |> Map.delete("identity_variables_digest")

    assert {:ok, request} = AwxLaunchContract.request_from(binding, [request_target])
    assert request["schema"] == AwxLaunchContract.request_schema()
    assert {:ok, request_digest} = AwxLaunchContract.request_digest(request)

    {:ok, preflight_digest} = AwxLaunchContract.digest(live_snapshot)

    result = %{
      "schema" => AwxLaunchContract.result_schema(),
      "verb" => AwxLaunchContract.result_verb(),
      "ok" => true,
      "request_digest" => request_digest,
      "preflight" => live_snapshot,
      "preflight_digest" => preflight_digest
    }

    assert {:ok,
            %{
              preflight: ^live_snapshot,
              request_digest: ^request_digest,
              preflight_digest: ^preflight_digest
            }} = AwxLaunchContract.from_plugin_result(result)

    assert {:ok, expected_command_result_digest} = CanonicalJSON.digest(result)
    assert {:ok, ^expected_command_result_digest} = AwxLaunchContract.result_digest(result)

    expected_target_snapshot = %{
      "schema" => "serviceradar.awx_launch_target_snapshot.v1",
      "controller_id" => request["controller_id"],
      "inventory_id" => request["inventory_id"],
      "selected_hosts" => request["selected_hosts"]
    }

    assert {:ok, ^expected_target_snapshot} = AwxLaunchContract.target_snapshot(request)
    assert {:ok, expected_target_snapshot_digest} = CanonicalJSON.digest(expected_target_snapshot)

    assert {:ok, ^expected_target_snapshot_digest} =
             AwxLaunchContract.target_snapshot_digest(request)

    assert {:ok, %{preflight: ^live_snapshot}} =
             AwxLaunchContract.verify_plugin_result(result, request)

    assert :ok = AwxLaunchContract.verify_targets(request, live_snapshot)
    assert AwxLaunchContract.targets_equivalent?(request, live_snapshot)
    assert AwxLaunchContract.static_equivalent?(reviewed_snapshot, live_snapshot)
    refute AwxLaunchContract.equivalent?(reviewed_snapshot, live_snapshot)

    changed_credential =
      put_in(live_snapshot, ["credentials", Access.at(0), "modified"], "2026-07-15T20:00:00Z")

    refute AwxLaunchContract.static_equivalent?(reviewed_snapshot, changed_credential)

    assert :awx_preflight_credential_set_drift =
             AwxLaunchContract.static_drift_reason(reviewed_snapshot, changed_credential)

    changed_target =
      put_in(live_snapshot, ["selected_hosts", Access.at(0), "ansible_host"], "192.168.2.99")

    assert {:error, :awx_preflight_target_mismatch} =
             AwxLaunchContract.verify_targets(request, changed_target)

    refute AwxLaunchContract.targets_equivalent?(request, changed_target)

    assert {:error, :awx_preflight_digest_mismatch} =
             result
             |> Map.put("preflight_digest", String.duplicate("f", 64))
             |> AwxLaunchContract.from_plugin_result()

    assert {:error, :awx_preflight_selected_hosts_required} =
             result
             |> Map.put("preflight", reviewed_snapshot)
             |> Map.put("preflight_digest", digest!(reviewed_snapshot))
             |> AwxLaunchContract.from_plugin_result()

    assert {:error, :awx_preflight_request_digest_mismatch} =
             AwxLaunchContract.verify_plugin_result(
               result,
               Map.put(request, "template_id", "43")
             )

    assert {:error, :awx_preflight_result_not_ok} =
             result
             |> Map.put("ok", false)
             |> AwxLaunchContract.result_digest()
  end

  test "classifies reviewed static-contract drift without exposing AWX values" do
    reviewed = valid_snapshot()

    assert :none = AwxLaunchContract.static_drift_reason(reviewed, reviewed)

    for {expected, live} <- [
          {:awx_preflight_controller_drift,
           Map.put(reviewed, "controller_id", "018f0000-0000-7000-8000-000000000002")},
          {:awx_preflight_template_project_drift,
           put_in(reviewed, ["template", "playbook"], "playbooks/updated.yml")},
          {:awx_preflight_inventory_drift,
           put_in(reviewed, ["inventory", "name"], "farm02-linux")},
          {:awx_preflight_credential_set_drift,
           put_in(reviewed, ["credentials", Access.at(0), "name"], "machine-ssh-rotated")},
          {:awx_preflight_execution_environment_drift,
           put_in(reviewed, ["execution_environment", "name"], "serviceradar-awx-ee-v2")},
          {:awx_preflight_survey_contract_drift,
           reviewed
           |> put_in(["survey", "spec", Access.at(-1), "question_name"], "Approved version")
           |> refresh_survey_digest()},
          {:awx_preflight_prompt_policy_drift,
           put_in(reviewed, ["template", "prompt_on_launch", "ask_inventory_on_launch"], false)}
        ] do
      assert ^expected = AwxLaunchContract.static_drift_reason(reviewed, live)
    end
  end

  defp valid_snapshot do
    survey = %{"spec" => marker_fields() ++ [reviewed_input_field()]}
    {:ok, survey_digest} = CanonicalJSON.digest(survey)

    %{
      "schema" => AwxLaunchContract.schema(),
      "controller_id" => "018f0000-0000-7000-8000-000000000001",
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

  defp valid_live_snapshot(snapshot) do
    Map.put(snapshot, "selected_hosts", [valid_live_host(snapshot)])
  end

  defp valid_request(snapshot) do
    {:ok, snapshot_digest} = AwxLaunchContract.digest(snapshot)
    binding = valid_binding(snapshot, snapshot_digest)

    snapshot
    |> valid_live_snapshot()
    |> Map.fetch!("selected_hosts")
    |> Enum.map(&Map.delete(&1, "identity_variables_digest"))
    |> then(&AwxLaunchContract.request_from(binding, &1))
    |> then(fn {:ok, request} -> request end)
  end

  defp valid_live_host(snapshot) do
    %{
      "membership_id" => "018f0000-0000-7000-8000-000000000201",
      "controller_id" => snapshot["controller_id"],
      "inventory_id" => snapshot["inventory"]["id"],
      "awx_host_id" => "201",
      "canonical_device_uid" => "device-web01",
      "host_name" => "web01.example.test",
      "ansible_host" => "192.168.2.22",
      "enabled" => true,
      "membership_generation" => "5",
      "source_fingerprint" => "sha256:" <> String.duplicate("a", 64),
      "identity_variables_digest" => identity_variables_digest("192.168.2.22")
    }
  end

  defp valid_binding(snapshot, digest) do
    %{
      controller_id: snapshot["controller_id"],
      job_template_id: 42,
      project_id: 7,
      scm_revision: snapshot["project"]["scm_revision"],
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
        "awx_snapshot_digest" => digest,
        "dispatch_marker_contract" => DispatchMarkerContract.contract()
      },
      reviewed_launch_snapshot: snapshot,
      reviewed_launch_snapshot_digest: digest
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

  defp refresh_survey_digest(snapshot) do
    {:ok, digest} = CanonicalJSON.digest(snapshot["survey"])
    Map.put(snapshot, "survey_digest", digest)
  end

  defp digest!(snapshot) do
    {:ok, digest} = AwxLaunchContract.digest(snapshot)
    digest
  end

  defp identity_variables_digest(ansible_host) do
    {:ok, digest} = CanonicalJSON.digest(%{"ansible_host" => ansible_host})
    digest
  end
end
