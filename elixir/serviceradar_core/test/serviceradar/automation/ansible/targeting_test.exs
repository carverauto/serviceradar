defmodule ServiceRadar.Automation.Ansible.TargetingTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract
  alias ServiceRadar.Automation.Ansible.Targeting

  defp membership(overrides \\ %{}) do
    Map.merge(
      %{
        controller_id: "controller-1",
        inventory_id: 34,
        awx_host_id: 7,
        device_uid: "sr:device-7",
        awx_host_name: "farm01-pve01",
        ansible_host: "192.168.2.22"
      },
      overrides
    )
  end

  describe "build_child/2" do
    test "builds a stable exact literal limit and target digest" do
      first = membership(%{awx_host_id: 8, device_uid: "sr:b", awx_host_name: "host-b"})
      second = membership(%{awx_host_id: 7, device_uid: "sr:a", awx_host_name: "host-a"})

      assert {:ok, plan} = Targeting.build_child([first, second], "controller-1", [])
      assert plan.inventory_id == 34
      assert plan.host_limit == "host-a,host-b"
      assert Enum.map(plan.targets, & &1.awx_host_id) == [7, 8]
      assert plan.target_digest =~ ~r/\A[0-9a-f]{64}\z/

      assert {:ok, reordered} = Targeting.build_child([second, first], "controller-1", [])
      assert reordered.target_digest == plan.target_digest
      assert reordered.host_limit == plan.host_limit
    end

    test "rejects Ansible pattern and delimiter characters" do
      unsafe = ["all", "host,other", "group:&prod", "!host", "web*", "@retry", "host name"]

      refute Targeting.literal_host_token?("all")
      refute Targeting.literal_host_token?("ungrouped")

      for host_name <- unsafe do
        assert {:error, {:unsafe_awx_host_name, ^host_name}} =
                 Targeting.build_child(
                   [membership(%{awx_host_name: host_name})],
                   "controller-1",
                   []
                 )
      end
    end

    test "rejects a literal host token that also names an inventory group" do
      assert {:error, {:awx_group_name_collision, "farm01-pve01"}} =
               Targeting.build_child([membership()], "controller-1", ["farm01-pve01"])
    end

    test "rejects missing tuple fields instead of falling back" do
      assert {:error, :inventory_id_required} =
               Targeting.build_child([membership(%{inventory_id: nil})], "controller-1", [])

      assert {:error, :awx_host_id_required} =
               Targeting.build_child([membership(%{awx_host_id: nil})], "controller-1", [])

      assert {:error, :device_uid_required} =
               Targeting.build_child([membership(%{device_uid: nil})], "controller-1", [])
    end

    test "rejects controller and inventory mixing" do
      assert {:error, :mixed_controllers} =
               Targeting.build_child(
                 [membership(), membership(%{controller_id: "controller-2", awx_host_id: 8})],
                 "controller-1",
                 []
               )

      assert {:error, :mixed_inventories} =
               Targeting.build_child(
                 [membership(), membership(%{inventory_id: 35, awx_host_id: 8})],
                 "controller-1",
                 []
               )
    end

    test "rejects duplicate source identities and canonical devices" do
      assert {:error, :duplicate_device_uid} =
               Targeting.build_child(
                 [membership(), membership(%{awx_host_id: 8, awx_host_name: "other"})],
                 "controller-1",
                 []
               )

      assert {:error, :duplicate_awx_host_id} =
               Targeting.build_child(
                 [membership(), membership(%{device_uid: "sr:other", awx_host_name: "other"})],
                 "controller-1",
                 []
               )

      assert {:error, :duplicate_awx_host_name} =
               Targeting.build_child(
                 [membership(), membership(%{device_uid: "sr:other", awx_host_id: 8})],
                 "controller-1",
                 []
               )
    end
  end

  describe "launch_extra_vars/3" do
    test "adds typed server-owned markers" do
      digest = String.duplicate("a", 64)

      assert {:ok, vars} =
               Targeting.launch_extra_vars(%{"version" => "1.2.3"}, "dispatch-1", digest)

      assert vars == %{
               "version" => "1.2.3",
               "serviceradar_dispatch_id" => "dispatch-1",
               "serviceradar_snapshot_digest" => digest
             }
    end

    test "callers cannot override markers" do
      digest = String.duplicate("a", 64)

      assert {:error, :reserved_launch_input} =
               Targeting.launch_extra_vars(
                 %{"serviceradar_dispatch_id" => "caller"},
                 "server",
                 digest
               )
    end

    test "requires a lowercase SHA-256 snapshot digest" do
      assert {:error, :invalid_snapshot_digest} =
               Targeting.launch_extra_vars(%{}, "dispatch-1", "ABC")
    end
  end

  describe "verify_job_scope/4" do
    test "requires exact retained markers, inventory, limit, and host IDs" do
      assert {:ok, plan} = Targeting.build_child([membership()], "controller-1", [])

      job = %{
        inventory_id: 34,
        host_limit: "farm01-pve01",
        dispatch_markers: %{
          "serviceradar_dispatch_id" => "dispatch-1",
          "serviceradar_snapshot_digest" => plan.target_digest
        }
      }

      summaries = [%{"host_id" => 7, "host_name" => "farm01-pve01"}]
      assert :ok = Targeting.verify_job_scope(plan, job, summaries, "dispatch-1")
    end

    test "fails closed on marker or host-summary mismatch" do
      assert {:ok, plan} = Targeting.build_child([membership()], "controller-1", [])

      job = %{
        inventory_id: 34,
        host_limit: "farm01-pve01",
        dispatch_markers: %{
          "serviceradar_dispatch_id" => "wrong",
          "serviceradar_snapshot_digest" => plan.target_digest
        }
      }

      summaries = [%{"host_id" => 7, "host_name" => "farm01-pve01"}]

      assert {:error, :accepted_dispatch_id_mismatch} =
               Targeting.verify_job_scope(plan, job, summaries, "dispatch-1")

      corrected = put_in(job, [:dispatch_markers, "serviceradar_dispatch_id"], "dispatch-1")

      assert {:error, :job_host_scope_mismatch} =
               Targeting.verify_job_scope(
                 plan,
                 corrected,
                 [%{"host_id" => 8, "host_name" => "farm01-pve01"}],
                 "dispatch-1"
               )
    end

    test "allows unobserved markers when the rest of the launch contract matches" do
      assert {:ok, plan} = Targeting.build_child([membership()], "controller-1", [])

      job = %{
        inventory_id: 34,
        host_limit: "farm01-pve01",
        dispatch_markers: %{}
      }

      summaries = [%{"host_id" => 7, "host_name" => "farm01-pve01"}]
      assert :ok = Targeting.verify_job_scope(plan, job, summaries, "dispatch-1")
    end
  end

  describe "validate_binding/3" do
    defp reviewed_binding(overrides \\ %{}) do
      Map.merge(
        %{
          approval_state: "approved",
          inventory_id: 34,
          ask_limit_on_launch: true,
          dispatch_markers_retained: true,
          dispatch_marker_contract: DispatchMarkerContract.contract(),
          project_update_on_launch: false,
          project_id: 3,
          scm_revision: String.duplicate("a", 40),
          content_sha256: String.duplicate("b", 64),
          execution_environment_id: 4,
          credential_ids: [5],
          credentials: [%{"id" => 5, "kind" => "ssh"}],
          machine_credential_id: 5,
          job_type: "run",
          awx_created_by_id: 11,
          inventory_group_names: ["linux"]
        },
        overrides
      )
    end

    test "accepts an immutable reviewed run binding" do
      assert {:ok, plan} = Targeting.build_child([membership()], "controller-1", ["linux"])
      assert {:ok, validated} = Targeting.validate_binding(reviewed_binding(), plan, :run)
      assert validated.scm_revision == String.duplicate("a", 40)
      assert validated.credential_ids == [5]
      assert validated.credentials == [%{"id" => 5, "kind" => "ssh"}]
      assert validated.awx_created_by_id == 11
    end

    test "rejects mutable or incompletely bound templates" do
      assert {:ok, plan} = Targeting.build_child([membership()], "controller-1", [])

      assert {:error, :binding_project_is_mutable} =
               Targeting.validate_binding(
                 reviewed_binding(%{project_update_on_launch: true}),
                 plan,
                 :run
               )

      assert {:error, :binding_scm_revision_not_immutable} =
               Targeting.validate_binding(reviewed_binding(%{scm_revision: "main"}), plan, :run)

      assert {:error, :binding_dispatch_markers_unverified} =
               Targeting.validate_binding(
                 reviewed_binding(%{dispatch_markers_retained: false}),
                 plan,
                 :run
               )

      assert {:error, :binding_dispatch_marker_contract_required} =
               Targeting.validate_binding(
                 reviewed_binding(%{dispatch_marker_contract: %{}}),
                 plan,
                 :run
               )

      assert {:error, :binding_job_type_mismatch} =
               Targeting.validate_binding(reviewed_binding(), plan, :check)

      assert {:error, :binding_credential_references_mismatch} =
               Targeting.validate_binding(
                 reviewed_binding(%{credentials: [%{"id" => 6, "kind" => "ssh"}]}),
                 plan,
                 :run
               )

      assert {:error, :binding_machine_credential_kind_mismatch} =
               Targeting.validate_binding(
                 reviewed_binding(%{credentials: [%{"id" => 5, "kind" => "vault"}]}),
                 plan,
                 :run
               )
    end

    test "requires the reviewed credential launch prompt only for callback bindings" do
      assert {:ok, plan} = Targeting.build_child([membership()], "controller-1", [])

      callback = %{
        callback_actions: ["remote_access.ssh_ca.bundle.read"],
        callback_credential_type_id: 91,
        callback_credential_organization_id: 2,
        callback_credential_injector_digest: String.duplicate("c", 64),
        callback_credential_slot: "ssh_ca_callback"
      }

      assert {:error, :binding_callback_credentials_not_promptable} =
               Targeting.validate_binding(reviewed_binding(callback), plan, :run)

      assert {:ok, validated} =
               Targeting.validate_binding(
                 reviewed_binding(Map.put(callback, :ask_credential_on_launch, true)),
                 plan,
                 :run
               )

      assert validated.ask_credential_on_launch == true
      assert {:ok, ordinary} = Targeting.validate_binding(reviewed_binding(), plan, :run)
      assert ordinary.ask_credential_on_launch == false
    end
  end

  test "snapshot_digest/1 is stable across map key order" do
    first = %{targets: [%{host: 7, device: "sr:a"}], actor: %{id: "user-1"}}
    second = %{"actor" => %{"id" => "user-1"}, "targets" => [%{"device" => "sr:a", "host" => 7}]}

    assert Targeting.snapshot_digest(first) == Targeting.snapshot_digest(second)
  end
end
