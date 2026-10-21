defmodule ServiceRadar.Plugins.AddonRolloutEligibility do
  @moduledoc """
  Deterministic candidate selection and target classification for fleet rollouts.

  Approval remains the security boundary. This module only selects a newer
  package when its provenance is trusted, its approved capabilities stay inside
  the source ceiling, and the target agent can run it. Semantic-version order,
  release channels, blocked candidates and agent availability are decided here;
  what counts as the same artifact, as trusted, as within the ceiling and as
  compatible with an agent is the `ServiceRadar.Plugins.RolloutArtifact`
  implementation's answer.
  """

  alias ServiceRadar.Plugins.RolloutArtifact

  @default_freshness_seconds 180

  @spec latest_candidate(RolloutArtifact.package(), [RolloutArtifact.package()], map(), keyword()) ::
          {:ok, RolloutArtifact.package()}
          | {:blocked, atom(), RolloutArtifact.package()}
          | :none
  def latest_candidate(current, packages, source, opts \\ []) do
    artifact = RolloutArtifact.implementation(source)
    blocked_ids = MapSet.new(Keyword.get(opts, :blocked_candidate_ids, []), &to_string/1)

    packages
    |> Enum.filter(&artifact.same_lineage?(&1, current))
    |> Enum.filter(&newer?(&1, current))
    |> Enum.filter(&channel_matches?(&1, source))
    |> Enum.filter(&artifact.trusted_approved?/1)
    |> Enum.reject(&MapSet.member?(blocked_ids, to_string(&1.id)))
    |> Enum.sort(&version_desc?/2)
    |> case do
      [] ->
        :none

      candidates ->
        case Enum.find(candidates, &artifact.within_capability_ceiling?(&1, source)) do
          nil -> {:blocked, :capability_ceiling_exceeded, hd(candidates)}
          candidate -> {:ok, candidate}
        end
    end
  end

  @spec classify_target(RolloutArtifact.package(), map() | nil, DateTime.t(), keyword()) ::
          {:eligible | :unavailable | :incompatible | :unresolved, String.t() | nil}
  def classify_target(package, agent, now \\ DateTime.utc_now(), opts \\ [])

  def classify_target(_package, nil, _now, _opts), do: {:unresolved, "agent_not_enrolled"}

  def classify_target(package, agent, now, opts) do
    freshness_seconds =
      Keyword.get(opts, :freshness_seconds, @default_freshness_seconds)

    case RolloutArtifact.implementation(package).incompatibility(package, agent) do
      nil ->
        if agent_available?(agent, now, freshness_seconds),
          do: {:eligible, nil},
          else: {:unavailable, "agent_unavailable_or_stale"}

      reason ->
        {:incompatible, reason}
    end
  end

  @doc """
  Whether `observed` is at least `target`, by semantic version.

  Deliberately NOT a string comparison: `"0.2.7" >= "0.2.26"` is true
  lexically and false in fact, and the fleet routinely runs versions where that
  distinction decides whether a rollout is finished.

  Returns false when either side is unparseable, so an add-on that cannot report
  a usable version is never mistaken for one that has reached the target.
  """
  @spec version_at_least?(String.t() | nil, String.t() | nil) :: boolean()
  def version_at_least?(observed, target) do
    with {:ok, observed_version} <- parse_version(observed),
         {:ok, target_version} <- parse_version(target) do
      Version.compare(observed_version, target_version) in [:gt, :eq]
    else
      _ -> false
    end
  end

  @doc "Parses a reported version, tolerating surrounding whitespace and a leading `v`."
  @spec parse_version(term()) :: {:ok, Version.t()} | :error
  def parse_version(value) when is_binary(value),
    do: value |> String.trim() |> String.trim_leading("v") |> Version.parse()

  def parse_version(_), do: :error

  defp newer?(candidate, current) do
    with {:ok, candidate_version} <- parse_version(candidate.version),
         {:ok, current_version} <- parse_version(current.version) do
      Version.compare(candidate_version, current_version) == :gt
    else
      _ -> false
    end
  end

  defp version_desc?(left, right) do
    with {:ok, left_version} <- parse_version(left.version),
         {:ok, right_version} <- parse_version(right.version) do
      case Version.compare(left_version, right_version) do
        :gt -> true
        :lt -> false
        :eq -> to_string(left.id) <= to_string(right.id)
      end
    else
      _ -> to_string(left.version) >= to_string(right.version)
    end
  end

  defp channel_matches?(package, source) do
    requested = source |> value(:release_channel, "stable") |> to_string()

    case parse_version(package.version) do
      {:ok, %Version{pre: []}} -> requested == "stable"
      {:ok, %Version{pre: [channel | _]}} -> requested == to_string(channel)
      _ -> false
    end
  end

  defp agent_available?(agent, now, freshness_seconds) do
    status = value(agent, :status)
    healthy? = value(agent, :is_healthy, true) != false
    last_seen = value(agent, :last_seen_time)

    status == :connected and healthy? and fresh?(last_seen, now, freshness_seconds)
  end

  defp fresh?(%DateTime{} = observed_at, %DateTime{} = now, freshness_seconds),
    do: DateTime.diff(now, observed_at, :second) <= freshness_seconds

  defp fresh?(_, _, _), do: false

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_, _, default), do: default
end
