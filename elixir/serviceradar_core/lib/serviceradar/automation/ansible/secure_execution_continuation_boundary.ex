defmodule ServiceRadar.Automation.Ansible.SecureExecutionContinuationBoundary do
  @moduledoc """
  Verifies the durable controller and edge boundary for an existing AWX child.

  Read, reconciliation, and cancellation may outlive the launch preflight TTL.
  They still require matching immutable snapshots and independent evidence.
  This verifier must never authorize a new job launch.
  """

  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot

  def verify(resources, attempt, now, opts \\ []) do
    if attestation_present?(resources) do
      verify_attested(resources, attempt, now, opts)
    else
      verify_legacy(resources, attempt)
    end
  end

  defp verify_attested(resources, attempt, now, opts) do
    verification_opts =
      case Keyword.fetch(opts, :preflight_evidence_reader) do
        {:ok, reader} -> [evidence_reader: reader]
        :error -> []
      end

    with {:ok, attestation} <-
           AwxLaunchPreflightAttestation.verify_persisted_for_cleanup(
             resources.operation,
             resources.execution,
             resources.controller,
             now,
             verification_opts
           ) do
      AwxLaunchPreflightAttestation.verify_dispatch_principal(
        attestation,
        attempt.dispatch_agent_id,
        attempt.dispatch_partition_id
      )
    end
  end

  defp verify_legacy(resources, attempt) do
    metadata = value(resources.execution, :metadata) || %{}

    with partition when is_binary(partition) and partition != "" <-
           value(metadata, :dispatch_partition_id),
         true <- partition == attempt.dispatch_partition_id,
         :ok <-
           ControllerSecuritySnapshot.verify(
             resources.controller,
             value(metadata, :controller_security_snapshot)
           ) do
      :ok
    else
      false -> {:error, :secure_execution_dispatch_partition_drift}
      {:error, _reason} = error -> error
      _ -> {:error, :secure_execution_dispatch_partition_required}
    end
  end

  defp attestation_present?(resources) do
    Enum.any?([resources.operation, resources.execution], fn resource ->
      snapshot = value(resource, :immutable_launch_snapshot)

      not is_nil(value(resource, :preflight_evidence_id)) or
        not is_nil(value(resource, :immutable_launch_snapshot_digest)) or
        snapshot not in [nil, %{}]
    end)
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
