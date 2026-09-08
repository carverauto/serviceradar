defmodule ServiceRadar.TestSupport.ExecutionLifecycleFakeActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.ExecutionLifecycleActions

  @impl true
  def bind_accepted_job(execution, snapshot) do
    notify({:bind_accepted_job, execution, snapshot})

    case Process.get(:execution_lifecycle_bind_result) do
      nil ->
        {:ok,
         execution
         |> Map.put(:awx_job_id, snapshot["awx_job_id"])
         |> Map.put(:accepted_job_snapshot, snapshot)
         |> Map.put(:state, :launching)}

      result ->
        result
    end
  end

  @impl true
  def mark_scope_verified(execution, targets, evidence) do
    notify({:mark_scope_verified, execution, targets, evidence})

    case Process.get(:execution_lifecycle_scope_result) do
      nil -> {:ok, Map.put(execution, :state, :scope_verified)}
      result -> result
    end
  end

  @impl true
  def reject_scope(execution, targets, diagnostics) do
    notify({:reject_scope, execution, targets, diagnostics})
    :ok
  end

  defp notify(message), do: send(Process.get(:test_pid), message)
end
