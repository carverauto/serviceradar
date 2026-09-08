defmodule ServiceRadar.Inventory.Identity.Registrar do
  @moduledoc """
  Identifier registration for resolved devices: per-identifier upserts
  (atomic MACs with evidence-based confidence), register-time conflict
  resolution, and provisional-identity promotion.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.CardinalityCaps
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.MergePolicy
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Query
  require Logger

  @strong_non_mac_identifier_types [
    :agent_id,
    :armis_device_id,
    :integration_id,
    :netbox_device_id,
    :hardware_serial
  ]
  @provisional_promotion_required_repeat_count 2

  @doc """
  Register device identifiers in the device_identifiers table.
  """
  @spec register_identifiers(String.t(), Ids.strong_identifiers(), keyword()) ::
          :ok | {:error, term()}
  def register_identifiers(device_id, ids, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    partition = Ids.ids_get_partition(ids)
    query_opts = if actor, do: [actor: actor], else: []
    canonical_id = resolve_identifier_conflicts(device_id, ids, actor)

    maybe_merge_on_register(device_id, canonical_id, ids, actor)
    maybe_promote_provisional_identity(canonical_id, ids, actor, partition)

    agent_id_value = colocation_safe_agent_id(canonical_id, Ids.ids_get(ids, :agent_id), actor)

    identifiers_to_register =
      []
      |> maybe_add_identifier(canonical_id, :agent_id, agent_id_value, partition)
      |> maybe_add_identifier(
        canonical_id,
        :armis_device_id,
        Ids.ids_get(ids, :armis_id),
        partition
      )
      |> maybe_add_identifier(
        canonical_id,
        :integration_id,
        Ids.ids_get(ids, :integration_id),
        partition
      )
      |> maybe_add_identifier(
        canonical_id,
        :netbox_device_id,
        Ids.ids_get(ids, :netbox_id),
        partition
      )
      |> maybe_add_identifier(
        canonical_id,
        :hardware_serial,
        Ids.ids_get(ids, :hardware_serial),
        partition
      )
      |> add_mac_identifiers(canonical_id, ids, partition)

    results =
      Enum.map(identifiers_to_register, fn params ->
        DeviceIdentifier
        |> Ash.Changeset.for_create(:upsert, params)
        |> Ash.create(query_opts)
      end)

    CardinalityCaps.enforce(
      Enum.map(identifiers_to_register, fn params ->
        {params.device_id, params.identifier_type}
      end)
    )

    results
    |> Enum.filter(&match?({:error, _}, &1))
    |> handle_identifier_errors()
  end

  @doc """
  Repoint an agent's `agent_id` identifier to the agent's canonical device.

  Identifier ownership never changes via upsert side effects; this is the
  explicit, audited repair used at enrollment (and by the periodic link
  repair job) when a stale identifier row points at a device that is not
  actually bound to the agent.
  """
  @spec repair_agent_identifier(String.t(), String.t(), term()) :: :ok
  def repair_agent_identifier(agent_id, device_id, actor)
      when is_binary(agent_id) and is_binary(device_id) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceIdentifier
    |> Ash.Query.filter(identifier_type == :agent_id and identifier_value == ^agent_id)
    |> Ash.read(query_opts)
    |> case do
      {:ok, identifiers} ->
        losing_device_ids =
          identifiers
          |> Enum.reject(&(&1.device_id == device_id))
          |> Enum.reduce([], fn identifier, repaired ->
            # Only repair rows whose current owner is not genuinely bound to
            # this agent (a live device whose agent_id attribute matches keeps
            # its identifier; resolution-time trust handles that case).
            owner_bound? =
              case Device.get_by_uid(identifier.device_id, false, actor: actor) do
                {:ok, %Device{agent_id: owner_agent}} ->
                  owner_agent |> to_string() |> String.trim() == agent_id

                _ ->
                  false
              end

            if owner_bound? do
              repaired
            else
              identifier
              |> Ash.Changeset.for_update(:reassign_device, %{device_id: device_id})
              |> Ash.update(query_opts)
              |> case do
                {:ok, _} ->
                  Logger.info(
                    "Repaired stale agent identifier #{agent_id}: " <>
                      "#{identifier.device_id} -> #{device_id}"
                  )

                  :telemetry.execute(
                    [:serviceradar, :identity_reconciler, :agent_identifier, :repaired],
                    %{count: 1},
                    %{agent_id: agent_id, from: identifier.device_id, to: device_id}
                  )

                  [identifier.device_id | repaired]

                {:error, error} ->
                  Logger.warning("Agent identifier repair failed: #{inspect(error)}")
                  repaired
              end
            end
          end)

        # Identifier ownership moved, so both sides changed composition: each
        # stale owner lost the agent identity and this device gained it. Hoisted
        # out of the loop -- N identifiers stripped from one device is one
        # transition, not N -- and only for repairs that actually landed.
        bump_repaired_devices(losing_device_ids, device_id, actor)

        :ok

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Agent identifier repair failed: #{inspect(e)}")
      :ok
  end

  def repair_agent_identifier(_agent_id, _device_id, _actor), do: :ok

  defp bump_repaired_devices([], _target_device_id, _actor), do: :ok

  defp bump_repaired_devices(losing_device_ids, target_device_id, actor) do
    losing_device_ids
    |> Enum.uniq()
    |> Enum.each(&bump_device_identity_revision(&1, actor))

    bump_device_identity_revision(target_device_id, actor)
  end

  # Best-effort, matching this function's rescue-and-continue posture: a failed
  # bump must not undo a repair that already landed. A uid that no longer resolves
  # to a live device is skipped -- :soft_delete already carried its bump.
  defp bump_device_identity_revision(device_uid, actor) do
    actor = actor || SystemActor.system(:identity_registrar)

    case Device.get_by_uid(device_uid, false, actor: actor) do
      {:ok, %Device{} = device} ->
        case Device.bump_identity_revision(device, actor: actor) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.warning(
              "Failed to bump identity revision for #{device_uid}: #{inspect(error)}"
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  # A device carries at most one connected agent's identity. If the resolved
  # device already holds a DIFFERENT agent's agent_id identifier, refuse to
  # co-locate (the arriving agent keeps its own device via resolution-time
  # trusted matching) — silently stacking agent identities is how five worker
  # agents ended up sharing one chimera device.
  defp colocation_safe_agent_id(_canonical_id, nil, _actor), do: nil

  defp colocation_safe_agent_id(canonical_id, agent_id, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceIdentifier
    |> Ash.Query.filter(device_id == ^canonical_id and identifier_type == :agent_id)
    |> Ash.read(query_opts)
    |> case do
      {:ok, identifiers} ->
        existing = Enum.map(identifiers, & &1.identifier_value)

        if existing == [] or agent_id in existing do
          agent_id
        else
          Logger.warning(
            "Refusing to co-locate agent #{agent_id} on device #{canonical_id} " <>
              "already bound to agent(s) #{inspect(existing)}"
          )

          :telemetry.execute(
            [:serviceradar, :identity_reconciler, :agent_colocation, :refused],
            %{count: 1},
            %{agent_id: agent_id, device_id: canonical_id, existing_agents: existing}
          )

          nil
        end

      _ ->
        agent_id
    end
  rescue
    e ->
      Logger.warning("Agent co-location check failed: #{inspect(e)}")
      agent_id
  end

  defp maybe_promote_provisional_identity(_device_id, ids, _actor, _partition)
       when not is_map(ids), do: :ok

  defp maybe_promote_provisional_identity(device_id, ids, actor, partition) do
    case Device.get_by_uid(device_id, false, actor: actor) do
      {:ok, %Device{} = device} ->
        metadata = Map.new(device.metadata || %{})

        if Map.get(metadata, "identity_state") == "provisional" do
          evaluate_and_maybe_promote_provisional_identity(device, metadata, ids, actor, partition)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp evaluate_and_maybe_promote_provisional_identity(device, metadata, ids, actor, partition) do
    current_non_mac_types = current_non_mac_strong_types(ids)
    existing_non_mac_types = existing_non_mac_identifier_types(device.uid, partition, actor)
    distinct_types = Enum.uniq(current_non_mac_types ++ existing_non_mac_types)
    distinct_type_names = Enum.map(distinct_types, &Atom.to_string/1)
    current_type_names = Enum.map(current_non_mac_types, &Atom.to_string/1)
    total_sightings = non_mac_sighting_total(metadata, current_non_mac_types)
    repeated? = total_sightings >= @provisional_promotion_required_repeat_count
    corroborated? = length(distinct_types) >= 2

    cond do
      current_non_mac_types == [] ->
        record_blocked_promotion(device, metadata, "no_non_mac_strong_identifier", actor, %{
          current_non_mac_types: current_type_names,
          distinct_types: distinct_type_names,
          non_mac_sighting_total: total_sightings
        })

      repeated? or corroborated? ->
        promote_device_identity_state(device, actor, %{
          "identity_promotion_policy" => "corroborated_strong_identifier",
          "identity_promotion_non_mac_sighting_count" => total_sightings,
          "identity_promotion_types_seen" => distinct_type_names
        })

      true ->
        record_blocked_promotion(device, metadata, "insufficient_corroboration", actor, %{
          current_non_mac_types: current_type_names,
          distinct_types: distinct_type_names,
          non_mac_sighting_total: total_sightings,
          required_repeat_count: @provisional_promotion_required_repeat_count
        })
    end
  end

  defp current_non_mac_strong_types(ids) do
    Enum.filter(@strong_non_mac_identifier_types, fn type ->
      Ids.present_id?(Ids.get_identifier_value(ids, type))
    end)
  end

  defp existing_non_mac_identifier_types(device_id, partition, actor) do
    query =
      DeviceIdentifier
      |> Ash.Query.for_read(:by_device, %{device_id: device_id})
      |> Ash.Query.filter(identifier_type in ^@strong_non_mac_identifier_types)
      |> maybe_filter_identifier_partition(partition)

    case Ash.read(query, actor: actor) do
      {:ok, identifiers} ->
        identifiers
        |> Enum.map(& &1.identifier_type)
        |> Enum.uniq()

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp maybe_filter_identifier_partition(query, ""), do: query

  defp maybe_filter_identifier_partition(query, partition) do
    Ash.Query.filter(query, partition == ^partition)
  end

  defp non_mac_sighting_total(metadata, current_non_mac_types) do
    previous = parse_positive_int(metadata["identity_promotion_non_mac_sighting_count"])
    increment = if current_non_mac_types == [], do: 0, else: 1
    previous + increment
  end

  defp parse_positive_int(value) when is_integer(value) and value >= 0, do: value

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp parse_positive_int(_), do: 0

  defp record_blocked_promotion(device, metadata, reason, actor, details) do
    blocked_metadata =
      %{}
      |> Map.put("identity_promotion_blocked_reason", reason)
      |> Map.put("identity_promotion_last_eval_at", now_iso8601())
      |> Map.put(
        "identity_promotion_non_mac_sighting_count",
        details[:non_mac_sighting_total] || metadata["identity_promotion_non_mac_sighting_count"] ||
          0
      )
      |> Map.put("identity_promotion_types_seen", details[:distinct_types] || [])

    _ =
      device
      |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: blocked_metadata})
      |> Ash.update(actor: actor)

    Logger.info("Blocked provisional identity promotion",
      device_id: device.uid,
      reason: reason,
      current_non_mac_types: details[:current_non_mac_types] || [],
      distinct_types: details[:distinct_types] || [],
      non_mac_sighting_total: details[:non_mac_sighting_total] || 0,
      required_repeat_count:
        details[:required_repeat_count] || @provisional_promotion_required_repeat_count
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :provisional_promotion, :blocked],
      %{count: 1},
      %{reason: reason}
    )

    :ok
  rescue
    e ->
      Logger.warning(
        "Failed to record blocked provisional promotion for #{device.uid}: #{inspect(e)}"
      )

      :ok
  end

  defp promote_device_identity_state(%Device{} = device, actor, extra_metadata) do
    promoted_metadata =
      %{}
      |> Map.put("identity_state", "canonical")
      |> Map.put("identity_promoted_by", "dire")
      |> Map.put("identity_promoted_at", now_iso8601())
      |> Map.put("identity_promotion_blocked_reason", nil)
      |> Map.merge(extra_metadata)

    device
    |> Ash.Changeset.for_update(:merge_metadata, %{metadata_patch: promoted_metadata})
    |> Ash.update(actor: actor)

    Logger.info("Promoted provisional identity",
      device_id: device.uid,
      promotion_policy: promoted_metadata["identity_promotion_policy"],
      non_mac_sighting_total: promoted_metadata["identity_promotion_non_mac_sighting_count"],
      promotion_types_seen: promoted_metadata["identity_promotion_types_seen"] || []
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :provisional_promotion, :promoted],
      %{count: 1},
      %{policy: promoted_metadata["identity_promotion_policy"] || "unknown"}
    )

    :ok
  rescue
    e ->
      Logger.warning("Failed to promote provisional identity for #{device.uid}: #{inspect(e)}")
      :ok
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp handle_identifier_errors([]), do: :ok
  defp handle_identifier_errors(errors), do: {:error, {:identifier_registration_failed, errors}}

  defp maybe_merge_on_register(device_id, canonical_id, ids, actor) do
    if should_merge_on_register?(device_id, canonical_id) do
      matches = Resolver.lookup_identifier_matches(ids, actor)

      if MergePolicy.merge_allowed_for_matches?(matches) do
        _ =
          MergeEngine.merge_devices(device_id, canonical_id,
            actor: actor,
            reason: "identifier_conflict",
            details: %{
              source: "identifier_registration",
              identifiers: %{
                agent_id: Ids.ids_get(ids, :agent_id),
                armis_id: Ids.ids_get(ids, :armis_id),
                integration_id: Ids.ids_get(ids, :integration_id),
                netbox_id: Ids.ids_get(ids, :netbox_id),
                mac: Ids.ids_get(ids, :mac)
              }
            }
          )
      else
        blocked_reason = MergePolicy.blocked_merge_reason(matches)
        device_ids = Enum.uniq([device_id, canonical_id])

        Logger.warning(
          "Blocked register-time merge. " <>
            "Devices: #{inspect(device_ids)}, reason: #{blocked_reason}"
        )

        MergePolicy.emit_blocked_merge_telemetry(blocked_reason, device_ids, matches)
      end

      :ok
    else
      :ok
    end
  end

  defp should_merge_on_register?(device_id, canonical_id) do
    Ids.present_id?(device_id) and Ids.present_id?(canonical_id) and device_id != canonical_id and
      not Ids.service_device_id?(device_id)
  end

  defp resolve_identifier_conflicts(device_id, ids, actor) do
    matches = Resolver.lookup_identifier_matches(ids, actor)
    device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

    case device_ids do
      [] ->
        device_id

      [only_id] ->
        only_id

      _ ->
        canonical_id = Resolver.select_canonical_device_id(device_id, matches, actor)
        resolve_conflicts_for_canonical(device_id, canonical_id, device_ids, matches, actor)
    end
  end

  defp resolve_conflicts_for_canonical(device_id, canonical_id, device_ids, matches, actor) do
    if MergePolicy.merge_allowed_for_matches?(matches) do
      _ = MergeEngine.merge_conflicting_devices(canonical_id, device_ids, matches, actor)
      canonical_id
    else
      blocked_reason = MergePolicy.blocked_merge_reason(matches)

      Logger.warning(
        "Blocked merge during identifier conflict resolution. " <>
          "Devices: #{inspect(device_ids)}, reason: #{blocked_reason}"
      )

      MergePolicy.emit_blocked_merge_telemetry(blocked_reason, device_ids, matches)

      # Preserve current device_id on blocked merge paths to avoid
      # destructive rebinds from ambiguous MAC-only conflicts.
      if Ids.present_id?(device_id), do: device_id, else: canonical_id
    end
  end

  defp maybe_add_identifier(acc, _device_id, _id_type, nil, _partition), do: acc

  defp maybe_add_identifier(acc, device_id, :mac, id_value, partition) do
    [
      %{
        device_id: device_id,
        identifier_type: :mac,
        identifier_value: id_value,
        partition: partition,
        confidence: Mac.mac_confidence(id_value),
        source: "identity_reconciler"
      }
      | acc
    ]
  end

  defp maybe_add_identifier(acc, device_id, id_type, id_value, partition) do
    [
      %{
        device_id: device_id,
        identifier_type: id_type,
        identifier_value: id_value,
        partition: partition,
        confidence: :strong,
        source: "identity_reconciler"
      }
      | acc
    ]
  end

  # Register every atomic MAC carried by the update (never the legacy blob).
  # Values are re-validated here so hand-built identifier maps cannot register
  # malformed MACs. Write-time sanity cap; per-device lifecycle caps are
  # enforced separately.
  defp add_mac_identifiers(acc, device_id, ids, partition) do
    case_result =
      case Ids.ids_get(ids, :macs) do
        list when is_list(list) -> list
        _ -> List.wrap(Ids.ids_get(ids, :mac))
      end

    macs =
      case_result
      |> Enum.flat_map(&Mac.normalize_mac_list/1)
      |> Enum.uniq()

    {to_register, dropped} = Enum.split(macs, max_macs_per_update())

    if dropped != [] do
      :telemetry.execute(
        [:serviceradar, :identity_reconciler, :identifier, :truncated],
        %{count: length(dropped)},
        %{identifier_type: :mac, device_id: device_id}
      )
    end

    Enum.reduce(to_register, acc, fn mac, inner ->
      maybe_add_identifier(inner, device_id, :mac, mac, partition)
    end)
  end

  defp max_macs_per_update do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_macs_per_update, 32)
  end
end
