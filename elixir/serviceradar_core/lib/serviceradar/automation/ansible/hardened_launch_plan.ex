defmodule ServiceRadar.Automation.Ansible.HardenedLaunchPlan do
  @moduledoc """
  Builds the immutable, secret-free local plan for one AWX child execution.

  This module is intentionally pure. Authorization code supplies an already
  checked actor snapshot, current AWX memberships, reviewed catalog binding,
  and active device holds. Persistence and external AWX dispatch happen only
  after this function has returned a complete plan.
  """

  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.Ansible.VariableSchema

  @principal_types [:human, :service_principal]
  @input_classes ["public", "internal"]

  @type plan :: %{
          operation: map(),
          execution: map(),
          targets: [map()],
          launch_opts: map(),
          command_context: map(),
          snapshot: map()
        }

  @doc "Builds a single controller/inventory-bound child launch plan."
  @spec build(map()) :: {:ok, plan()} | {:error, term()}
  def build(intent) when is_map(intent) do
    mode = value(intent, :mode) || :run
    binding = value(intent, :binding) || %{}
    actor = value(intent, :actor_snapshot) || %{}
    memberships = value(intent, :memberships) || []
    held_device_uids = MapSet.new(value(intent, :held_device_uids) || [])
    variable_schema = value(intent, :variable_schema) || []
    requested_inputs = value(intent, :inputs) || %{}
    controller_id = value(intent, :controller_id)
    job_template_id = positive_integer(value(intent, :job_template_id))
    callback_gate_available? = value(intent, :callback_gate_available) == true

    with :ok <- validate_mode(mode),
         :ok <- validate_actor(actor),
         {:ok, membership_targets} <- validate_memberships(memberships, held_device_uids),
         {:ok, group_names} <- inventory_group_names(binding),
         {:ok, child} <- Targeting.build_child(membership_targets, controller_id, group_names),
         {:ok, reviewed_binding} <- Targeting.validate_binding(binding, child, mode),
         :ok <- require_job_template(job_template_id),
         {:ok, inputs} <-
           VariableSchema.validated_non_secret_inputs(variable_schema, requested_inputs),
         {:ok, classifications} <- input_classifications(binding, inputs),
         {:ok, callback_actions} <-
           callback_actions(binding, callback_gate_available?),
         {:ok, dispatch_id} <- dispatch_id(intent) do
      assemble(
        intent,
        actor,
        mode,
        child,
        membership_targets,
        reviewed_binding,
        job_template_id,
        inputs,
        classifications,
        callback_actions,
        dispatch_id
      )
    end
  end

  def build(_), do: {:error, :invalid_launch_intent}

  defp assemble(
         intent,
         actor,
         mode,
         child,
         membership_targets,
         binding,
         job_template_id,
         inputs,
         classifications,
         callback_actions,
         dispatch_id
       ) do
    mutating? = value(intent, :mutating) != false and mode == :run

    snapshot = %{
      "schema" => "serviceradar.ansible_launch_snapshot.v1",
      "action" => value(intent, :action),
      "actor" => public_actor_snapshot(actor),
      "approval" => value(actor, :approval_snapshot) || %{},
      "binding" => %{
        "controller_id" => child.controller_id,
        "inventory_id" => child.inventory_id,
        "job_template_id" => job_template_id,
        "project_id" => binding.project_id,
        "scm_revision" => binding.scm_revision,
        "content_sha256" => binding.content_sha256,
        "execution_environment_id" => binding.execution_environment_id,
        "credential_ids" => binding.credential_ids,
        "machine_credential_id" => binding.machine_credential_id,
        "job_type" => binding.job_type
      },
      "check_mode" => mode == :check,
      "inputs" => inputs,
      "input_classifications" => classifications,
      "targets" =>
        Enum.map(child.targets, fn target ->
          Map.take(target, [
            :controller_id,
            :inventory_id,
            :awx_host_id,
            :device_uid,
            :awx_host_name,
            :ansible_host
          ])
        end),
      "target_digest" => child.target_digest,
      "callback_actions" => callback_actions,
      "mutating" => mutating?
    }

    snapshot_digest = Targeting.snapshot_digest(snapshot)

    with {:ok, extra_vars} <-
           Targeting.launch_extra_vars(inputs, dispatch_id, snapshot_digest) do
      operation = %{
        tenant_id: value(actor, :tenant_id),
        action: value(intent, :action),
        mutating: mutating?,
        check_mode: mode == :check,
        initiator_principal_type: value(actor, :principal_type),
        initiator_principal_id: value(actor, :principal_id),
        service_principal_owner_id: value(actor, :service_principal_owner_id),
        authorization_version: value(actor, :authorization_version),
        authority_ceiling: value(actor, :authority_ceiling),
        approval_snapshot: value(actor, :approval_snapshot) || %{},
        request_source: value(intent, :request_source),
        declared_inputs: inputs,
        input_classifications: classifications,
        input_digest: Targeting.snapshot_digest(%{"inputs" => inputs}),
        target_digest: child.target_digest,
        callback_actions: callback_actions,
        run_budget: value(actor, :run_budget) || %{},
        metadata: %{"snapshot_digest" => snapshot_digest}
      }

      execution = %{
        controller_id: child.controller_id,
        inventory_id: child.inventory_id,
        job_template_id: job_template_id,
        project_id: binding.project_id,
        scm_revision: binding.scm_revision,
        content_sha256: binding.content_sha256,
        execution_environment_id: binding.execution_environment_id,
        machine_credential_id: binding.machine_credential_id,
        credential_snapshot: %{
          "credential_ids" => binding.credential_ids,
          "dynamic_callback_slot" => value(intent, :dynamic_callback_slot)
        },
        check_mode: mode == :check,
        host_limit: child.host_limit,
        dispatch_id: dispatch_id,
        snapshot_digest: snapshot_digest,
        metadata: %{
          "awx_created_by_id" => binding.awx_created_by_id,
          "target_digest" => child.target_digest
        }
      }

      targets =
        Enum.map(membership_targets, fn target ->
          immutable_target = Enum.find(child.targets, &(&1.awx_host_id == target.awx_host_id))

          %{
            membership_id: target.membership_id,
            canonical_device_uid: immutable_target.device_uid,
            controller_id: immutable_target.controller_id,
            inventory_id: immutable_target.inventory_id,
            awx_host_id: immutable_target.awx_host_id,
            membership_generation: target.membership_generation,
            host_name: immutable_target.awx_host_name,
            ansible_host: immutable_target.ansible_host,
            snapshot_digest: Targeting.snapshot_digest(immutable_target)
          }
        end)

      launch_opts = %{
        inventory_id: child.inventory_id,
        host_limit: child.host_limit,
        extra_vars: extra_vars,
        credential_ids: binding.credential_ids,
        execution_environment_id: binding.execution_environment_id,
        job_type: binding.job_type
      }

      command_context = %{
        "controller_id" => child.controller_id,
        "inventory_id" => child.inventory_id,
        "dispatch_id" => dispatch_id,
        "snapshot_digest" => snapshot_digest,
        "target_digest" => child.target_digest,
        "verb" => "awx.launch_job"
      }

      {:ok,
       %{
         operation: operation,
         execution: execution,
         targets: targets,
         launch_opts: launch_opts,
         command_context: command_context,
         snapshot: snapshot
       }}
    end
  end

  defp validate_mode(mode) when mode in [:run, :check], do: :ok
  defp validate_mode(_), do: {:error, :invalid_launch_mode}

  defp validate_actor(actor) do
    principal_type = value(actor, :principal_type)
    principal_id = value(actor, :principal_id)

    cond do
      principal_type not in @principal_types ->
        {:error, :initiating_principal_required}

      blank?(principal_id) or String.starts_with?(principal_id, "system:") ->
        {:error, :initiating_principal_required}

      blank?(value(actor, :tenant_id)) ->
        {:error, :tenant_required}

      blank?(value(actor, :authorization_version)) ->
        {:error, :authorization_version_required}

      not is_map(value(actor, :authority_ceiling)) ->
        {:error, :authority_ceiling_required}

      true ->
        :ok
    end
  end

  defp validate_memberships(memberships, held_device_uids) when is_list(memberships) do
    memberships
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, acc} ->
      target = %{
        membership_id: value(membership, :id) || value(membership, :membership_id),
        controller_id: value(membership, :controller_id),
        inventory_id: value(membership, :inventory_id),
        awx_host_id: value(membership, :awx_host_id),
        device_uid: value(membership, :canonical_device_uid) || value(membership, :device_uid),
        awx_host_name: value(membership, :host_name) || value(membership, :awx_host_name),
        ansible_host: value(membership, :ansible_host),
        membership_generation:
          positive_integer(
            value(membership, :source_generation) ||
              value(membership, :membership_generation)
          )
      }

      cond do
        value(membership, :current) != true ->
          {:halt, {:error, :stale_awx_membership}}

        value(membership, :enabled) != true ->
          {:halt, {:error, :disabled_awx_membership}}

        value(membership, :link_disposition) not in [:approved, "approved"] ->
          {:halt, {:error, :unapproved_awx_membership}}

        blank?(target.membership_id) ->
          {:halt, {:error, :membership_id_required}}

        is_nil(target.membership_generation) ->
          {:halt, {:error, :membership_generation_required}}

        MapSet.member?(held_device_uids, target.device_uid) ->
          {:halt, {:error, {:target_held, target.device_uid}}}

        true ->
          {:cont, {:ok, [target | acc]}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp validate_memberships(_memberships, _held), do: {:error, :devices_required}

  defp inventory_group_names(binding) do
    case value(binding, :inventory_group_names) do
      names when is_list(names) ->
        if Enum.all?(names, &is_binary/1),
          do: {:ok, names},
          else: {:error, :binding_inventory_groups_required}

      _ ->
        {:error, :binding_inventory_groups_required}
    end
  end

  defp require_job_template(value) when is_integer(value) and value > 0, do: :ok
  defp require_job_template(_), do: {:error, :job_template_required}

  defp input_classifications(binding, inputs) do
    declared = value(binding, :input_classifications) || %{}

    classifications =
      Map.new(inputs, fn {name, _value} ->
        {name, value(declared, name) || "internal"}
      end)

    if Enum.all?(classifications, fn {_name, class} -> class in @input_classes end) do
      {:ok, classifications}
    else
      {:error, :secret_input_classification_forbidden}
    end
  end

  defp callback_actions(binding, gate_available?) do
    actions = value(binding, :callback_actions) || []

    cond do
      not is_list(actions) or not Enum.all?(actions, &is_binary/1) ->
        {:error, :invalid_callback_actions}

      actions != [] and not gate_available? ->
        {:error, :callback_gate_unavailable}

      true ->
        {:ok, Enum.sort(Enum.uniq(actions))}
    end
  end

  defp dispatch_id(intent) do
    case value(intent, :dispatch_id) do
      nil ->
        {:ok, Ecto.UUID.generate()}

      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, :invalid_dispatch_id}
        end

      _ ->
        {:error, :invalid_dispatch_id}
    end
  end

  defp public_actor_snapshot(actor) do
    %{
      "principal_type" => value(actor, :principal_type),
      "principal_id" => value(actor, :principal_id),
      "tenant_id" => value(actor, :tenant_id),
      "authorization_version" => value(actor, :authorization_version),
      "authority_ceiling" => value(actor, :authority_ceiling),
      "service_principal_owner_id" => value(actor, :service_principal_owner_id)
    }
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
