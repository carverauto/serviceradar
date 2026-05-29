defmodule ServiceRadar.Inventory.DeviceRiskReducer do
  @moduledoc """
  Maintains the inventory-visible composite device risk score.

  Source ingestors call this module to update their source-specific
  contribution. The reducer then writes the derived composite score to
  `ocsf_devices`, preventing later lower source updates from clobbering a
  higher active contribution from another source.
  """

  import Ecto.Query

  alias ServiceRadar.Repo

  @risk_levels [
    {90, 4, "Critical"},
    {70, 3, "High"},
    {40, 2, "Medium"},
    {1, 1, "Low"},
    {0, 0, "Info"}
  ]

  def risk_level_for_score(score) do
    score = normalize_score(score)

    Enum.find_value(@risk_levels, fn {min, id, label} ->
      if score >= min, do: {id, label}
    end)
  end

  def upsert_contributions(contributions, opts \\ []) when is_list(contributions) do
    now = DateTime.utc_now()

    records =
      contributions
      |> Enum.map(&normalize_contribution(&1, now))
      |> Enum.reject(&is_nil/1)

    if records == [] do
      :ok
    else
      Repo.insert_all(
        "device_risk_contributions",
        records,
        prefix: "platform",
        on_conflict:
          {:replace,
           [
             :score,
             :risk_level_id,
             :risk_level,
             :reason,
             :active,
             :occurred_at,
             :resolved_at,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:device_uid, :source, :source_ref]
      )

      records
      |> Enum.map(& &1.device_uid)
      |> Enum.uniq()
      |> recompute_devices(opts)
    end
  end

  def upsert_contribution(contribution, opts \\ []) when is_map(contribution) do
    upsert_contributions([contribution], opts)
  end

  def resolve_other_contributions(source, source_ref, current_device_uid, opts \\ [])

  def resolve_other_contributions(source, source_ref, current_device_uid, opts)
      when is_binary(current_device_uid) do
    source = normalize_source(source)
    source_ref = normalize_source_ref(source_ref)
    now = DateTime.utc_now()

    query =
      from(c in "device_risk_contributions",
        where:
          c.source == ^source and c.source_ref == ^source_ref and c.active == true and
            c.device_uid != ^current_device_uid,
        select: c.device_uid
      )

    {_count, device_uids} =
      Repo.update_all(
        query,
        [set: [active: false, resolved_at: now, updated_at: now]],
        prefix: "platform"
      )

    recompute_devices(device_uids || [], opts)
  end

  def resolve_other_contributions(_source, _source_ref, _current_device_uid, _opts), do: :ok

  def recompute_devices(device_uids, _opts \\ []) when is_list(device_uids) do
    Enum.each(Enum.uniq(device_uids), &recompute_device/1)
    :ok
  end

  def recompute_device(device_uid) when is_binary(device_uid) do
    case top_active_contribution(device_uid) do
      nil ->
        write_device_risk(device_uid, nil, nil, nil)

      contribution ->
        write_device_risk(
          device_uid,
          contribution.score,
          contribution.risk_level_id,
          contribution.risk_level
        )
    end
  end

  defp normalize_contribution(contribution, now) when is_map(contribution) do
    device_uid = contribution[:device_uid] || contribution["device_uid"]
    source = contribution[:source] || contribution["source"]
    score = contribution[:score] || contribution["score"]

    if not present?(device_uid) or not present?(source) or is_nil(score) do
      nil
    else
      score = normalize_score(score)
      {risk_level_id, risk_level} = risk_level_for_score(score)

      %{
        device_uid: to_string(device_uid),
        source: normalize_source(source),
        source_ref: normalize_source_ref(contribution[:source_ref] || contribution["source_ref"]),
        score: score,
        risk_level_id: risk_level_id,
        risk_level: risk_level,
        reason: contribution[:reason] || contribution["reason"],
        active: Map.get(contribution, :active, Map.get(contribution, "active", true)),
        occurred_at: contribution[:occurred_at] || contribution["occurred_at"] || now,
        resolved_at: contribution[:resolved_at] || contribution["resolved_at"],
        metadata: normalize_metadata(contribution[:metadata] || contribution["metadata"]),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp top_active_contribution(device_uid) do
    Repo.one(
      from(c in "device_risk_contributions",
        where: c.device_uid == ^device_uid and c.active == true,
        order_by: [desc: c.score, asc: c.source],
        limit: 1,
        select: %{score: c.score, risk_level_id: c.risk_level_id, risk_level: c.risk_level}
      ),
      prefix: "platform"
    )
  end

  defp write_device_risk(device_uid, score, level_id, level) do
    Repo.update_all(
      from(d in "ocsf_devices", where: d.uid == ^device_uid),
      [
        set: [
          risk_score: score,
          risk_level_id: level_id,
          risk_level: level,
          modified_time: DateTime.utc_now()
        ]
      ],
      prefix: "platform"
    )

    :ok
  end

  defp normalize_score(score) when is_integer(score), do: score |> max(0) |> min(100)

  defp normalize_score(score) when is_binary(score) do
    case Integer.parse(score) do
      {value, _} -> normalize_score(value)
      :error -> 0
    end
  end

  defp normalize_score(_), do: 0

  defp normalize_source(source) do
    source
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp normalize_source_ref(nil), do: "current"
  defp normalize_source_ref(""), do: "current"
  defp normalize_source_ref(value), do: to_string(value)

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true
end
