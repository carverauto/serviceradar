defmodule ServiceRadar.Automation.Ansible.OcsfMapper do
  @moduledoc """
  Projects Ansible run / task events into OCSF Application Activity
  (class 6003) shape so the universal observability log viewer can
  surface them alongside other system signals.

  All functions in this module are pure: they take struct-ish input
  and return a map. `EventIngestor` calls them then passes the result
  to `IngestorActions.emit_ocsf_event/1` which production routes
  through `EventBatcher.queue_event/2`.

  See openspec change `add-ansible-integration` design.md decision 3c
  ("Telemetry projects to OCSF events, no extra OTEL hop"). v1 picks
  class 6003 (Application Activity); we can re-project to a different
  class later by replaying from the structured tables if it doesn't
  fit operator search habits.
  """

  @class_uid 6003
  @class_name "Application Activity"
  @category_uid 6

  @product %{
    "name" => "ServiceRadar Ansible",
    "vendor_name" => "ServiceRadar"
  }

  @doc """
  Build an OCSF event from a `PlaybookRun` state transition.
  """
  @spec run_state_event(map(), atom(), map()) :: map()
  def run_state_event(run, new_state, extra \\ %{}) do
    {severity_id, status_id, status} = severity_for_state(new_state)

    %{
      "class_uid" => @class_uid,
      "class_name" => @class_name,
      "category_uid" => @category_uid,
      "activity_id" => 1,
      "activity_name" => "ansible_run_#{new_state}",
      "type_uid" => @class_uid * 100 + 1,
      "type_name" => "Ansible Run State Change",
      "time" => now_ms(),
      "severity_id" => severity_id,
      "status_id" => status_id,
      "status" => status,
      "message" => run_message(run, new_state),
      "metadata" => %{
        "product" => @product,
        "version" => "1.4.0"
      },
      "app_name" => app_name(run),
      "unmapped" => Map.merge(run_unmapped(run, new_state), extra)
    }
  end

  @doc """
  Build an OCSF event from a `PlaybookTaskResult` write. `run` /
  `task` / `target` carry enough context to attribute the event back
  to its source.
  """
  @spec task_result_event(map(), map(), map(), map()) :: map()
  def task_result_event(run, task, target, result) do
    status_atom = Map.get(result, :status) || Map.get(result, "status") || :ok
    {severity_id, status_id, status} = severity_for_task_outcome(status_atom)

    %{
      "class_uid" => @class_uid,
      "class_name" => @class_name,
      "category_uid" => @category_uid,
      "activity_id" => 1,
      "activity_name" => "ansible_task_#{status_atom}",
      "type_uid" => @class_uid * 100 + 2,
      "type_name" => "Ansible Task Result",
      "time" => now_ms(),
      "severity_id" => severity_id,
      "status_id" => status_id,
      "status" => status,
      "message" => task_message(task, target, status_atom),
      "metadata" => %{
        "product" => @product,
        "version" => "1.4.0"
      },
      "app_name" => app_name(run),
      "unmapped" => task_unmapped(run, task, target, result)
    }
  end

  ## Helpers ------------------------------------------------------------------

  defp severity_for_state(:succeeded), do: {1, 1, "Success"}
  defp severity_for_state(:partial), do: {3, 2, "Failure"}
  defp severity_for_state(:failed), do: {4, 2, "Failure"}
  defp severity_for_state(:unreachable), do: {4, 2, "Failure"}
  defp severity_for_state(:canceled), do: {2, 2, "Other"}
  defp severity_for_state(:running), do: {1, 99, "In Progress"}
  defp severity_for_state(:launching), do: {1, 99, "In Progress"}
  defp severity_for_state(:pending), do: {1, 99, "In Progress"}
  defp severity_for_state(_), do: {1, 0, "Unknown"}

  defp severity_for_task_outcome(:ok), do: {1, 1, "Success"}
  defp severity_for_task_outcome(:skipped), do: {1, 1, "Success"}
  defp severity_for_task_outcome(:failed), do: {3, 2, "Failure"}
  defp severity_for_task_outcome(:unreachable), do: {4, 2, "Failure"}
  defp severity_for_task_outcome(_), do: {1, 0, "Unknown"}

  defp app_name(run) do
    "AnsibleRun:" <> short_id(Map.get(run, :id))
  end

  defp run_message(run, new_state) do
    "Ansible run " <> short_id(Map.get(run, :id)) <> " → #{new_state}"
  end

  defp task_message(task, target, status_atom) do
    name = Map.get(task, :name) || Map.get(task, "name") || "(task)"
    host = Map.get(target, :awx_host_name) || Map.get(target, "awx_host_name") || "(host)"
    "Ansible task '#{name}' on #{host} → #{status_atom}"
  end

  defp run_unmapped(run, new_state) do
    %{
      "ansible" => %{
        "kind" => "run_state",
        "run_id" => Map.get(run, :id),
        "playbook_id" => Map.get(run, :playbook_id),
        "controller_id" => Map.get(run, :controller_id),
        "awx_job_id" => Map.get(run, :awx_job_id),
        "schedule_id" => Map.get(run, :schedule_id),
        "state" => Atom.to_string(new_state),
        "summary" => Map.get(run, :summary)
      }
    }
  end

  defp task_unmapped(run, task, target, result) do
    %{
      "ansible" => %{
        "kind" => "task_result",
        "run_id" => Map.get(run, :id),
        "playbook_id" => Map.get(run, :playbook_id),
        "controller_id" => Map.get(run, :controller_id),
        "awx_job_id" => Map.get(run, :awx_job_id),
        "task_id" => Map.get(task, :id) || Map.get(task, "id"),
        "task_name" => Map.get(task, :name) || Map.get(task, "name"),
        "task_action" => Map.get(task, :action) || Map.get(task, "action"),
        "awx_task_uuid" => Map.get(task, :awx_task_uuid) || Map.get(task, "awx_task_uuid"),
        "target_id" => Map.get(target, :id) || Map.get(target, "id"),
        "device_uid" => Map.get(target, :device_uid) || Map.get(target, "device_uid"),
        "awx_host_name" => Map.get(target, :awx_host_name) || Map.get(target, "awx_host_name"),
        "awx_event_id" => Map.get(result, :awx_event_id) || Map.get(result, "awx_event_id"),
        "changed" => !!(Map.get(result, :changed) || Map.get(result, "changed"))
      }
    }
  end

  defp short_id(nil), do: "(none)"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(other), do: to_string(other)

  defp now_ms, do: System.system_time(:millisecond)
end
