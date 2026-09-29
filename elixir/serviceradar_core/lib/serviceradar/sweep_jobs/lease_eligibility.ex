defmodule ServiceRadar.SweepJobs.LeaseEligibility do
  @moduledoc """
  Whether a sweep group can be scheduled by core ahead of time, and if so what it needs.

  A group is leased only when it is enabled, has static targets and no SRQL target query, and
  the edge record format can carry everything it does:

    * every target is a bare address or CIDR that a plan range can hold;
    * its effective modes and ports (profile as base, group overrides on top, exactly as the
      sweep compiler computes them) reduce to ICMP and TCP checks, with no MTR;
    * banner grabbing is off, since the format has nowhere to put banner results;
    * its schedule is an interval of at least `LeaseSchedule.min_interval_seconds/0`, or cron.

  A group that fails any of these stays on the legacy path. One execution is never split
  across the two paths.
  """

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.Edge.SweepPlan
  alias ServiceRadar.SweepJobs.LeaseSchedule
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile

  @type plan_inputs :: %{
          targets: [String.t()],
          checks: [SweepPlan.check()],
          check_set_sha256: binary(),
          schedule: LeaseSchedule.spec()
        }

  @type reason ::
          :disabled
          | :no_static_targets
          | :has_target_query
          | :banner_grab_enabled
          | SweepPlan.reason()
          | LeaseSchedule.reason()

  @doc """
  What a lease of the group is built from, or why the group is not eligible. `profile` is the
  group's sweep profile, or `nil` when it has none.
  """
  @spec evaluate(SweepGroup.t(), SweepProfile.t() | nil) ::
          {:ok, plan_inputs()} | {:error, reason()}
  def evaluate(%SweepGroup{} = group, profile \\ nil) do
    with :ok <- enabled(group),
         :ok <- no_target_query(group),
         {:ok, targets} <- static_targets(group),
         :ok <- representable(targets),
         :ok <- no_banner_grab(group, profile),
         {:ok, checks} <- checks(group, profile),
         {:ok, schedule} <- LeaseSchedule.parse(group) do
      {:ok,
       %{
         targets: targets,
         checks: checks,
         check_set_sha256: SweepPlan.check_set_sha256(checks),
         schedule: schedule
       }}
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

  defp checks(group, profile) do
    %{modes: modes, ports: ports} = SweepCompiler.compiled_scan_settings(group, profile)
    SweepPlan.checks(modes, ports)
  end
end
