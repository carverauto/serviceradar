defmodule ServiceRadar.Inventory.VirtualizationIdentityAliases do
  @moduledoc """
  Reconciles lookup-only legacy virtualization aliases.

  The transition is monotonic: an unresolved migration row can become
  resolved when one source-scoped v3 target is observed, while a second target
  for the same legacy ref permanently quarantines the alias as ambiguous.
  """

  alias ServiceRadar.Repo

  @resource_keys [
    {:clusters, "cluster"},
    {:hosts, "host"},
    {:guests, "guest"}
  ]

  @spec reconcile(map()) :: :ok | {:error, term()}
  def reconcile(records) when is_map(records) do
    records
    |> alias_candidates()
    |> Enum.reduce_while(:ok, fn candidate, :ok ->
      case upsert_candidate(candidate) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def reconcile(_records), do: {:error, :invalid_virtualization_records}

  defp alias_candidates(records) do
    Enum.flat_map(@resource_keys, fn {record_key, resource_kind} ->
      records
      |> Map.get(record_key, [])
      |> Enum.filter(&authoritative_v3?/1)
      |> Enum.flat_map(fn record ->
        record
        |> Map.get(:legacy_provider_refs, [])
        |> List.wrap()
        |> Enum.filter(&present?/1)
        |> Enum.uniq()
        |> Enum.map(fn legacy_ref ->
          %{
            provider: to_string(Map.get(record, :provider)),
            resource_kind: resource_kind,
            legacy_provider_ref: legacy_ref,
            target_provider_ref: Map.fetch!(record, :provider_ref)
          }
        end)
      end)
    end)
  end

  defp authoritative_v3?(record) when is_map(record) do
    Map.get(record, :identity_version) == 3 and
      Map.get(record, :identity_state) in [:authoritative, "authoritative"] and
      present?(Map.get(record, :provider_ref))
  end

  defp authoritative_v3?(_record), do: false

  defp upsert_candidate(candidate) do
    sql = """
    INSERT INTO platform.virtualization_identity_aliases (
      id,
      provider,
      resource_kind,
      legacy_provider_ref,
      target_provider_ref,
      status,
      reason,
      candidate_provider_refs,
      metadata,
      inserted_at,
      updated_at
    )
    VALUES (
      gen_random_uuid(),
      $1,
      $2,
      $3,
      $4,
      'resolved',
      'source_scoped_v3_observation',
      ARRAY[$4]::text[],
      '{}'::jsonb,
      now() AT TIME ZONE 'utc',
      now() AT TIME ZONE 'utc'
    )
    ON CONFLICT (provider, resource_kind, legacy_provider_ref)
    DO UPDATE SET
      candidate_provider_refs = (
        SELECT ARRAY_AGG(DISTINCT candidate_ref ORDER BY candidate_ref)
        FROM unnest(
          platform.virtualization_identity_aliases.candidate_provider_refs ||
          EXCLUDED.candidate_provider_refs
        ) AS candidate_ref
      ),
      status = CASE
        WHEN platform.virtualization_identity_aliases.status = 'ambiguous' THEN 'ambiguous'
        WHEN platform.virtualization_identity_aliases.target_provider_ref IS NULL
             AND cardinality(platform.virtualization_identity_aliases.candidate_provider_refs) = 0
          THEN 'resolved'
        WHEN platform.virtualization_identity_aliases.target_provider_ref = EXCLUDED.target_provider_ref
          THEN 'resolved'
        ELSE 'ambiguous'
      END,
      target_provider_ref = CASE
        WHEN platform.virtualization_identity_aliases.status = 'ambiguous' THEN NULL
        WHEN platform.virtualization_identity_aliases.target_provider_ref IS NULL
             AND cardinality(platform.virtualization_identity_aliases.candidate_provider_refs) = 0
          THEN EXCLUDED.target_provider_ref
        WHEN platform.virtualization_identity_aliases.target_provider_ref = EXCLUDED.target_provider_ref
          THEN EXCLUDED.target_provider_ref
        ELSE NULL
      END,
      reason = CASE
        WHEN platform.virtualization_identity_aliases.status = 'ambiguous' THEN 'multiple_source_scoped_targets'
        WHEN platform.virtualization_identity_aliases.target_provider_ref IS NULL
             AND cardinality(platform.virtualization_identity_aliases.candidate_provider_refs) = 0
          THEN 'source_scoped_v3_observation'
        WHEN platform.virtualization_identity_aliases.target_provider_ref = EXCLUDED.target_provider_ref
          THEN 'source_scoped_v3_observation'
        ELSE 'multiple_source_scoped_targets'
      END,
      updated_at = now() AT TIME ZONE 'utc'
    """

    case Repo.query(sql, [
           candidate.provider,
           candidate.resource_kind,
           candidate.legacy_provider_ref,
           candidate.target_provider_ref
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
