defmodule ServiceRadar.TestSupport.MutationLifecycleFakeActions do
  @moduledoc false
  @behaviour ServiceRadar.Automation.Ansible.MutationLifecycleActions

  @impl true
  def get_by_idempotency_key(target_id, key) do
    phase =
      Enum.find(
        phases(),
        &(value(&1, :execution_target_id) == target_id and value(&1, :idempotency_key) == key)
      )

    {:ok, phase}
  end

  @impl true
  def list_for_target(target_id) do
    {:ok, Enum.filter(phases(), &(value(&1, :execution_target_id) == target_id))}
  end

  @impl true
  def record_phase(attrs) do
    phase = Map.put(attrs, :id, "phase-#{length(phases()) + 1}")
    Process.put(:mutation_lifecycle_phases, phases() ++ [phase])
    notify({:record_phase, phase})
    {:ok, phase}
  end

  @impl true
  def record_phase_and_hold(context, attrs, reason) do
    {:ok, phase} = record_phase(attrs)
    hold = hold(context, attrs, reason)
    notify({:place_hold, hold})
    {:ok, %{phase: phase, hold: hold}}
  end

  @impl true
  def record_unknown_and_hold(context, attrs, reason) do
    {:ok, phase} = record_phase(attrs)
    hold = hold(context, attrs, reason)
    notify({:place_hold, hold})
    {:ok, %{phase: phase, hold: hold}}
  end

  defp phases, do: Process.get(:mutation_lifecycle_phases, [])

  defp hold(context, attrs, reason) do
    %{
      canonical_device_uid: value(context.target, :canonical_device_uid),
      phase: attrs.phase,
      reason: reason,
      transaction_id: attrs.transaction_id
    }
  end

  defp notify(message), do: send(Process.get(:test_pid), message)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
