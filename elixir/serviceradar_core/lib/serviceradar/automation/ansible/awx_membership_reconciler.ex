defmodule ServiceRadar.Automation.Ansible.AwxMembershipReconciler do
  @moduledoc """
  Materializes durable AWX host memberships from device-discovery aggregates.

  Membership identity comes only from the AWX source tuple embedded in the
  discovery record. Host names and addresses are retained as evidence, but are
  never used to select a device or merge memberships. Legacy AWX envelopes that
  do not advertise the generation/fingerprint/completeness contract remain
  valid device discoveries, but cannot create execution identities.
  """

  alias Ash.Page.Keyset
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo

  require Ash.Expr
  require Ash.Query

  @schema "serviceradar.device_discovery.v1"
  @source "awx"
  @max_aggregates 64
  @max_hosts_per_aggregate 50_000
  @max_existing_memberships 100_000
  @max_generation 9_223_372_036_854_775_807
  @max_host_name_bytes 255
  @max_ansible_host_bytes 1_024
  @fingerprint_regex ~r/\Asha256:[0-9a-f]{64}\z/
  @contract_keys ["source_generation", "source_fingerprint", "complete"]

  @type source_tuple :: {String.t(), pos_integer(), pos_integer()}

  @doc """
  Reconciles every explicitly versioned AWX aggregate in a plugin payload.

  The caller must invoke this only after the corresponding device inventory
  sync succeeds. All membership changes for one aggregate run in a transaction;
  an older generation or a same-generation fingerprint conflict aborts it.
  """
  @spec reconcile(map() | list(), keyword()) :: :ok | {:error, term()}
  def reconcile(payload, opts) do
    actor = Keyword.fetch!(opts, :actor)
    dependencies = dependencies(opts)

    with {:ok, aggregates} <- parse(payload) do
      reconcile_aggregates(aggregates, actor, dependencies)
    end
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec parse(map() | list()) :: {:ok, [map()]} | {:error, term()}
  def parse(payload) do
    envelopes = discovery_envelopes(payload)

    if length(envelopes) > @max_aggregates do
      {:error, {:too_many_awx_aggregates, length(envelopes), @max_aggregates}}
    else
      envelopes
      |> Enum.reduce_while({:ok, []}, fn envelope, {:ok, aggregates} ->
        case parse_envelope(envelope) do
          :legacy -> {:cont, {:ok, aggregates}}
          {:ok, aggregate} -> {:cont, {:ok, [aggregate | aggregates]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, aggregates} -> validate_unique_controllers(Enum.reverse(aggregates))
        error -> error
      end
    end
  end

  @doc false
  @spec device_evidence_index([map() | struct()]) :: %{optional(source_tuple()) => [String.t()]}
  def device_evidence_index(devices) when is_list(devices) do
    devices
    |> Enum.reduce(%{}, fn device, index ->
      with uid when is_binary(uid) <- field(device, :uid),
           metadata when is_map(metadata) <- field(device, :metadata),
           awx when is_map(awx) <- value(metadata, "awx"),
           {:ok, controller_id} <- canonical_uuid(value(awx, "controller_id")),
           {:ok, inventory_id} <- positive_integer(value(awx, "inventory_id")),
           {:ok, awx_host_id} <- positive_integer(value(awx, "host_id")) do
        Map.update(index, {controller_id, inventory_id, awx_host_id}, [uid], fn uids ->
          [uid | uids]
        end)
      else
        _ -> index
      end
    end)
    |> Map.new(fn {tuple, uids} -> {tuple, uids |> Enum.uniq() |> Enum.sort()} end)
  end

  defp dependencies(opts) do
    %{
      transaction: Keyword.get(opts, :transaction, &default_transaction/1),
      load_existing: Keyword.get(opts, :load_existing, &load_existing/2),
      resolve_links: Keyword.get(opts, :resolve_links, &resolve_links/2),
      upsert: Keyword.get(opts, :upsert, &upsert_membership/2),
      expire: Keyword.get(opts, :expire, &expire_membership/3),
      notify: Keyword.get(opts, :notify, &Ash.Notifier.notify/1)
    }
  end

  defp reconcile_aggregates(aggregates, actor, dependencies) do
    Enum.reduce_while(aggregates, :ok, fn aggregate, :ok ->
      case dependencies.transaction.(fn ->
             reconcile_aggregate(aggregate, actor, dependencies)
           end) do
        {:ok, notifications} when is_list(notifications) ->
          continue_after_notification_dispatch(notifications, dependencies)

        {:ok, {:ok, notifications}} when is_list(notifications) ->
          continue_after_notification_dispatch(notifications, dependencies)

        :ok ->
          {:cont, :ok}

        {:ok, :ok} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, {:invalid_membership_transaction_result, other}}}
      end
    end)
  end

  defp reconcile_aggregate(aggregate, actor, dependencies) do
    with {:ok, existing} <- dependencies.load_existing.(aggregate.controller_id, actor),
         :ok <- validate_existing_bound(existing),
         :ok <- validate_generation(aggregate, existing),
         :ok <- validate_same_generation_source_state(aggregate, existing),
         {:ok, evidence_index} <- dependencies.resolve_links.(aggregate, actor),
         {:ok, upsert_notifications} <-
           upsert_memberships(aggregate, existing, evidence_index, actor, dependencies),
         {:ok, expire_notifications} <-
           maybe_expire_absent(aggregate, existing, actor, dependencies) do
      {:ok, upsert_notifications ++ expire_notifications}
    end
  end

  defp validate_existing_bound(existing) when length(existing) <= @max_existing_memberships,
    do: :ok

  defp validate_existing_bound(existing) do
    {:error, {:too_many_existing_awx_memberships, length(existing), @max_existing_memberships}}
  end

  defp validate_generation(aggregate, existing) do
    max_existing_generation =
      existing
      |> Enum.map(&field(&1, :source_generation))
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> 0 end)

    cond do
      aggregate.source_generation < max_existing_generation ->
        {:error,
         {:stale_awx_membership_generation, aggregate.controller_id, aggregate.source_generation,
          max_existing_generation}}

      aggregate.source_generation == max_existing_generation and
          Enum.any?(existing, fn membership ->
            field(membership, :source_generation) == aggregate.source_generation and
                field(membership, :source_fingerprint) != aggregate.source_fingerprint
          end) ->
        {:error,
         {:conflicting_awx_membership_fingerprint, aggregate.controller_id,
          aggregate.source_generation}}

      true ->
        :ok
    end
  end

  defp validate_same_generation_source_state(aggregate, existing) do
    incoming_by_tuple =
      Map.new(aggregate.hosts, &{host_tuple(aggregate.controller_id, &1), &1})

    Enum.reduce_while(existing, :ok, fn membership, :ok ->
      host = Map.get(incoming_by_tuple, membership_tuple(membership))

      if field(membership, :source_generation) == aggregate.source_generation and
           not is_nil(host) and
           (field(membership, :current) != true or
              not is_nil(field(membership, :expired_at)) or
              field(membership, :host_name) != host.host_name or
              field(membership, :ansible_host) != host.ansible_host or
              field(membership, :enabled) != host.enabled) do
        {:halt,
         {:error,
          {:conflicting_same_generation_awx_membership_state, membership_tuple(membership)}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp upsert_memberships(aggregate, existing, evidence_index, actor, dependencies) do
    existing_by_tuple = Map.new(existing, &{membership_tuple(&1), &1})

    aggregate.hosts
    |> Enum.reduce_while({:ok, []}, fn host, {:ok, notification_batches} ->
      tuple = host_tuple(aggregate.controller_id, host)
      existing_membership = Map.get(existing_by_tuple, tuple)
      matching_device_uids = Map.get(evidence_index, tuple, [])
      link = link_attributes(existing_membership, matching_device_uids, tuple)

      attrs = %{
        controller_id: aggregate.controller_id,
        inventory_id: host.inventory_id,
        awx_host_id: host.awx_host_id,
        canonical_device_uid: link.canonical_device_uid,
        source_generation: aggregate.source_generation,
        host_name: host.host_name,
        ansible_host: host.ansible_host,
        enabled: host.enabled,
        current: true,
        last_seen_at: aggregate.observed_at,
        expired_at: nil,
        link_disposition: link.disposition,
        link_evidence: link.evidence,
        source_fingerprint: aggregate.source_fingerprint,
        metadata: host.metadata
      }

      case write_notifications(dependencies.upsert.(attrs, actor)) do
        {:ok, notifications} ->
          {:cont, {:ok, [notifications | notification_batches]}}

        {:error, reason} ->
          {:halt, {:error, {:awx_membership_upsert_failed, tuple, reason}}}

        {:invalid, other} ->
          {:halt, {:error, {:invalid_membership_upsert_result, tuple, other}}}
      end
    end)
    |> flatten_notification_batches()
  end

  defp maybe_expire_absent(%{complete: false}, _existing, _actor, _dependencies), do: {:ok, []}

  defp maybe_expire_absent(aggregate, existing, actor, dependencies) do
    seen = MapSet.new(aggregate.hosts, &host_tuple(aggregate.controller_id, &1))

    existing
    |> Enum.filter(&(field(&1, :current) == true))
    |> Enum.reject(&MapSet.member?(seen, membership_tuple(&1)))
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, notification_batches} ->
      tuple = membership_tuple(membership)

      attrs = %{
        source_generation: aggregate.source_generation,
        expired_at: aggregate.observed_at,
        source_fingerprint: aggregate.source_fingerprint,
        metadata: expiration_metadata(aggregate, membership)
      }

      case write_notifications(dependencies.expire.(membership, attrs, actor)) do
        {:ok, notifications} ->
          {:cont, {:ok, [notifications | notification_batches]}}

        {:error, reason} ->
          {:halt, {:error, {:awx_membership_expire_failed, tuple, reason}}}

        {:invalid, other} ->
          {:halt, {:error, {:invalid_membership_expire_result, tuple, other}}}
      end
    end)
    |> flatten_notification_batches()
  end

  defp flatten_notification_batches({:ok, batches}) do
    {:ok, batches |> Enum.reverse() |> List.flatten()}
  end

  defp flatten_notification_batches({:error, _reason} = error), do: error

  defp write_notifications({:ok, _record, %{notifications: notifications}})
       when is_list(notifications),
       do: {:ok, notifications}

  defp write_notifications({:ok, _record, notifications}) when is_list(notifications),
    do: {:ok, notifications}

  defp write_notifications({:ok, _record}), do: {:ok, []}
  defp write_notifications(:ok), do: {:ok, []}
  defp write_notifications({:error, reason}), do: {:error, reason}
  defp write_notifications(other), do: {:invalid, other}

  defp dispatch_notifications([], _dependencies), do: :ok

  defp dispatch_notifications(notifications, dependencies) do
    case dependencies.notify.(notifications) do
      [] ->
        :ok

      remaining when is_list(remaining) ->
        {:error, {:awx_membership_notifications_not_dispatched, length(remaining)}}

      other ->
        {:error, {:invalid_membership_notification_dispatch_result, other}}
    end
  end

  defp continue_after_notification_dispatch(notifications, dependencies) do
    case dispatch_notifications(notifications, dependencies) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp expiration_metadata(aggregate, membership) do
    membership
    |> field(:metadata)
    |> normalize_map()
    |> Map.merge(%{
      "expired_by_complete_aggregate" => true,
      "expired_collection_id" => aggregate.collection_id
    })
  end

  defp link_attributes(existing, [canonical_device_uid], tuple) do
    cond do
      not is_nil(existing) and field(existing, :link_disposition) == :quarantined ->
        quarantined_link(existing, tuple, [canonical_device_uid])

      not is_nil(existing) and field(existing, :link_disposition) == :approved and
          (field(existing, :current) != true or
             field(existing, :canonical_device_uid) != canonical_device_uid) ->
        quarantined_link(existing, tuple, [canonical_device_uid])

      not is_nil(existing) and field(existing, :current) == true and
          field(existing, :link_disposition) == :approved ->
        %{
          canonical_device_uid: canonical_device_uid,
          disposition: :approved,
          evidence:
            merge_link_evidence(existing, source_tuple_evidence(tuple, [canonical_device_uid]))
        }

      true ->
        %{
          canonical_device_uid: canonical_device_uid,
          disposition: :proposed,
          evidence: source_tuple_evidence(tuple, [canonical_device_uid])
        }
    end
  end

  defp link_attributes(existing, matching_device_uids, tuple) do
    disposition =
      cond do
        not is_nil(existing) and field(existing, :link_disposition) == :quarantined ->
          :quarantined

        length(matching_device_uids) > 1 ->
          :quarantined

        not is_nil(existing) and field(existing, :link_disposition) == :approved ->
          :quarantined

        true ->
          :unlinked
      end

    %{
      canonical_device_uid: nil,
      disposition: disposition,
      evidence:
        if(disposition == :quarantined,
          do: merge_link_evidence(existing, source_tuple_evidence(tuple, matching_device_uids)),
          else: source_tuple_evidence(tuple, matching_device_uids)
        )
    }
  end

  defp quarantined_link(existing, tuple, matching_device_uids) do
    %{
      canonical_device_uid: nil,
      disposition: :quarantined,
      evidence: merge_link_evidence(existing, source_tuple_evidence(tuple, matching_device_uids))
    }
  end

  defp merge_link_evidence(existing, source_evidence) do
    existing
    |> field(:link_evidence)
    |> normalize_map()
    |> Map.merge(source_evidence)
  end

  defp source_tuple_evidence({controller_id, inventory_id, awx_host_id}, device_uids) do
    %{
      "kind" => "stored_awx_source_tuple",
      "controller_id" => controller_id,
      "inventory_id" => inventory_id,
      "awx_host_id" => awx_host_id,
      "matching_device_uids" => Enum.sort(device_uids),
      "match_count" => length(device_uids)
    }
  end

  defp default_transaction(fun) do
    Repo.transaction(
      fn ->
        case fun.() do
          {:ok, notifications} when is_list(notifications) -> notifications
          :ok -> []
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: :infinity
    )
  end

  defp load_existing(controller_id, actor) do
    AwxHostMembership
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(controller_id == ^controller_id)
    |> Ash.read(actor: actor)
    |> unwrap_page()
  end

  defp resolve_links(aggregate, actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
      |> Ash.Query.filter(metadata["awx"]["controller_id"] == ^aggregate.controller_id)

    case Ash.read(query, actor: actor, page: [limit: @max_hosts_per_aggregate]) do
      {:ok, %Keyset{more?: true}} ->
        {:error, {:too_many_awx_device_evidence_rows, @max_hosts_per_aggregate}}

      {:ok, page} ->
        {:ok, page |> page_results() |> device_evidence_index()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_membership(attrs, actor) do
    condition =
      Ash.Expr.expr(
        source_generation < upsert_conflict(:source_generation) or
          (source_generation == upsert_conflict(:source_generation) and
             source_fingerprint == upsert_conflict(:source_fingerprint) and
             host_name == upsert_conflict(:host_name) and
             enabled == upsert_conflict(:enabled) and current == upsert_conflict(:current) and
             link_disposition == upsert_conflict(:link_disposition) and
             link_evidence == upsert_conflict(:link_evidence) and
             ((is_nil(ansible_host) and is_nil(upsert_conflict(:ansible_host))) or
                ansible_host == upsert_conflict(:ansible_host)) and
             ((is_nil(canonical_device_uid) and
                 is_nil(upsert_conflict(:canonical_device_uid))) or
                canonical_device_uid == upsert_conflict(:canonical_device_uid)) and
             ((is_nil(expired_at) and is_nil(upsert_conflict(:expired_at))) or
                expired_at == upsert_conflict(:expired_at)))
      )

    AwxHostMembership
    |> Ash.Changeset.for_create(:upsert_from_sync, attrs, actor: actor)
    |> Ash.create(actor: actor, upsert_condition: condition, return_notifications?: true)
  end

  defp expire_membership(membership, attrs, actor) do
    membership
    |> Ash.Changeset.for_update(:expire, attrs, actor: actor)
    |> Ash.Changeset.filter(
      Ash.Expr.expr(source_generation <= ^attrs.source_generation and current == true)
    )
    |> Ash.update(actor: actor, return_notifications?: true)
  end

  defp unwrap_page({:ok, page}), do: {:ok, page_results(page)}
  defp unwrap_page({:error, reason}), do: {:error, reason}

  defp page_results(%Keyset{results: results}), do: results
  defp page_results(%Ash.Page.Offset{results: results}), do: results
  defp page_results(results) when is_list(results), do: results

  defp parse_envelope(envelope) do
    metadata = map_value(envelope, "metadata") || %{}

    if Enum.any?(@contract_keys, &Map.has_key?(stringify_keys(metadata), &1)) do
      parse_versioned_envelope(envelope, metadata)
    else
      :legacy
    end
  end

  defp parse_versioned_envelope(envelope, metadata) do
    with {:ok, devices} <- exact_device_list(envelope),
         :ok <- validate_host_bound(devices),
         {:ok, controller_id} <- canonical_uuid(value(metadata, "controller_id")),
         {:ok, source_generation} <- positive_generation(value(metadata, "source_generation")),
         {:ok, source_fingerprint} <- source_fingerprint(value(metadata, "source_fingerprint")),
         {:ok, complete} <- exact_boolean(value(metadata, "complete")),
         {:ok, observed_at} <- observed_at(value(envelope, "observed_at")),
         {:ok, hosts} <-
           parse_hosts(devices, controller_id, source_generation, source_fingerprint),
         :ok <- validate_unique_host_tuples(hosts, controller_id) do
      {:ok,
       %{
         controller_id: controller_id,
         source_generation: source_generation,
         source_fingerprint: source_fingerprint,
         complete: complete,
         observed_at: observed_at,
         collection_id: bounded_string(value(envelope, "collection_id"), 512),
         hosts: hosts
       }}
    else
      {:error, reason} -> {:error, {:invalid_awx_membership_aggregate, reason}}
    end
  end

  defp validate_host_bound(devices) when length(devices) <= @max_hosts_per_aggregate, do: :ok

  defp validate_host_bound(devices) do
    {:error, {:too_many_hosts, length(devices), @max_hosts_per_aggregate}}
  end

  defp exact_device_list(envelope) do
    case value(envelope, "devices") do
      devices when is_list(devices) ->
        if Enum.all?(devices, &is_map/1),
          do: {:ok, devices},
          else: {:error, :invalid_devices}

      _ ->
        {:error, :invalid_devices}
    end
  end

  defp parse_hosts(devices, controller_id, source_generation, source_fingerprint) do
    devices
    |> Enum.reduce_while({:ok, []}, fn device, {:ok, hosts} ->
      case parse_host(device, controller_id, source_generation, source_fingerprint) do
        {:ok, host} -> {:cont, {:ok, [host | hosts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hosts} -> {:ok, Enum.reverse(hosts)}
      error -> error
    end
  end

  defp parse_host(device, controller_id, source_generation, source_fingerprint) do
    with metadata when is_map(metadata) <- map_value(device, "metadata"),
         awx when is_map(awx) <- map_value(metadata, "awx"),
         {:ok, ^controller_id} <- canonical_uuid(value(awx, "controller_id")),
         {:ok, inventory_id} <- positive_integer(value(awx, "inventory_id")),
         {:ok, awx_host_id} <- positive_integer(value(awx, "host_id")),
         {:ok, host_name} <-
           required_bounded_string(value(awx, "host_name"), @max_host_name_bytes),
         {:ok, enabled} <- exact_boolean(value(device, "is_available")),
         :ok <- optional_generation_matches(awx, source_generation),
         :ok <- optional_fingerprint_matches(awx, source_fingerprint) do
      {:ok,
       %{
         inventory_id: inventory_id,
         awx_host_id: awx_host_id,
         host_name: host_name,
         ansible_host: ansible_host(awx),
         enabled: enabled,
         metadata: %{
           "inventory_name" => bounded_string(value(awx, "inventory_name"), 512),
           "collection_source" => @source
         }
       }}
    else
      {:ok, other_controller} -> {:error, {:controller_mismatch, other_controller, controller_id}}
      nil -> {:error, :missing_awx_host_metadata}
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_awx_host}
    end
  end

  defp optional_generation_matches(awx, source_generation) do
    case value(awx, "source_generation") do
      nil ->
        :ok

      value ->
        if positive_generation(value) == {:ok, source_generation},
          do: :ok,
          else: {:error, :host_generation_mismatch}
    end
  end

  defp optional_fingerprint_matches(awx, source_fingerprint) do
    case value(awx, "source_fingerprint") do
      nil -> :ok
      ^source_fingerprint -> :ok
      _ -> {:error, :host_fingerprint_mismatch}
    end
  end

  defp ansible_host(awx) do
    direct = bounded_string(value(awx, "ansible_host"), @max_ansible_host_bytes)

    direct ||
      awx
      |> value("variables")
      |> ansible_host_from_variables()
      |> bounded_string(@max_ansible_host_bytes)
  end

  defp ansible_host_from_variables(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Jason.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) ->
        bounded_string(
          value(decoded, "ansible_host") || value(decoded, "ansible_ssh_host"),
          @max_ansible_host_bytes
        )

      _ ->
        yaml_ansible_host(trimmed)
    end
  end

  defp ansible_host_from_variables(_raw), do: nil

  defp yaml_ansible_host(raw) do
    raw
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      line = String.trim(line)

      Enum.find_value(["ansible_host:", "ansible_ssh_host:"], fn prefix ->
        if String.starts_with?(line, prefix) do
          line
          |> String.replace_prefix(prefix, "")
          |> String.split("#", parts: 2)
          |> List.first()
          |> String.trim()
          |> String.trim("\"'")
          |> bounded_string(@max_ansible_host_bytes)
        end
      end)
    end)
  end

  defp validate_unique_controllers(aggregates) do
    controllers = Enum.map(aggregates, & &1.controller_id)

    if length(controllers) == length(Enum.uniq(controllers)) do
      {:ok, aggregates}
    else
      {:error, :duplicate_awx_controller_aggregate}
    end
  end

  defp validate_unique_host_tuples(hosts, controller_id) do
    tuples = Enum.map(hosts, &host_tuple(controller_id, &1))

    if length(tuples) == length(Enum.uniq(tuples)) do
      :ok
    else
      {:error, :duplicate_awx_host_source_tuple}
    end
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_controller_id}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_controller_id}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp positive_generation(value)
       when is_integer(value) and value > 0 and value <= @max_generation, do: {:ok, value}

  defp positive_generation(_value), do: {:error, :invalid_source_generation}

  defp source_fingerprint(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@fingerprint_regex, value),
      do: {:ok, value},
      else: {:error, :invalid_source_fingerprint}
  end

  defp source_fingerprint(_value), do: {:error, :invalid_source_fingerprint}

  defp exact_boolean(value) when is_boolean(value), do: {:ok, value}
  defp exact_boolean(_value), do: {:error, :invalid_boolean}

  defp observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, observed_at, _offset} -> {:ok, observed_at}
      {:error, _reason} -> {:error, :invalid_observed_at}
    end
  end

  defp observed_at(_value), do: {:error, :invalid_observed_at}

  defp required_bounded_string(value, max_bytes) do
    case bounded_string(value, max_bytes) do
      nil -> {:error, :missing_required_string}
      string -> {:ok, string}
    end
  end

  defp bounded_string(value, max_bytes) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= max_bytes, do: value
  end

  defp bounded_string(_value, _max_bytes), do: nil

  defp discovery_envelopes(payload) when is_list(payload) do
    payload |> Enum.flat_map(&discovery_envelopes/1) |> Enum.filter(&awx_envelope?/1)
  end

  defp discovery_envelopes(payload) when is_map(payload) do
    direct = if awx_envelope?(payload), do: [payload], else: []

    nested =
      ["device_discovery", "deviceDiscovery", "discoveries"]
      |> Enum.flat_map(&list_value(payload, &1))
      |> Enum.filter(&awx_envelope?/1)

    direct ++ nested
  end

  defp discovery_envelopes(_payload), do: []

  defp awx_envelope?(envelope) do
    value(envelope, "schema") == @schema and value(envelope, "source") == @source
  end

  defp membership_tuple(membership) do
    {
      field(membership, :controller_id),
      field(membership, :inventory_id),
      field(membership, :awx_host_id)
    }
  end

  defp host_tuple(controller_id, host), do: {controller_id, host.inventory_id, host.awx_host_id}

  # Device/membership rows from Ash can arrive as nil when an optional
  # association is missing; fail closed to nil instead of FunctionClauseError
  # so one bad row cannot abort the whole inventory membership reconcile.
  defp field(nil, _key), do: nil
  defp field(struct_or_map, key) when is_map(struct_or_map), do: Map.get(struct_or_map, key)
  defp field(_other, _key), do: nil

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} ->
        found

      :error ->
        map
        |> Enum.find_value(fn {candidate, found} ->
          if is_atom(candidate) and Atom.to_string(candidate) == key,
            do: {:found, found}
        end)
        |> case do
          {:found, found} -> found
          nil -> nil
        end
    end
  end

  defp value(_map, _key), do: nil

  defp map_value(map, key) do
    case value(map, key) do
      nested when is_map(nested) -> nested
      _ -> nil
    end
  end

  defp list_value(map, key) do
    case value(map, key) do
      values when is_list(values) -> Enum.filter(values, &is_map/1)
      _ -> []
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, val} -> {to_string(key), val} end)
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}
end
