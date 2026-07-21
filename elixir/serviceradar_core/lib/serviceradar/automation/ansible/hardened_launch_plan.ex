defmodule ServiceRadar.Automation.Ansible.HardenedLaunchPlan do
  @moduledoc """
  Builds the immutable, secret-free local plan for one AWX child execution.

  This module is intentionally pure. Authorization code supplies an already
  checked actor snapshot, current AWX memberships, reviewed catalog binding,
  and active device holds. Persistence and external AWX dispatch happen only
  after this function has returned a complete plan.
  """

  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.AwxLaunchPreflightAttestation
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Automation.Ansible.Targeting
  alias ServiceRadar.Automation.Ansible.VariableSchema

  @principal_types [:human, :service_principal]
  @input_classes ["public", "internal"]
  @source_fingerprint ~r/\Asha256:[0-9a-f]{64}\z/

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
    preflight_binding = value(intent, :preflight_binding) || %{}
    actor = value(intent, :actor_snapshot) || %{}
    memberships = value(intent, :memberships) || []
    held_device_uids = MapSet.new(value(intent, :held_device_uids) || [])
    variable_schema = value(intent, :variable_schema) || []
    requested_inputs = value(intent, :inputs) || %{}
    controller_id = value(intent, :controller_id)
    controller_security_snapshot = value(intent, :controller_security_snapshot)
    job_template_id = positive_integer(value(intent, :job_template_id))
    callback_gate_available? = value(intent, :callback_gate_available) == true

    with :ok <- validate_mode(mode),
         :ok <- validate_actor(actor),
         :ok <- validate_controller_snapshot(controller_security_snapshot, controller_id),
         {:ok, membership_targets} <- validate_memberships(memberships, held_device_uids),
         :ok <- validate_target_ceiling(actor, membership_targets),
         {:ok, group_names} <- inventory_group_names(binding),
         {:ok, child} <- Targeting.build_child(membership_targets, controller_id, group_names),
         {:ok, reviewed_binding} <- Targeting.validate_binding(binding, child, mode),
         {:ok, preflight} <-
           validate_preflight_attestation(
             intent,
             preflight_binding,
             child,
             membership_targets,
             controller_security_snapshot
           ),
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
        preflight,
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
         preflight,
         job_template_id,
         inputs,
         classifications,
         callback_actions,
         dispatch_id
       ) do
    mutating? = value(intent, :mutating) != false and mode == :run
    controller_security_snapshot = value(intent, :controller_security_snapshot)

    {:ok, controller_security_digest} =
      ControllerSecuritySnapshot.digest(controller_security_snapshot)

    immutable_targets = Map.new(child.targets, &{&1.awx_host_id, &1})

    targets =
      Enum.map(membership_targets, fn target ->
        immutable_target = Map.fetch!(immutable_targets, target.awx_host_id)

        target = %{
          membership_id: target.membership_id,
          canonical_device_uid: immutable_target.device_uid,
          controller_id: immutable_target.controller_id,
          inventory_id: immutable_target.inventory_id,
          awx_host_id: immutable_target.awx_host_id,
          membership_generation: target.membership_generation,
          source_fingerprint: target.source_fingerprint,
          host_name: immutable_target.awx_host_name,
          ansible_host: immutable_target.ansible_host
        }

        Map.put(
          target,
          :snapshot_digest,
          Targeting.snapshot_digest(execution_target_snapshot(target))
        )
      end)

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
        "credentials" => binding.credentials,
        "credential_ids" => binding.credential_ids,
        "machine_credential_id" => binding.machine_credential_id,
        "ask_credential_on_launch" => binding.ask_credential_on_launch,
        "dispatch_marker_contract" => binding.dispatch_marker_contract,
        "callback_credential_type_id" => binding.callback_credential_type_id,
        "callback_credential_organization_id" => binding.callback_credential_organization_id,
        "callback_credential_injector_digest" => binding.callback_credential_injector_digest,
        "callback_credential_slot" => binding.callback_credential_slot,
        "job_type" => binding.job_type
      },
      "check_mode" => mode == :check,
      "inputs" => inputs,
      "input_classifications" => classifications,
      "targets" => Enum.map(targets, &launch_snapshot_target/1),
      "target_digest" => child.target_digest,
      "preflight_attestation" => preflight.snapshot,
      "callback_actions" => callback_actions,
      "mutating" => mutating?,
      "controller_security" => controller_security_snapshot
    }

    snapshot_digest = Targeting.snapshot_digest(snapshot)

    with {:ok, extra_vars} <-
           Targeting.launch_extra_vars(inputs, dispatch_id, snapshot_digest) do
      operation =
        Map.merge(
          %{
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
            metadata: %{
              "snapshot_digest" => snapshot_digest,
              "controller_security_snapshot" => controller_security_snapshot,
              "controller_security_digest" => controller_security_digest
            }
          },
          preflight.attrs
        )

      execution =
        Map.merge(
          %{
            controller_id: child.controller_id,
            inventory_id: child.inventory_id,
            job_template_id: job_template_id,
            project_id: binding.project_id,
            scm_revision: binding.scm_revision,
            content_sha256: binding.content_sha256,
            execution_environment_id: binding.execution_environment_id,
            machine_credential_id: binding.machine_credential_id,
            credential_snapshot: %{
              "credentials" => binding.credentials,
              "credential_ids" => binding.credential_ids,
              "dynamic_callback_slot" => value(intent, :dynamic_callback_slot)
            },
            check_mode: mode == :check,
            host_limit: child.host_limit,
            dispatch_id: dispatch_id,
            snapshot_digest: snapshot_digest,
            metadata: %{
              "awx_created_by_id" => binding.awx_created_by_id,
              "target_digest" => child.target_digest,
              "controller_security_snapshot" => controller_security_snapshot,
              "controller_security_digest" => controller_security_digest
            }
          },
          preflight.attrs
        )

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
        "controller_security_digest" => controller_security_digest,
        "verb" => "awx.launch_job"
      }

      plan = %{
        operation: operation,
        execution: execution,
        targets: targets,
        launch_opts: launch_opts,
        command_context: command_context,
        snapshot: snapshot
      }

      plan =
        if callback_actions == [],
          do: plan,
          else: Map.put(plan, :callback_contract, value(intent, :callback_contract))

      {:ok, plan}
    end
  end

  defp validate_mode(mode) when mode in [:run, :check], do: :ok
  defp validate_mode(_), do: {:error, :invalid_launch_mode}

  defp validate_controller_snapshot(snapshot, controller_id) when is_map(snapshot) do
    if value(snapshot, :schema) == "serviceradar.awx_controller_security_snapshot.v1" and
         value(snapshot, :controller_id) == controller_id,
       do: :ok,
       else: {:error, :controller_security_snapshot_mismatch}
  end

  defp validate_controller_snapshot(_snapshot, _controller_id),
    do: {:error, :controller_security_snapshot_required}

  # The controller read has already completed before this pure planner runs.
  # Rebuild the request from the post-read membership tuples and the immutable
  # reviewed binding rather than trusting a caller-provided target digest.
  defp validate_preflight_attestation(
         intent,
         binding,
         child,
         membership_targets,
         controller_security_snapshot
       )
       when is_map(binding) and is_map(child) and is_list(membership_targets) do
    now = value(intent, :preflight_checked_at) || DateTime.utc_now()

    with {:ok, attestation} <-
           AwxLaunchPreflightAttestation.normalize(value(intent, :preflight_attestation)),
         :ok <- AwxLaunchPreflightAttestation.verify_fresh(attestation, now),
         :ok <- AwxLaunchPreflightAttestation.verify_binding(attestation, binding),
         {:ok, controller_security_digest} <-
           ControllerSecuritySnapshot.digest(controller_security_snapshot),
         true <-
           secure_equal(
             controller_security_digest,
             attestation["controller_security_snapshot_digest"]
           ) || {:error, :awx_preflight_controller_drift},
         {:ok, request} <- preflight_request(binding, child, membership_targets),
         {:ok, request_digest} <- AwxLaunchContract.request_digest(request),
         {:ok, target_digest} <- AwxLaunchContract.target_snapshot_digest(request),
         true <-
           secure_equal(request_digest, attestation["preflight_request_digest"]) ||
             {:error, :awx_preflight_request_drift},
         true <-
           secure_equal(target_digest, attestation["target_snapshot_digest"]) ||
             {:error, :awx_preflight_target_drift},
         {:ok, attrs} <- AwxLaunchPreflightAttestation.attrs(attestation) do
      {:ok, %{attrs: attrs, snapshot: attestation}}
    else
      false -> {:error, :awx_preflight_attestation_required}
      {:error, _reason} = error -> error
      _ -> {:error, :awx_preflight_attestation_required}
    end
  end

  defp validate_preflight_attestation(_intent, _binding, _child, _memberships, _snapshot),
    do: {:error, :awx_preflight_attestation_required}

  defp preflight_request(binding, child, membership_targets)
       when is_map(binding) and is_map(child) and is_list(membership_targets) do
    membership_by_host = Map.new(membership_targets, &{&1.awx_host_id, &1})

    with true <-
           map_size(membership_by_host) == length(child.targets) ||
             {:error, :awx_preflight_target_drift},
         {:ok, selected_hosts} <-
           Enum.reduce_while(child.targets, {:ok, []}, fn target, {:ok, hosts} ->
             case Map.fetch(membership_by_host, target.awx_host_id) do
               {:ok, membership} ->
                 host = %{
                   "membership_id" => membership.membership_id,
                   "controller_id" => target.controller_id,
                   "inventory_id" => Integer.to_string(target.inventory_id),
                   "awx_host_id" => Integer.to_string(target.awx_host_id),
                   "canonical_device_uid" => target.device_uid,
                   "host_name" => target.awx_host_name,
                   "ansible_host" => target.ansible_host,
                   "enabled" => true,
                   "membership_generation" => Integer.to_string(membership.membership_generation),
                   "source_fingerprint" => membership.source_fingerprint
                 }

                 {:cont, {:ok, [host | hosts]}}

               :error ->
                 {:halt, {:error, :awx_preflight_target_drift}}
             end
           end) do
      AwxLaunchContract.request_from(binding, Enum.reverse(selected_hosts))
    end
  end

  defp preflight_request(_binding, _child, _memberships),
    do: {:error, :awx_preflight_target_drift}

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

      "ansible.runs.launch" not in List.wrap(
        value(value(actor, :authority_ceiling), :permissions)
      ) ->
        {:error, :launch_permission_required}

      true ->
        :ok
    end
  end

  defp validate_target_ceiling(actor, targets) do
    allowed =
      actor
      |> value(:authority_ceiling)
      |> value(:target_membership_ids)
      |> List.wrap()
      |> MapSet.new()

    requested = MapSet.new(targets, & &1.membership_id)

    if MapSet.subset?(requested, allowed),
      do: :ok,
      else: {:error, :target_outside_authority_ceiling}
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
          ),
        source_fingerprint: value(membership, :source_fingerprint)
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

        not valid_source_fingerprint?(target.source_fingerprint) ->
          {:halt, {:error, :membership_source_fingerprint_required}}

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

  defp launch_snapshot_target(target) do
    %{
      controller_id: target.controller_id,
      inventory_id: target.inventory_id,
      awx_host_id: target.awx_host_id,
      device_uid: target.canonical_device_uid,
      awx_host_name: target.host_name,
      ansible_host: target.ansible_host,
      membership_id: target.membership_id,
      membership_generation: target.membership_generation,
      source_fingerprint: target.source_fingerprint
    }
  end

  defp execution_target_snapshot(target) do
    Map.take(target, [
      :membership_id,
      :canonical_device_uid,
      :controller_id,
      :inventory_id,
      :awx_host_id,
      :membership_generation,
      :source_fingerprint,
      :host_name,
      :ansible_host
    ])
  end

  defp valid_source_fingerprint?(value) when is_binary(value),
    do: Regex.match?(@source_fingerprint, value)

  defp valid_source_fingerprint?(_value), do: false

  defp secure_equal(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal(_left, _right), do: false

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
