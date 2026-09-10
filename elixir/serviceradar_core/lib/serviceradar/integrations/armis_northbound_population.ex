defmodule ServiceRadar.Integrations.ArmisNorthboundPopulation do
  @moduledoc """
  Collection-bound source-ID population for one Armis northbound run.

  Candidate selection starts from activated source observations, never from an
  accumulated active-device query. Every source ID is classified exactly once.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservation
  alias ServiceRadar.Inventory.DeviceSourceSnapshot
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Repo

  @spec load(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(source, _opts \\ []) do
    with %DeviceSourceSnapshot{} = snapshot <- current_snapshot(source),
         :ok <- require_exact_accounting(snapshot),
         observations = collection_observations(source, snapshot),
         :ok <- require_membership_count(snapshot, observations) do
      {:ok, classify(source, snapshot, observations)}
    else
      nil -> {:error, :source_snapshot_not_found}
      {:error, _} = error -> error
    end
  end

  @doc false
  def classify_observation(observation, typed_ids, availability, conflicting_duplicate?) do
    source_id = to_string(observation.source_object_id)
    typed_ids = typed_ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.sort()

    cond do
      conflicting_duplicate? ->
        withheld(observation, "conflicting_duplicate_payload")

      is_nil(observation.device_id) ->
        withheld(observation, "unresolved_canonical_identity")

      observation.deleted_at != nil ->
        withheld(observation, "deleted_canonical_device")

      typed_ids == [] ->
        withheld(observation, "missing_typed_identifier")

      length(typed_ids) > 1 ->
        withheld(observation, "multiple_typed_ids_per_device", %{"typed_ids" => typed_ids})

      typed_ids != [source_id] ->
        withheld(observation, "source_identifier_mismatch", %{"typed_ids" => typed_ids})

      metadata_disagrees?(
        observation.metadata,
        source_id,
        Map.get(observation, :expected_source_instance)
      ) ->
        withheld(observation, "metadata_identifier_disagreement")

      source_linkage_disagrees?(observation, source_id) ->
        withheld(observation, "source_linkage_mismatch")

      availability not in [true, false] ->
        withheld(observation, "missing_availability")

      true ->
        %{
          disposition: :eligible,
          reason: nil,
          source_object_id: source_id,
          canonical_device_uid: observation.device_id,
          is_available: availability,
          metadata: %{}
        }
    end
  end

  defp classify(source, snapshot, observations) do
    device_ids = observations |> Enum.map(& &1.device_id) |> Enum.uniq()
    typed_ids = typed_ids_by_device(device_ids)
    availability = availability_by_device(source, observations)

    dispositions =
      Enum.map(observations, fn observation ->
        observation = Map.put(observation, :expected_source_instance, to_string(source.id))

        classify_observation(
          observation,
          Map.get(typed_ids, observation.device_id, []),
          Map.get(availability, observation.device_id, :missing),
          duplicate_conflict?(observation)
        )
      end)

    {eligible_dispositions, withheld_dispositions} =
      Enum.split_with(dispositions, &(&1.disposition == :eligible))

    candidates =
      Enum.map(eligible_dispositions, fn disposition ->
        %{
          armis_device_id: disposition.source_object_id,
          is_available: disposition.is_available,
          device_id: disposition.canonical_device_uid,
          sync_service_id: to_string(source.id),
          metadata: %{
            "collection_id" => snapshot.collection_id,
            "source_object_id" => disposition.source_object_id
          }
        }
      end)

    %{
      accounted?: true,
      snapshot: snapshot,
      candidates: candidates,
      eligible: eligible_dispositions,
      withheld: withheld_dispositions,
      distinct_source_ids: length(dispositions),
      eligible_count: length(eligible_dispositions),
      withheld_count: length(withheld_dispositions),
      reason_counts: Enum.frequencies_by(withheld_dispositions, & &1.reason),
      accounting: accounting(snapshot)
    }
  end

  defp current_snapshot(source) do
    partition = Map.get(source, :partition) || "default"
    source_instance = source |> Map.fetch!(:id) |> to_string()

    Repo.one(
      from(snapshot in DeviceSourceSnapshot,
        where:
          snapshot.partition == ^partition and snapshot.source == "armis" and
            snapshot.source_instance == ^source_instance,
        order_by: [desc: snapshot.activated_at, desc: snapshot.observed_at, desc: snapshot.id],
        limit: 1
      )
    )
  end

  defp collection_observations(source, snapshot) do
    source_instance = source |> Map.fetch!(:id) |> to_string()

    Repo.all(
      from(observation in DeviceSourceObservation,
        left_join: device in Device,
        on: device.uid == observation.device_id,
        where:
          observation.partition == ^snapshot.partition and observation.source == "armis" and
            observation.source_instance == ^source_instance and
            observation.collection_id == ^snapshot.collection_id and
            observation.present == true,
        select: %{
          source_object_id: observation.source_object_id,
          device_id: observation.device_id,
          metadata: device.metadata,
          observation_metadata: observation.metadata,
          deleted_at: device.deleted_at,
          canonical_availability: device.is_available
        },
        order_by: [asc: observation.source_object_id]
      )
    )
  end

  defp typed_ids_by_device([]), do: %{}

  defp typed_ids_by_device(device_ids) do
    device_ids = Enum.reject(device_ids, &is_nil/1)

    from(identifier in DeviceIdentifier,
      where:
        identifier.device_id in ^device_ids and identifier.identifier_type == :armis_device_id,
      select: {identifier.device_id, identifier.identifier_value}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp availability_by_device(source, observations) do
    case availability_source_agent_id(source) do
      nil -> Map.new(observations, &{&1.device_id, &1.canonical_availability})
      "" -> Map.new(observations, &{&1.device_id, &1.canonical_availability})
      agent_id -> agent_availability(agent_id, Enum.map(observations, & &1.device_id))
    end
  end

  defp agent_availability(_agent_id, []), do: %{}

  defp agent_availability(agent_id, device_ids) do
    from(availability in DeviceAgentAvailability,
      where: availability.agent_id == ^agent_id and availability.device_uid in ^device_ids,
      select: {availability.device_uid, availability.is_available}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp require_exact_accounting(snapshot) do
    metadata = snapshot.metadata || %{}
    if metadata["accounting_status"] == "exact", do: :ok, else: {:error, :accounting_unavailable}
  end

  defp require_membership_count(snapshot, observations) do
    metadata = snapshot.metadata || %{}
    expected = metadata["distinct_source_ids"] || snapshot.device_count
    actual = length(observations)

    if expected == actual,
      do: :ok,
      else: {:error, {:source_membership_mismatch, expected, actual}}
  end

  defp duplicate_conflict?(observation) do
    observation.observation_metadata
    |> Map.new()
    |> Map.get("identifier_metadata", %{})
    |> Map.get("source_duplicate_conflict", false)
    |> Kernel.in([true, "true"])
  end

  defp source_linkage_disagrees?(observation, source_id) do
    metadata = Map.get(observation, :observation_metadata) || %{}
    identifier_metadata = Map.get(metadata, "identifier_metadata") || %{}
    linked_source = present(Map.get(identifier_metadata, "sync_service_id"))
    expected_source = present(Map.get(observation, :expected_source_instance))

    (linked_source != nil and expected_source != nil and linked_source != expected_source) or
      metadata_source_id_disagrees?(observation.metadata, source_id, expected_source)
  end

  defp metadata_source_id_disagrees?(metadata, source_id, expected_source)
       when is_map(metadata) do
    linked_source = present(metadata["sync_service_id"])

    (linked_source != nil and expected_source != nil and linked_source != expected_source) or
      metadata_disagrees?(metadata, source_id, expected_source)
  end

  defp metadata_source_id_disagrees?(_metadata, _source_id, _expected_source), do: false

  defp metadata_disagrees?(metadata, source_id, expected_source) when is_map(metadata) do
    typed_metadata_id = present(metadata["armis_device_id"])

    generic_id =
      if String.downcase(to_string(metadata["integration_type"] || "")) == "armis" do
        present(metadata["integration_id"])
      end

    scoped_id =
      IntegrationIdentity.scoped_device_id(
        "armis",
        expected_source || metadata["sync_service_id"],
        source_id
      )

    (typed_metadata_id != nil and typed_metadata_id != source_id) or
      (generic_id != nil and generic_id not in [source_id, scoped_id])
  end

  defp metadata_disagrees?(_metadata, _source_id, _expected_source), do: false

  defp accounting(snapshot) do
    metadata = snapshot.metadata || %{}

    %{
      collection_id: snapshot.collection_id,
      collection_content_hash: snapshot.content_hash,
      collection_observed_at: snapshot.observed_at,
      raw_rows: accounting_value(metadata, "raw_rows"),
      excluded_rows: accounting_value(metadata, "excluded_rows"),
      invalid_rows: accounting_value(metadata, "invalid_rows"),
      valid_occurrences: accounting_value(metadata, "valid_occurrences"),
      distinct_source_ids: accounting_value(metadata, "distinct_source_ids"),
      duplicate_occurrences: accounting_value(metadata, "duplicate_occurrences"),
      conflicting_duplicate_ids: accounting_value(metadata, "conflicting_duplicate_ids"),
      duplicate_source_id_examples: accounting_examples(metadata, "duplicate_source_id_examples"),
      invalid_row_examples: accounting_examples(metadata, "invalid_row_examples"),
      conflicting_duplicate_examples:
        accounting_examples(metadata, "conflicting_duplicate_examples")
    }
  end

  defp accounting_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key)) || 0
  rescue
    ArgumentError -> Map.get(metadata, key, 0)
  end

  defp accounting_examples(metadata, key) do
    case Map.get(metadata, key) do
      values when is_list(values) -> Enum.take(values, 100)
      _ -> []
    end
  end

  defp withheld(observation, reason, metadata \\ %{}) do
    %{
      disposition: :withheld,
      reason: reason,
      source_object_id: to_string(observation.source_object_id),
      canonical_device_uid: observation.device_id,
      is_available: nil,
      metadata: metadata
    }
  end

  defp availability_source_agent_id(source) do
    Map.get(source, :northbound_availability_source_agent_id) ||
      Map.get(source, "northbound_availability_source_agent_id")
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(value) when is_integer(value), do: Integer.to_string(value)
  defp present(_), do: nil
end
