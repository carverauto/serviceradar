defmodule ServiceRadar.Automation.Ansible.Targeting do
  @moduledoc """
  Pure validation and canonicalization for exact AWX launch targets.

  AWX accepts Ansible patterns in its `limit` field. ServiceRadar intentionally
  supports only literal inventory host tokens on the hardened path, then binds
  those tokens to immutable `(controller, inventory, AWX host, device)` tuples.
  This module never falls back to hostname, address, facts, or device metadata
  when a tuple field is missing.
  """

  alias ServiceRadar.Automation.Ansible.DispatchMarkerContract

  @host_token ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/
  @sha256_hex ~r/\A[0-9a-f]{64}\z/
  @scm_revision ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @credential_kind ~r/\A[a-z][a-z0-9_.-]{0,63}\z/
  @reserved_pattern_names MapSet.new(["all", "ungrouped"])
  @reserved_input_names MapSet.new([
                          "serviceradar_dispatch_id",
                          "serviceradar_snapshot_digest"
                        ])

  @type target :: %{
          controller_id: String.t(),
          inventory_id: pos_integer(),
          awx_host_id: pos_integer(),
          device_uid: String.t(),
          awx_host_name: String.t(),
          ansible_host: String.t() | nil
        }

  @type child_plan :: %{
          controller_id: String.t(),
          inventory_id: pos_integer(),
          targets: [target()],
          host_limit: String.t(),
          target_digest: String.t()
        }

  @doc """
  Builds one inventory-bound child plan from already selected memberships.

  All tuple fields are mandatory. Targets are sorted by AWX host ID so their
  digest and limit are stable regardless of UI selection order.
  """
  @spec build_child([map()], String.t(), [String.t()]) ::
          {:ok, child_plan()} | {:error, term()}
  def build_child(memberships, controller_id, inventory_group_names)
      when is_list(memberships) and is_binary(controller_id) and is_list(inventory_group_names) do
    with :ok <- nonempty_controller(controller_id),
         {:ok, targets} <- normalize_targets(memberships),
         :ok <- require_targets(targets),
         :ok <- require_controller(targets, controller_id),
         {:ok, inventory_id} <- one_inventory(targets),
         :ok <- unique_targets(targets),
         :ok <- no_group_collisions(targets, inventory_group_names) do
      targets = Enum.sort_by(targets, & &1.awx_host_id)
      host_names = Enum.map(targets, & &1.awx_host_name)
      host_limit = Enum.join(host_names, ",")

      with :ok <- round_trip_limit(host_limit, host_names) do
        {:ok,
         %{
           controller_id: controller_id,
           inventory_id: inventory_id,
           targets: targets,
           host_limit: host_limit,
           target_digest: target_digest(targets)
         }}
      end
    end
  end

  def build_child(_memberships, _controller_id, _inventory_group_names),
    do: {:error, :invalid_target_plan}

  @doc "Returns true only for an AWX host name safe as one literal limit token."
  @spec literal_host_token?(term()) :: boolean()
  def literal_host_token?(value) when is_binary(value) do
    Regex.match?(@host_token, value) and not MapSet.member?(@reserved_pattern_names, value)
  end

  def literal_host_token?(_), do: false

  @doc """
  Merges reviewed non-secret inputs with server-owned reconciliation markers.

  Callers cannot provide either reserved marker, and the snapshot digest must
  be a lowercase SHA-256 hex value.
  """
  @spec launch_extra_vars(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def launch_extra_vars(inputs, dispatch_id, snapshot_digest)
      when is_map(inputs) and is_binary(dispatch_id) and is_binary(snapshot_digest) do
    cond do
      String.trim(dispatch_id) == "" ->
        {:error, :dispatch_id_required}

      not Regex.match?(@sha256_hex, snapshot_digest) ->
        {:error, :invalid_snapshot_digest}

      Enum.any?(Map.keys(inputs), &MapSet.member?(@reserved_input_names, to_string(&1))) ->
        {:error, :reserved_launch_input}

      true ->
        normalized = Map.new(inputs, fn {key, value} -> {to_string(key), value} end)

        {:ok,
         Map.merge(normalized, %{
           "serviceradar_dispatch_id" => dispatch_id,
           "serviceradar_snapshot_digest" => snapshot_digest
         })}
    end
  end

  def launch_extra_vars(_inputs, _dispatch_id, _snapshot_digest),
    do: {:error, :invalid_launch_inputs}

  @doc """
  Validates a reviewed catalog binding against an exact child plan.

  Mutable branches, `update_on_launch`, unverified marker retention, and
  implicit inventory/limit behavior are deliberately non-launchable.
  """
  @spec validate_binding(map(), child_plan(), :run | :check) ::
          {:ok, map()} | {:error, term()}
  def validate_binding(binding, plan, mode)
      when is_map(binding) and is_map(plan) and mode in [:run, :check] do
    scm_revision = value(binding, :scm_revision)
    content_sha256 = value(binding, :content_sha256)
    credential_ids = value(binding, :credential_ids)
    credential_refs = normalize_credential_refs(value(binding, :credentials))
    machine_credential_id = positive_integer(value(binding, :machine_credential_id))
    callback_actions = List.wrap(value(binding, :callback_actions))
    callback_type_id = positive_integer(value(binding, :callback_credential_type_id))

    callback_organization_id =
      positive_integer(value(binding, :callback_credential_organization_id))

    callback_injector_digest = value(binding, :callback_credential_injector_digest)
    callback_slot = value(binding, :callback_credential_slot)
    job_type = Atom.to_string(mode)

    dispatch_marker_contract =
      case DispatchMarkerContract.validate_contract(value(binding, :dispatch_marker_contract)) do
        {:ok, contract} -> contract
        {:error, _reason} -> nil
      end

    cond do
      value(binding, :approval_state) != "approved" ->
        {:error, :binding_not_approved}

      value(binding, :inventory_id) != plan.inventory_id ->
        {:error, :binding_inventory_mismatch}

      value(binding, :ask_limit_on_launch) != true ->
        {:error, :binding_limit_not_promptable}

      value(binding, :dispatch_markers_retained) != true ->
        {:error, :binding_dispatch_markers_unverified}

      is_nil(dispatch_marker_contract) ->
        {:error, :binding_dispatch_marker_contract_required}

      value(binding, :project_update_on_launch) != false ->
        {:error, :binding_project_is_mutable}

      not is_binary(scm_revision) or not Regex.match?(@scm_revision, scm_revision) ->
        {:error, :binding_scm_revision_not_immutable}

      not is_binary(content_sha256) or not Regex.match?(@sha256_hex, content_sha256) ->
        {:error, :binding_content_digest_required}

      is_nil(positive_integer(value(binding, :project_id))) ->
        {:error, :binding_project_required}

      is_nil(positive_integer(value(binding, :execution_environment_id))) ->
        {:error, :binding_execution_environment_required}

      not positive_integer_list?(credential_ids) ->
        {:error, :binding_credentials_required}

      credential_refs == :invalid ->
        {:error, :binding_credential_references_required}

      Enum.sort(credential_ids) != Enum.map(credential_refs, & &1["id"]) ->
        {:error, :binding_credential_references_mismatch}

      is_nil(machine_credential_id) or machine_credential_id not in credential_ids ->
        {:error, :binding_machine_credential_required}

      Enum.find(credential_refs, &(&1["id"] == machine_credential_id))["kind"] != "ssh" ->
        {:error, :binding_machine_credential_kind_mismatch}

      value(binding, :job_type) != job_type ->
        {:error, :binding_job_type_mismatch}

      is_nil(positive_integer(value(binding, :awx_created_by_id))) ->
        {:error, :binding_awx_identity_required}

      callback_actions != [] and value(binding, :ask_credential_on_launch) != true ->
        {:error, :binding_callback_credentials_not_promptable}

      not callback_contract?(
        callback_actions,
        callback_type_id,
        callback_organization_id,
        callback_injector_digest,
        callback_slot
      ) ->
        {:error, :binding_callback_contract_required}

      true ->
        {:ok,
         %{
           inventory_id: plan.inventory_id,
           project_id: positive_integer(value(binding, :project_id)),
           scm_revision: scm_revision,
           content_sha256: content_sha256,
           execution_environment_id: positive_integer(value(binding, :execution_environment_id)),
           credential_ids: Enum.sort(credential_ids),
           credentials: credential_refs,
           machine_credential_id: machine_credential_id,
           job_type: job_type,
           awx_created_by_id: positive_integer(value(binding, :awx_created_by_id)),
           ask_credential_on_launch: value(binding, :ask_credential_on_launch) == true,
           dispatch_marker_contract: dispatch_marker_contract,
           callback_actions: callback_actions,
           callback_credential_type_id: callback_type_id,
           callback_credential_organization_id: callback_organization_id,
           callback_credential_injector_digest: callback_injector_digest,
           callback_credential_slot: callback_slot,
           inventory_group_names:
             binding |> value(:inventory_group_names) |> List.wrap() |> Enum.map(&to_string/1)
         }}
    end
  end

  def validate_binding(_binding, _plan, _mode), do: {:error, :invalid_binding}

  defp callback_contract?([], nil, nil, nil, nil), do: true

  defp callback_contract?(actions, type_id, organization_id, injector_digest, slot)
       when is_list(actions) and actions != [] and is_integer(type_id) and
              is_integer(organization_id) and
              is_binary(injector_digest) and is_binary(slot) do
    length(actions) == length(Enum.uniq(actions)) and
      Enum.all?(actions, &(&1 == "remote_access.ssh_ca.bundle.read")) and
      Regex.match?(@sha256_hex, injector_digest) and slot != ""
  end

  defp callback_contract?(_actions, _type_id, _organization_id, _injector_digest, _slot),
    do: false

  @doc """
  Verifies the AWX job's retained launch scope and post-start host summaries.

  The AWX bridge normalizes job fields and host summaries before calling this
  function. Callback grants must remain pending until this returns `:ok`.
  """
  @spec verify_job_scope(child_plan(), map(), [map()], String.t()) ::
          :ok | {:error, term()}
  def verify_job_scope(plan, job, host_summaries, dispatch_id)
      when is_map(plan) and is_map(job) and is_list(host_summaries) and is_binary(dispatch_id) do
    with :ok <- same_value(job, :inventory_id, plan.inventory_id, :accepted_inventory_mismatch),
         :ok <- same_value(job, :host_limit, plan.host_limit, :accepted_limit_mismatch),
         :ok <- verify_job_markers(job, dispatch_id, plan.target_digest),
         {:ok, actual} <- normalize_host_summaries(host_summaries) do
      compare_host_summaries(plan.targets, actual)
    end
  end

  def verify_job_scope(_plan, _job, _host_summaries, _dispatch_id),
    do: {:error, :invalid_job_scope}

  @doc "Returns a deterministic digest of the immutable target tuples."
  @spec target_digest([target()]) :: String.t()
  def target_digest(targets) when is_list(targets) do
    targets
    |> Enum.map_join("\n", fn target ->
      Enum.join(
        [
          target.controller_id,
          Integer.to_string(target.inventory_id),
          Integer.to_string(target.awx_host_id),
          target.device_uid,
          target.awx_host_name,
          target.ansible_host || ""
        ],
        "\0"
      )
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns a deterministic SHA-256 digest for a public/internal snapshot."
  @spec snapshot_digest(map()) :: String.t()
  def snapshot_digest(snapshot) when is_map(snapshot) do
    snapshot
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_targets(memberships) do
    memberships
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, acc} ->
      case normalize_target(membership) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp normalize_target(membership) when is_map(membership) do
    controller_id = value(membership, :controller_id)
    inventory_id = positive_integer(value(membership, :inventory_id))
    awx_host_id = positive_integer(value(membership, :awx_host_id) || value(membership, :host_id))
    device_uid = value(membership, :device_uid)
    awx_host_name = value(membership, :awx_host_name) || value(membership, :host_name)
    ansible_host = value(membership, :ansible_host)

    cond do
      blank?(controller_id) ->
        {:error, :controller_id_required}

      is_nil(inventory_id) ->
        {:error, :inventory_id_required}

      is_nil(awx_host_id) ->
        {:error, :awx_host_id_required}

      blank?(device_uid) ->
        {:error, :device_uid_required}

      not literal_host_token?(awx_host_name) ->
        {:error, {:unsafe_awx_host_name, awx_host_name}}

      not is_nil(ansible_host) and not is_binary(ansible_host) ->
        {:error, :invalid_ansible_host}

      true ->
        {:ok,
         %{
           controller_id: controller_id,
           inventory_id: inventory_id,
           awx_host_id: awx_host_id,
           device_uid: device_uid,
           awx_host_name: awx_host_name,
           ansible_host: empty_to_nil(ansible_host)
         }}
    end
  end

  defp normalize_target(_), do: {:error, :invalid_target}

  defp nonempty_controller(controller_id) do
    if String.trim(controller_id) == "", do: {:error, :controller_id_required}, else: :ok
  end

  defp require_targets([]), do: {:error, :devices_required}
  defp require_targets(_), do: :ok

  defp require_controller(targets, controller_id) do
    if Enum.all?(targets, &(&1.controller_id == controller_id)) do
      :ok
    else
      {:error, :mixed_controllers}
    end
  end

  defp one_inventory(targets) do
    case targets |> Enum.map(& &1.inventory_id) |> Enum.uniq() do
      [inventory_id] -> {:ok, inventory_id}
      _ -> {:error, :mixed_inventories}
    end
  end

  defp unique_targets(targets) do
    checks = [
      {:duplicate_device_uid, Enum.map(targets, & &1.device_uid)},
      {:duplicate_awx_host_id, Enum.map(targets, & &1.awx_host_id)},
      {:duplicate_awx_host_name, Enum.map(targets, & &1.awx_host_name)}
    ]

    Enum.find_value(checks, :ok, fn {error, values} ->
      if length(values) == MapSet.size(MapSet.new(values)), do: false, else: {:error, error}
    end)
  end

  defp no_group_collisions(targets, inventory_group_names) do
    group_names = MapSet.new(inventory_group_names, &to_string/1)

    case Enum.find(targets, &MapSet.member?(group_names, &1.awx_host_name)) do
      nil -> :ok
      target -> {:error, {:awx_group_name_collision, target.awx_host_name}}
    end
  end

  defp same_value(map, key, expected, error) do
    if value(map, key) == expected, do: :ok, else: {:error, error}
  end

  defp verify_job_markers(job, dispatch_id, snapshot_digest) do
    dispatch_markers = value(job, :dispatch_markers)
    dispatch_marker = marker_string(dispatch_markers, :serviceradar_dispatch_id)
    snapshot_marker = marker_string(dispatch_markers, :serviceradar_snapshot_digest)

    cond do
      # AWX may ignore launch extra_vars; unobserved markers are allowed when
      # the rest of the immutable launch contract already matched.
      is_nil(dispatch_marker) and is_nil(snapshot_marker) ->
        :ok

      is_nil(dispatch_marker) or is_nil(snapshot_marker) ->
        {:error, :accepted_markers_missing}

      dispatch_marker != dispatch_id ->
        {:error, :accepted_dispatch_id_mismatch}

      snapshot_marker != snapshot_digest ->
        {:error, :accepted_snapshot_digest_mismatch}

      true ->
        :ok
    end
  end

  defp marker_string(markers, key) when is_map(markers) do
    case value(markers, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp marker_string(_markers, _key), do: nil

  defp normalize_host_summaries(summaries) do
    summaries
    |> Enum.reduce_while({:ok, []}, fn summary, {:ok, acc} ->
      host_id = positive_integer(value(summary, :awx_host_id) || value(summary, :host_id))
      host_name = value(summary, :awx_host_name) || value(summary, :host_name)

      if is_integer(host_id) and is_binary(host_name) and host_name != "" do
        {:cont, {:ok, [%{awx_host_id: host_id, awx_host_name: host_name} | acc]}}
      else
        {:halt, {:error, :invalid_job_host_summary}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.sort_by(values, & &1.awx_host_id)}
      error -> error
    end
  end

  defp compare_host_summaries(expected_targets, actual) do
    expected =
      expected_targets
      |> Enum.map(&Map.take(&1, [:awx_host_id, :awx_host_name]))
      |> Enum.sort_by(& &1.awx_host_id)

    cond do
      length(actual) != length(Enum.uniq_by(actual, & &1.awx_host_id)) ->
        {:error, :duplicate_job_host_summary}

      actual == expected ->
        :ok

      true ->
        {:error, :job_host_scope_mismatch}
    end
  end

  defp round_trip_limit(host_limit, expected) do
    actual = String.split(host_limit, ",", trim: false)

    if actual == expected and Enum.all?(actual, &literal_host_token?/1) do
      :ok
    else
      {:error, :invalid_host_limit}
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp positive_integer(_), do: nil

  defp positive_integer_list?(values) when is_list(values) and values != [] do
    Enum.all?(values, &(not is_nil(positive_integer(&1)))) and
      length(values) == MapSet.size(MapSet.new(values))
  end

  defp positive_integer_list?(_), do: false

  defp normalize_credential_refs(values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, []}, fn credential, {:ok, acc} ->
      id = positive_integer(value(credential, :id))
      kind = value(credential, :kind)

      if is_integer(id) and is_binary(kind) and Regex.match?(@credential_kind, kind) do
        {:cont, {:ok, [%{"id" => id, "kind" => kind} | acc]}}
      else
        {:halt, :invalid}
      end
    end)
    |> case do
      {:ok, credentials} ->
        credentials = Enum.sort_by(credentials, & &1["id"])
        ids = Enum.map(credentials, & &1["id"])
        if length(ids) == MapSet.size(MapSet.new(ids)), do: credentials, else: :invalid

      :invalid ->
        :invalid
    end
  end

  defp normalize_credential_refs(_values), do: :invalid

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical_term(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
