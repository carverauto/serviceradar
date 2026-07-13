defmodule ServiceRadar.Automation.Ansible.SecureLaunchResolver do
  @moduledoc """
  Resolves canonical devices and a reviewed AWX playbook to one exact child.

  The resolver accepts canonical device UIDs only. It never derives execution
  identity from host names, addresses, or mutable device metadata. Every target
  must have exactly one approved, current, enabled AWX membership in one common
  controller inventory allowed by the current approved template binding.
  Ambiguity fails closed.

  Resolution is suitable for presenting readiness in a UI. Dispatch must call
  `SecureLaunchService.launch/5`, which resolves everything again before it
  delegates to `SecureChildLauncher`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.SecureLaunchResolver.AshAdapter
  alias ServiceRadar.Automation.Ansible.VariableSchema

  @max_targets 500
  @max_device_uid_bytes 1_024

  @type resolution :: %{
          playbook_id: String.t(),
          playbook_name: String.t(),
          membership_ids: [String.t()],
          device_uids: [String.t()],
          controller_id: String.t(),
          inventory_id: pos_integer(),
          job_template_id: pos_integer(),
          variables: [VariableSchema.Var.t()],
          run_mode_supported: boolean(),
          check_mode_supported: boolean(),
          binding_version: pos_integer(),
          approval_expires_at: DateTime.t()
        }

  @doc "Resolves one exact, currently approved launch child without dispatching it."
  @spec resolve(map(), [String.t()], String.t(), keyword()) ::
          {:ok, resolution()} | {:error, term()}
  def resolve(actor, device_uids, playbook_id, opts \\ [])

  def resolve(actor, device_uids, playbook_id, opts) when is_list(opts) do
    adapter = Keyword.get(opts, :adapter, AshAdapter)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, _actor_id} <- human_actor(actor),
         {:ok, device_uids} <- exact_device_uids(device_uids),
         {:ok, playbook_id} <- canonical_uuid(playbook_id, :playbook_required),
         {:ok, playbook} <- adapter.load_playbook(playbook_id, actor),
         {:ok, playbook_scope} <- reviewed_playbook(playbook, playbook_id),
         {:ok, binding} <-
           adapter.load_current_approved_binding(
             playbook_scope.controller_id,
             playbook_scope.job_template_id,
             actor
           ),
         {:ok, binding_scope} <-
           approved_binding(binding, playbook_scope, now),
         {:ok, variables} <- VariableSchema.from_binding(binding),
         {:ok, memberships_by_device} <-
           load_memberships(adapter, actor, device_uids, playbook_scope, binding_scope),
         {:ok, inventory_id, memberships} <-
           exact_common_inventory(memberships_by_device, device_uids),
         :ok <- unique_membership_ids(memberships) do
      {:ok,
       %{
         playbook_id: playbook_id,
         playbook_name: value(playbook, :name),
         membership_ids: Enum.map(memberships, &value(&1, :id)),
         device_uids: device_uids,
         controller_id: playbook_scope.controller_id,
         inventory_id: inventory_id,
         job_template_id: playbook_scope.job_template_id,
         variables: variables,
         run_mode_supported: value(binding, :run_mode_supported) == true,
         check_mode_supported: value(binding, :check_mode_supported) == true,
         binding_version: value(binding, :binding_version),
         approval_expires_at: value(binding, :approval_expires_at)
       }}
    end
  end

  def resolve(_actor, _device_uids, _playbook_id, _opts),
    do: {:error, :invalid_secure_launch_resolution}

  defp human_actor(actor) when is_map(actor) do
    actor_id = value(actor, :id)

    cond do
      SystemActor.system_actor?(actor) ->
        {:error, :human_actor_required}

      value(actor, :role) in [:system, "system"] ->
        {:error, :human_actor_required}

      value(actor, :status) not in [:active, "active"] ->
        {:error, :actor_inactive}

      true ->
        canonical_uuid(actor_id, :human_actor_required)
    end
  end

  defp human_actor(_actor), do: {:error, :human_actor_required}

  defp exact_device_uids(device_uids)
       when is_list(device_uids) and device_uids != [] and length(device_uids) <= @max_targets do
    valid? =
      Enum.all?(device_uids, fn uid ->
        is_binary(uid) and byte_size(uid) in 1..@max_device_uid_bytes and
          String.trim(uid) == uid
      end)

    cond do
      not valid? -> {:error, :invalid_canonical_device_uid}
      length(device_uids) != length(Enum.uniq(device_uids)) -> {:error, :duplicate_device_uid}
      true -> {:ok, device_uids}
    end
  end

  defp exact_device_uids([]), do: {:error, :devices_required}
  defp exact_device_uids(device_uids) when is_list(device_uids), do: {:error, :too_many_devices}
  defp exact_device_uids(_device_uids), do: {:error, :devices_required}

  defp reviewed_playbook(playbook, requested_id) when is_map(playbook) do
    with {:ok, id} <- canonical_uuid(value(playbook, :id), :playbook_identity_drift),
         {:ok, controller_id} <-
           canonical_uuid(value(playbook, :controller_id), :playbook_controller_required) do
      job_template_id = value(playbook, :awx_job_template_id)

      cond do
        id != requested_id -> {:error, :playbook_identity_drift}
        value(playbook, :source_type) not in [:awx, "awx"] -> {:error, :awx_playbook_required}
        value(playbook, :parse_status) not in [:ok, "ok"] -> {:error, :playbook_not_launchable}
        not positive_integer?(job_template_id) -> {:error, :playbook_template_required}
        true -> {:ok, %{controller_id: controller_id, job_template_id: job_template_id}}
      end
    end
  end

  defp reviewed_playbook(_playbook, _requested_id), do: {:error, :playbook_not_found}

  defp approved_binding(binding, playbook_scope, now) when is_map(binding) do
    allowed_inventory_ids = List.wrap(value(binding, :allowed_inventory_ids))
    callback_actions = List.wrap(value(binding, :callback_actions))
    expires_at = value(binding, :approval_expires_at)

    with {:ok, controller_id} <-
           canonical_uuid(value(binding, :controller_id), :binding_controller_drift) do
      cond do
        not uuid?(value(binding, :id)) ->
          {:error, :binding_identity_drift}

        controller_id != playbook_scope.controller_id ->
          {:error, :binding_controller_drift}

        value(binding, :job_template_id) != playbook_scope.job_template_id ->
          {:error, :binding_template_drift}

        value(binding, :current) != true ->
          {:error, :binding_not_current}

        value(binding, :approval_state) not in [:approved, "approved"] ->
          {:error, :binding_not_approved}

        not uuid?(value(binding, :approval_id)) ->
          {:error, :binding_approval_required}

        not match?(%DateTime{}, expires_at) or DateTime.compare(expires_at, now) != :gt ->
          {:error, :binding_approval_expired}

        not positive_integer?(value(binding, :binding_version)) ->
          {:error, :binding_version_required}

        not positive_unique_integers?(allowed_inventory_ids) ->
          {:error, :binding_inventory_required}

        value(binding, :run_mode_supported) != true and
            value(binding, :check_mode_supported) != true ->
          {:error, :binding_mode_not_approved}

        callback_actions != [] and value(binding, :ask_credential_on_launch) != true ->
          {:error, :binding_callback_credentials_not_promptable}

        true ->
          {:ok, %{allowed_inventory_ids: MapSet.new(allowed_inventory_ids)}}
      end
    end
  end

  defp approved_binding(_binding, _playbook_scope, _now), do: {:error, :binding_not_approved}

  defp load_memberships(adapter, actor, device_uids, playbook_scope, binding_scope) do
    Enum.reduce_while(device_uids, {:ok, %{}}, fn device_uid, {:ok, acc} ->
      case adapter.list_current_memberships(device_uid, actor) do
        {:ok, memberships} when is_list(memberships) ->
          candidates =
            Enum.filter(memberships, fn membership ->
              approved_membership?(
                membership,
                device_uid,
                playbook_scope.controller_id,
                binding_scope.allowed_inventory_ids
              )
            end)

          if candidates == [] do
            {:halt, {:error, {:target_not_ready, device_uid}}}
          else
            grouped = Enum.group_by(candidates, &membership_inventory_key/1)
            {:cont, {:ok, Map.put(acc, device_uid, grouped)}}
          end

        {:ok, _other} ->
          {:halt, {:error, {:membership_lookup_failed, device_uid}}}

        {:error, reason} ->
          {:halt, {:error, {:membership_lookup_failed, device_uid, reason}}}
      end
    end)
  end

  defp approved_membership?(membership, device_uid, controller_id, allowed_inventory_ids)
       when is_map(membership) do
    value(membership, :canonical_device_uid) == device_uid and
      value(membership, :current) == true and
      value(membership, :enabled) == true and
      value(membership, :link_disposition) in [:approved, "approved"] and
      value(membership, :controller_id) == controller_id and
      MapSet.member?(allowed_inventory_ids, value(membership, :inventory_id)) and
      uuid?(value(membership, :id)) and
      positive_integer?(value(membership, :inventory_id)) and
      positive_integer?(value(membership, :awx_host_id)) and
      positive_integer?(value(membership, :source_generation))
  end

  defp approved_membership?(_membership, _device_uid, _controller_id, _allowed), do: false

  defp membership_inventory_key(membership) do
    {value(membership, :controller_id), value(membership, :inventory_id)}
  end

  defp exact_common_inventory(memberships_by_device, device_uids) do
    common_keys =
      device_uids
      |> Enum.map(fn device_uid ->
        memberships_by_device |> Map.fetch!(device_uid) |> Map.keys() |> MapSet.new()
      end)
      |> intersect_all()
      |> MapSet.to_list()
      |> Enum.sort()

    case common_keys do
      [] ->
        {:error, :no_common_approved_inventory}

      [{_controller_id, inventory_id} = key] ->
        memberships =
          Enum.map(device_uids, fn device_uid ->
            memberships_by_device |> Map.fetch!(device_uid) |> Map.fetch!(key)
          end)

        case Enum.find_index(memberships, &(length(&1) != 1)) do
          nil -> {:ok, inventory_id, Enum.map(memberships, &hd/1)}
          index -> {:error, {:ambiguous_target_membership, Enum.at(device_uids, index)}}
        end

      _multiple ->
        {:error, :ambiguous_common_approved_inventory}
    end
  end

  defp intersect_all([first | rest]), do: Enum.reduce(rest, first, &MapSet.intersection/2)
  defp intersect_all([]), do: MapSet.new()

  defp unique_membership_ids(memberships) do
    ids = Enum.map(memberships, &value(&1, :id))

    if length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: {:error, :membership_identity_drift}
  end

  defp canonical_uuid(value, error) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  defp canonical_uuid(_value, error), do: {:error, error}

  defp uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp positive_unique_integers?(values) do
    values != [] and Enum.all?(values, &positive_integer?/1) and
      length(values) == length(Enum.uniq(values))
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, result} -> result
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
