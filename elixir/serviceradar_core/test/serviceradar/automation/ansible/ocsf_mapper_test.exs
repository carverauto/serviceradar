defmodule ServiceRadar.Automation.Ansible.OcsfMapperTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.OcsfMapper

  defp run_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        id: "run-uuid-1",
        playbook_id: "pb-uuid-1",
        controller_id: "ctrl-uuid-1",
        awx_job_id: 7331,
        schedule_id: nil,
        summary: nil
      },
      overrides
    )
  end

  describe "run_state_event/3" do
    test "succeeded run → severity 1 / status_id 1 / Success" do
      event = OcsfMapper.run_state_event(run_fixture(), :succeeded)

      assert event["class_uid"] == 6003
      assert event["class_name"] == "Application Activity"
      assert event["category_uid"] == 6
      assert event["severity_id"] == 1
      assert event["status_id"] == 1
      assert event["status"] == "Success"
      assert event["activity_name"] == "ansible_run_succeeded"
      assert event["metadata"]["product"]["name"] == "ServiceRadar Ansible"
      assert event["unmapped"]["ansible"]["kind"] == "run_state"
      assert event["unmapped"]["ansible"]["state"] == "succeeded"
      assert event["unmapped"]["ansible"]["run_id"] == "run-uuid-1"
      assert event["unmapped"]["ansible"]["awx_job_id"] == 7331
    end

    test "partial run → severity 3 / status_id 2 / Failure" do
      event = OcsfMapper.run_state_event(run_fixture(), :partial)
      assert event["severity_id"] == 3
      assert event["status_id"] == 2
      assert event["status"] == "Failure"
    end

    test "failed run → severity 4" do
      event = OcsfMapper.run_state_event(run_fixture(), :failed)
      assert event["severity_id"] == 4
      assert event["status_id"] == 2
    end

    test "unreachable run → severity 4" do
      event = OcsfMapper.run_state_event(run_fixture(), :unreachable)
      assert event["severity_id"] == 4
    end

    test "canceled run → status_id 2 / Other" do
      event = OcsfMapper.run_state_event(run_fixture(), :canceled)
      assert event["severity_id"] == 2
      assert event["status_id"] == 2
      assert event["status"] == "Other"
    end

    test "in-flight states use status_id 99 In Progress" do
      for state <- [:pending, :launching, :running] do
        event = OcsfMapper.run_state_event(run_fixture(), state)
        assert event["status_id"] == 99
        assert event["status"] == "In Progress"
      end
    end

    test "merges extra map into unmapped" do
      event = OcsfMapper.run_state_event(run_fixture(), :succeeded, %{"extra_key" => "x"})
      assert event["unmapped"]["extra_key"] == "x"
    end

    test "schedule_id flows through into unmapped" do
      event = OcsfMapper.run_state_event(run_fixture(%{schedule_id: "sched-1"}), :succeeded)
      assert event["unmapped"]["ansible"]["schedule_id"] == "sched-1"
    end
  end

  describe "task_result_event/4" do
    defp task_fixture do
      %{
        id: "task-uuid-1",
        awx_task_uuid: "awx-task-uuid",
        name: "Install nginx",
        action: "ansible.builtin.apt"
      }
    end

    defp target_fixture do
      %{
        id: "target-uuid-1",
        device_uid: "sr:web01",
        awx_host_name: "web01"
      }
    end

    test "ok task → severity 1 / status_id 1" do
      event =
        OcsfMapper.task_result_event(run_fixture(), task_fixture(), target_fixture(), %{
          status: :ok,
          awx_event_id: 42,
          changed: true
        })

      assert event["class_uid"] == 6003
      assert event["severity_id"] == 1
      assert event["status_id"] == 1
      assert event["activity_name"] == "ansible_task_ok"
      assert event["unmapped"]["ansible"]["kind"] == "task_result"
      assert event["unmapped"]["ansible"]["task_name"] == "Install nginx"
      assert event["unmapped"]["ansible"]["task_action"] == "ansible.builtin.apt"
      assert event["unmapped"]["ansible"]["awx_host_name"] == "web01"
      assert event["unmapped"]["ansible"]["device_uid"] == "sr:web01"
      assert event["unmapped"]["ansible"]["awx_event_id"] == 42
      assert event["unmapped"]["ansible"]["changed"] == true
    end

    test "failed task → severity 3 / status_id 2" do
      event =
        OcsfMapper.task_result_event(run_fixture(), task_fixture(), target_fixture(), %{
          status: :failed
        })

      assert event["severity_id"] == 3
      assert event["status_id"] == 2
      assert event["activity_name"] == "ansible_task_failed"
    end

    test "unreachable task → severity 4" do
      event =
        OcsfMapper.task_result_event(run_fixture(), task_fixture(), target_fixture(), %{
          status: :unreachable
        })

      assert event["severity_id"] == 4
    end

    test "skipped task → severity 1 (treated as success)" do
      event =
        OcsfMapper.task_result_event(run_fixture(), task_fixture(), target_fixture(), %{
          status: :skipped
        })

      assert event["severity_id"] == 1
      assert event["status_id"] == 1
    end

    test "message contains task name and host" do
      event =
        OcsfMapper.task_result_event(run_fixture(), task_fixture(), target_fixture(), %{
          status: :ok
        })

      assert event["message"] =~ "Install nginx"
      assert event["message"] =~ "web01"
    end

    test "accepts string-keyed task / target / result (defensive)" do
      task = %{"id" => "t1", "name" => "x", "awx_task_uuid" => "u1"}
      target = %{"id" => "tgt1", "device_uid" => "sr:x", "awx_host_name" => "host"}

      event = OcsfMapper.task_result_event(run_fixture(), task, target, %{"status" => :ok})
      assert event["unmapped"]["ansible"]["task_name"] == "x"
      assert event["unmapped"]["ansible"]["awx_host_name"] == "host"
      assert event["severity_id"] == 1
    end
  end

  describe "app_name + short_id" do
    test "app_name carries a shortened run id" do
      event = OcsfMapper.run_state_event(run_fixture(%{id: "abcdef0123456789"}), :succeeded)
      assert event["app_name"] == "AnsibleRun:abcdef01"
    end

    test "app_name handles missing run id" do
      event = OcsfMapper.run_state_event(%{}, :succeeded)
      assert event["app_name"] == "AnsibleRun:(none)"
    end
  end
end
