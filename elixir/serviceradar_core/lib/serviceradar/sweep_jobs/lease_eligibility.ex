defmodule ServiceRadar.SweepJobs.LeaseEligibility do
  @moduledoc """
  Whether a sweep group can be scheduled by core ahead of time, and if so what it needs.

  A group is leased only when it is enabled, has static targets and no SRQL target query, and
  the edge record format can carry everything it does:

    * every target is a bare address or CIDR that a plan range can hold;
    * banner grabbing is off, since the format has nowhere to put banner results;
    * its schedule is an interval of at least `LeaseSchedule.min_interval_seconds/0`, or cron.

  Those are properties of the group (`evaluate_group/2`). The checks are a property of the
  group as one agent runs it (`agent_checks/3`): the modes and ports that agent's delivered
  sweep config carries for the group (`SweepCompiler.agent_scan_modes/3`, so profile as base,
  group overrides on top, and the modes the agent reports it cannot run withheld), which must
  reduce to at least one ICMP or TCP check (`mtr` is ignored here so reachability and port modes
  run under the sweep lease). The lease carries those checks and the agent runs
  exactly them, so a mode it reports it cannot run must not be in them. An agent that can run
  none of the group's modes is not leased the group, as it is not sent the group at all. An
  agent reporting `tcp_syn_ipv6.unavailable` would run TCP SYN on an IPv6 range as a connect
  scan, which the plan does not sign, so a group whose checks include TCP SYN and whose
  targets include an IPv6 range is not leased to it. One plan carries one check set, so that
  mode cannot be withheld for the IPv6 ranges alone.

  A group that fails any of these stays on the legacy path, for that agent or, for a group
  property, for every agent. One execution is never split across the two paths.
  """

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.Edge.SweepPlan
  alias Serviceradar.Edge.V1.SweepMode
  alias ServiceRadar.SweepJobs.LeaseSchedule
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile

  @ipv6_syn_unavailable "tcp_syn_ipv6.unavailable"
  @mode_tcp_syn SweepMode.value(:SWEEP_MODE_TCP_SYN)

  @type plan_inputs :: %{
          targets: [String.t()],
          checks: [SweepPlan.check()],
          check_set_sha256: binary(),
          schedule: LeaseSchedule.spec()
        }

  @type group_inputs :: %{targets: [String.t()], schedule: LeaseSchedule.spec()}

  @type agent_inputs :: %{checks: [SweepPlan.check()], check_set_sha256: binary()}

  @type capabilities :: [String.t() | atom()] | nil

  @type reason ::
          :disabled
          | :no_static_targets
          | :has_target_query
          | :banner_grab_enabled
          | :all_modes_withheld
          | :ipv6_syn_unavailable
          | SweepPlan.reason()
          | LeaseSchedule.reason()

  @doc """
  What a lease of the group to an agent reporting `capabilities` is built from, or why the
  group is not eligible for that agent. `profile` is the group's sweep profile, or `nil` when
  it has none; `nil` capabilities are unknown and withhold no mode.
  """
  @spec evaluate(SweepGroup.t(), SweepProfile.t() | nil, capabilities()) ::
          {:ok, plan_inputs()} | {:error, reason()}
  def evaluate(%SweepGroup{} = group, profile \\ nil, capabilities \\ nil) do
    with {:ok, group_inputs} <- evaluate_group(group, profile),
         {:ok, agent_inputs} <- agent_checks(group, profile, capabilities) do
      {:ok, Map.merge(group_inputs, agent_inputs)}
    end
  end

  @doc """
  The part of a lease that is the same for every agent (targets and schedule), or why no
  agent can be leased the group.
  """
  @spec evaluate_group(SweepGroup.t(), SweepProfile.t() | nil) ::
          {:ok, group_inputs()} | {:error, reason()}
  def evaluate_group(%SweepGroup{} = group, profile) do
    with :ok <- enabled(group),
         :ok <- no_target_query(group),
         {:ok, targets} <- static_targets(group),
         :ok <- representable(targets),
         :ok <- no_banner_grab(group, profile),
         {:ok, schedule} <- LeaseSchedule.parse(group) do
      {:ok, %{targets: targets, schedule: schedule}}
    end
  end

  @doc """
  The checks of the group as an agent reporting `capabilities` runs it, and their
  `check_set_sha256`: exactly the checks of that agent's delivered sweep config for the group.
  `{:error, :all_modes_withheld}` when the agent can run none of the group's modes, and
  `{:error, :ipv6_syn_unavailable}` when the checks need raw IPv6 SYN on one of the group's
  IPv6 ranges and the agent reports it cannot run it.
  """
  @spec agent_checks(SweepGroup.t(), SweepProfile.t() | nil, capabilities()) ::
          {:ok, agent_inputs()} | {:error, reason()}
  def agent_checks(%SweepGroup{} = group, profile, capabilities) do
    with {:ok, %{modes: modes, ports: ports}} <- agent_scan_modes(group, profile, capabilities),
         {:ok, checks} <- SweepPlan.checks(modes, ports),
         :ok <- ipv6_syn_runnable(group, checks, capabilities) do
      {:ok, %{checks: checks, check_set_sha256: SweepPlan.check_set_sha256(checks)}}
    end
  end

  defp ipv6_syn_runnable(group, checks, capabilities) do
    if reports?(capabilities, @ipv6_syn_unavailable) and
         Enum.any?(checks, &match?({@mode_tcp_syn, _, _}, &1)) and ipv6_target?(group) do
      {:error, :ipv6_syn_unavailable}
    else
      :ok
    end
  end

  defp reports?(capabilities, marker),
    do: Enum.any?(List.wrap(capabilities), &(to_string(&1) == marker))

  # An IPv4-mapped address is IPv4 to the agent's scanner, as `net.IP.To4` reads it.
  defp ipv6_target?(%{static_targets: targets}) when is_list(targets) do
    Enum.any?(targets, fn target ->
      with {:ok, %{cidr: cidr}} <- SweepPlan.canonical_target(target),
           [address | _] = String.split(cidr, "/"),
           {:ok, ip} <- :inet.parse_address(String.to_charlist(address)) do
        ipv6_address?(ip)
      else
        _ -> false
      end
    end)
  end

  defp ipv6_target?(_group), do: false

  defp ipv6_address?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false
  defp ipv6_address?(ip), do: tuple_size(ip) == 8

  defp agent_scan_modes(group, profile, capabilities) do
    case SweepCompiler.agent_scan_modes(group, profile, capabilities) do
      {:ok, scan} -> {:ok, scan}
      {:withheld, _modes} -> {:error, :all_modes_withheld}
    end
  end

  defp enabled(%{enabled: true}), do: :ok
  defp enabled(_group), do: {:error, :disabled}

  defp no_target_query(%{target_query: query}) when is_binary(query) do
    if String.trim(query) == "", do: :ok, else: {:error, :has_target_query}
  end

  defp no_target_query(_group), do: :ok

  defp static_targets(%{static_targets: targets}) when is_list(targets) do
    case targets |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> {:error, :no_static_targets}
      trimmed -> {:ok, Enum.uniq(trimmed)}
    end
  end

  defp static_targets(_group), do: {:error, :no_static_targets}

  defp representable(targets) do
    Enum.find_value(targets, :ok, fn target ->
      case SweepPlan.canonical_target(target) do
        {:ok, _canonical} -> nil
        {:error, _} = error -> error
      end
    end)
  end

  defp no_banner_grab(group, profile) do
    if SweepCompiler.banner_grab_enabled?(group, profile),
      do: {:error, :banner_grab_enabled},
      else: :ok
  end
end
