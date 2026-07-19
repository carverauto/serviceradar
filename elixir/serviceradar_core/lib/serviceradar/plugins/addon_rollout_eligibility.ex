defmodule ServiceRadar.Plugins.AddonRolloutEligibility do
  @moduledoc """
  Deterministic eligibility and compatibility checks for native add-on rollouts.

  Approval remains the security boundary. This module only selects a newer
  package when its provenance is trusted, its approved capabilities stay inside
  the source ceiling, and the target agent can run it.
  """

  alias ServiceRadar.Plugins.AddonPackage

  @default_freshness_seconds 180

  @spec latest_candidate(AddonPackage.t(), [AddonPackage.t()], map(), keyword()) ::
          {:ok, AddonPackage.t()} | {:blocked, atom(), AddonPackage.t()} | :none
  def latest_candidate(%AddonPackage{} = current, packages, source, opts \\ []) do
    blocked_ids = MapSet.new(Keyword.get(opts, :blocked_candidate_ids, []), &to_string/1)

    packages
    |> Enum.filter(&same_addon?(&1, current))
    |> Enum.filter(&same_source_origin?(&1, current))
    |> Enum.filter(&newer?(&1, current))
    |> Enum.filter(&channel_matches?(&1, source))
    |> Enum.filter(&trusted_approved?/1)
    |> Enum.reject(&MapSet.member?(blocked_ids, to_string(&1.id)))
    |> Enum.sort(&version_desc?/2)
    |> case do
      [] ->
        :none

      candidates ->
        case Enum.find(candidates, &within_capability_ceiling?(&1, source)) do
          nil -> {:blocked, :capability_ceiling_exceeded, hd(candidates)}
          candidate -> {:ok, candidate}
        end
    end
  end

  @spec classify_target(AddonPackage.t(), map() | nil, DateTime.t(), keyword()) ::
          {:eligible | :unavailable | :incompatible | :unresolved, String.t() | nil}
  def classify_target(package, agent, now \\ DateTime.utc_now(), opts \\ [])

  def classify_target(%AddonPackage{}, nil, _now, _opts), do: {:unresolved, "agent_not_enrolled"}

  def classify_target(%AddonPackage{} = package, agent, now, opts) do
    freshness_seconds =
      Keyword.get(opts, :freshness_seconds, @default_freshness_seconds)

    cond do
      not platform_allowed?(package, agent) ->
        {:incompatible, "unsupported_platform"}

      not artifact_available?(package, agent) ->
        {:incompatible, "missing_platform_artifact"}

      not agent_version_allowed?(package, agent) ->
        {:incompatible, "incompatible_base_agent_version"}

      missing_required_capabilities(package, agent) != [] ->
        {:incompatible, "missing_required_agent_capability"}

      not agent_available?(agent, now, freshness_seconds) ->
        {:unavailable, "agent_unavailable_or_stale"}

      true ->
        {:eligible, nil}
    end
  end

  @spec trusted_approved?(AddonPackage.t()) :: boolean()
  def trusted_approved?(%AddonPackage{} = package) do
    package.status == :approved and package.verification_status == "verified" and
      is_nil(package.verification_error) and
      is_binary(package.source_oci_digest) and package.source_oci_digest != ""
  end

  @spec within_capability_ceiling?(AddonPackage.t(), map()) :: boolean()
  def within_capability_ceiling?(%AddonPackage{} = package, source) do
    ceiling = source |> value(:capability_ceiling, []) |> normalize_strings() |> MapSet.new()
    requested = package.approved_capabilities |> normalize_strings() |> MapSet.new()
    MapSet.subset?(requested, ceiling)
  end

  @spec supervision_ready?(AddonPackage.t(), map()) :: boolean()
  def supervision_ready?(%AddonPackage{supervision: supervision}, status) do
    state = status |> value(:state, "") |> to_string() |> String.downcase()
    active? = value(status, :active, false) == true
    degraded? = present?(value(status, :degradation_reason))

    not degraded? and
      case supervision do
        model when model in [:agent_sidecar, :systemd_service] ->
          active? and state in ["active", "healthy", "running"]

        :systemd_timer ->
          state in ["active", "enabled", "healthy", "ready", "running", "waiting"]

        :ephemeral_helper ->
          state in ["healthy", "ready", "registered", "staged", "verified"]

        :config_toggle ->
          state in ["active", "applied", "healthy", "ready", "running"]

        _ ->
          false
      end
  end

  defp same_addon?(%AddonPackage{addon_id: addon_id}, %AddonPackage{addon_id: addon_id}), do: true

  defp same_addon?(_candidate, _current), do: false

  defp same_source_origin?(candidate, current) do
    candidate.source_type == current.source_type and
      oci_repository(candidate.source_oci_ref) == oci_repository(current.source_oci_ref)
  end

  defp oci_repository(value) when is_binary(value) do
    value
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.replace(~r/:[^\/:]+$/, "")
  end

  defp oci_repository(_value), do: nil

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

  defp channel_matches?(%AddonPackage{} = package, source) do
    requested = source |> value(:release_channel, "stable") |> to_string()

    case parse_version(package.version) do
      {:ok, %Version{pre: []}} -> requested == "stable"
      {:ok, %Version{pre: [channel | _]}} -> requested == to_string(channel)
      _ -> false
    end
  end

  defp platform_allowed?(package, agent) do
    supported = package.requires |> value(:platforms, []) |> normalize_strings()
    os = agent_component(agent, :os)
    supported == [] or (is_binary(os) and os in supported)
  end

  defp artifact_available?(%AddonPackage{delivery: delivery}, _agent)
       when delivery != :pushed_artifact, do: true

  defp artifact_available?(package, agent) do
    os = agent_component(agent, :os)
    arch = agent_component(agent, :arch)

    if is_binary(os) and is_binary(arch) do
      case Map.get(package.artifacts || %{}, "#{os}/#{arch}") do
        artifact when is_map(artifact) ->
          present?(value(artifact, :object_key)) and present?(value(artifact, :sha256))

        _ ->
          false
      end
    else
      false
    end
  end

  defp agent_version_allowed?(package, agent) do
    case value(package.requires || %{}, :base_agent) do
      nil -> true
      "" -> true
      requirement -> version_matches?(value(agent, :version), requirement)
    end
  end

  defp missing_required_capabilities(package, agent) do
    actual = agent |> value(:capabilities, []) |> normalize_strings() |> MapSet.new()

    package.requires
    |> value(:agent_capabilities, [])
    |> normalize_strings()
    |> Enum.reject(&MapSet.member?(actual, &1))
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

  defp agent_component(agent, component) do
    metadata = value(agent, :metadata, %{}) || %{}

    normalize_component(
      value(agent, component) || value(metadata, component) ||
        value(metadata, String.to_atom("platform_#{component}"))
    )
  end

  defp normalize_component(nil), do: nil

  defp normalize_component(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp version_matches?(version, requirement)
       when is_binary(version) and is_binary(requirement) do
    with {:ok, parsed_version} <- parse_version(version),
         {:ok, parsed_requirement} <- Version.parse_requirement(requirement) do
      Version.match?(parsed_version, parsed_requirement)
    else
      _ -> false
    end
  end

  defp version_matches?(_, _), do: false

  defp parse_version(value) when is_binary(value),
    do: value |> String.trim() |> String.trim_leading("v") |> Version.parse()

  defp parse_version(_), do: :error

  defp normalize_strings(values),
    do: values |> List.wrap() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.uniq()

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_, _, default), do: default

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
