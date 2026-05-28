defmodule ServiceRadar.Inventory.AvailabilitySourceProfileMaterializer do
  @moduledoc """
  Applies SRQL-scoped availability source profiles to canonical devices.

  A non-null `devices.availability_source_profile_id` marks a profile-derived
  assignment. A non-null `availability_source_agent_id` with no profile id is a
  per-device override and is intentionally left untouched by profile evaluation.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.AvailabilitySourceProfile
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Repo
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  require Ash.Query
  require Logger

  @default_page_limit 5_000
  @preview_limit 25

  @type preview :: %{
          query: String.t(),
          total_count: non_neg_integer(),
          rows: [map()]
        }

  @spec preview_scope(String.t(), keyword()) :: {:ok, preview()} | {:error, term()}
  def preview_scope(query, opts \\ []) when is_binary(query) do
    runner = runner(opts)

    with {:ok, normalized} <- normalize_device_query(query),
         {:ok, %{rows: rows}} <- runner.query_page(normalized, limit: preview_limit(opts)) do
      {:ok, %{query: normalized, total_count: length(rows), rows: rows}}
    end
  end

  @spec materialize(keyword()) :: {:ok, map()} | {:error, term()}
  def materialize(opts \\ []) do
    with {:ok, profiles} <- load_enabled_profiles(opts),
         {:ok, profile_matches} <- resolve_profile_matches(profiles, opts) do
      apply_profile_matches(profile_matches, opts)
    end
  end

  defp load_enabled_profiles(opts) do
    ash_opts = ash_opts(opts)

    AvailabilitySourceProfile
    |> Ash.Query.for_read(:enabled, %{}, ash_opts)
    |> Ash.read(ash_opts)
    |> unwrap_page()
  end

  defp resolve_profile_matches(profiles, opts) do
    profiles
    |> Enum.reduce_while({:ok, []}, fn profile, {:ok, acc} ->
      case resolve_profile(profile, opts) do
        {:ok, match} -> {:cont, {:ok, [match | acc]}}
        {:error, reason} -> {:halt, {:error, {profile.id, reason}}}
      end
    end)
    |> case do
      {:ok, matches} -> {:ok, Enum.reverse(matches)}
      error -> error
    end
  end

  defp resolve_profile(profile, opts) do
    with {:ok, normalized} <- normalize_device_query(profile.srql_query),
         {:ok, uids} <- collect_device_uids(normalized, opts) do
      {:ok, %{profile: profile, query: normalized, uids: uids}}
    end
  end

  defp normalize_device_query(query) do
    normalized = SRQLQuery.ensure_target(query, :devices)

    if SRQLAst.entity(normalized) == "devices" do
      {:ok, normalized}
    else
      {:error, :profile_scope_must_target_devices}
    end
  end

  defp collect_device_uids(query, opts) do
    page_limit = Keyword.get(opts, :page_limit, @default_page_limit)
    collect_device_uids(query, nil, page_limit, MapSet.new(), opts)
  end

  defp collect_device_uids(query, cursor, page_limit, acc, opts) do
    runner = runner(opts)

    query_opts = maybe_put([limit: page_limit], :cursor, cursor)

    case runner.query_page(query, query_opts) do
      {:ok, %{rows: rows, next_cursor: next_cursor}} ->
        next_acc = Enum.reduce(rows, acc, &collect_uid/2)

        if is_binary(next_cursor) and next_cursor != "" do
          collect_device_uids(query, next_cursor, page_limit, next_acc, opts)
        else
          {:ok, next_acc |> MapSet.to_list() |> Enum.sort()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_uid(row, acc) when is_map(row) do
    case Map.get(row, "uid") || Map.get(row, :uid) || Map.get(row, "id") || Map.get(row, :id) do
      uid when is_binary(uid) and uid != "" -> MapSet.put(acc, uid)
      _ -> acc
    end
  end

  defp collect_uid(_row, acc), do: acc

  defp apply_profile_matches(profile_matches, _opts) do
    now = DateTime.utc_now()

    winning_by_uid = winning_assignments(profile_matches)
    winning_profile_ids = profile_matches |> Enum.map(& &1.profile.id) |> Enum.uniq()
    winning_uids = Map.keys(winning_by_uid)

    fn ->
      cleared = clear_stale_profile_assignments(winning_profile_ids, winning_uids, now)
      applied_by_profile = apply_winning_assignments(winning_by_uid, now)
      update_profile_stats(profile_matches, applied_by_profile, now)

      %{
        profiles: length(profile_matches),
        matched_devices: length(winning_uids),
        applied_devices: applied_by_profile |> Map.values() |> Enum.sum(),
        cleared_devices: cleared
      }
    end
    |> Repo.transaction()
    |> case do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp winning_assignments(profile_matches) do
    Enum.reduce(profile_matches, %{}, fn %{profile: profile, uids: uids}, acc ->
      Enum.reduce(uids, acc, fn uid, inner ->
        Map.put_new(inner, uid, profile)
      end)
    end)
  end

  defp clear_stale_profile_assignments([], _winning_uids, now) do
    {count, _} =
      Device
      |> where([d], not is_nil(d.availability_source_profile_id))
      |> Repo.update_all(
        set: [
          availability_source_agent_id: nil,
          availability_source_profile_id: nil,
          modified_time: now
        ]
      )

    count
  end

  defp clear_stale_profile_assignments(_profile_ids, [], now) do
    {count, _} =
      Device
      |> where([d], not is_nil(d.availability_source_profile_id))
      |> Repo.update_all(
        set: [
          availability_source_agent_id: nil,
          availability_source_profile_id: nil,
          modified_time: now
        ]
      )

    count
  end

  defp clear_stale_profile_assignments(profile_ids, winning_uids, now) do
    {count, _} =
      Device
      |> where(
        [d],
        not is_nil(d.availability_source_profile_id) and
          (d.availability_source_profile_id not in ^profile_ids or d.uid not in ^winning_uids)
      )
      |> Repo.update_all(
        set: [
          availability_source_agent_id: nil,
          availability_source_profile_id: nil,
          modified_time: now
        ]
      )

    count
  end

  defp apply_winning_assignments(winning_by_uid, now) do
    winning_by_uid
    |> Enum.group_by(fn {_uid, profile} -> profile end, fn {uid, _profile} -> uid end)
    |> Map.new(fn {profile, uids} ->
      {count, _} =
        Device
        |> where([d], d.uid in ^uids)
        |> where(
          [d],
          not is_nil(d.availability_source_profile_id) or
            is_nil(d.availability_source_agent_id) or
            fragment("NULLIF(BTRIM(?), '') IS NULL", d.availability_source_agent_id)
        )
        |> Repo.update_all(
          set: [
            availability_source_agent_id: profile.agent_id,
            availability_source_profile_id: profile.id,
            modified_time: now
          ]
        )

      {profile.id, count}
    end)
  end

  defp update_profile_stats(profile_matches, applied_by_profile, now) do
    Enum.each(profile_matches, fn %{profile: profile, uids: uids} ->
      applied = Map.get(applied_by_profile, profile.id, 0)

      AvailabilitySourceProfile
      |> where([p], p.id == ^profile.id)
      |> Repo.update_all(
        set: [
          match_count: length(uids),
          applied_count: applied,
          last_evaluated_at: now
        ]
      )
    end)
  end

  defp unwrap_page({:ok, %{results: results}}), do: {:ok, results}
  defp unwrap_page({:ok, results}) when is_list(results), do: {:ok, results}
  defp unwrap_page({:error, reason}), do: {:error, reason}

  defp runner(opts), do: Keyword.get(opts, :runner, SRQLRunner)
  defp preview_limit(opts), do: Keyword.get(opts, :preview_limit, @preview_limit)

  defp ash_opts(opts) do
    cond do
      scope = Keyword.get(opts, :scope) -> [scope: scope]
      actor = Keyword.get(opts, :actor) -> [actor: actor]
      true -> []
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
