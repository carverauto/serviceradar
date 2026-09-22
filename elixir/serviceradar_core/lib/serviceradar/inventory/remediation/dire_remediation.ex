defmodule ServiceRadar.Inventory.Remediation.DireRemediation do
  @moduledoc """
  Orchestrator for the operator-invoked DIRE production data remediation
  (OpenSpec refactor-device-identity-reconciliation tasks 4.1-4.4), driven
  by `mix serviceradar.dire_remediation`.

  Idempotent, dry-run by default, and safe to ship dormant: nothing runs
  unless an operator invokes the mix task, and nothing writes unless
  `mode: :execute` is passed. Execute mode writes an NDJSON rollback
  manifest of every row touched (ids only).

  Step order (each independently runnable via `steps:`):

    1. `blob-purge`   — extract first-MAC fallbacks, purge invalid mac rows (4.1)
    2. `test-debris`  — delete 2026-04-25 test artifacts + reip devices (4.2)
    3. `stale-agent-devices` — remove historical unavailable agent churn
    4. `agent-links`  — rebuild agent->device links from ocsf_agents ground
       truth, fix stranded identifiers/poisoned aliases/ip literal (4.3)
    5. `proxmox-dups` — collapse intra-Proxmox duplicate hostname groups (4.4)
    6. `proxmox-unfuse` — explicit-only Proxmox cross-cluster split
       planning/disposition (GitHub #4051; execute gated; see below)
    7. `armis-unmerge` — explicit-only Armis split planning/disposition
       (execute gated; see below)
    8. `armis-dups`   — collapse Armis rows onto their armis_device_id owner
       (DISABLED by default — see `@armis_dups_step` below)

  ## `armis-dups` is disabled by default

  `armis-dups` collapses every device sharing one `armis_device_id` onto a
  single canonical. That is the exact mechanism behind the armis-overmerge
  incident: an Armis "device" aggregates a whole scanned subnet, so this step
  re-collapses devices that the ingest-time distinct-MAC veto (BatchResolver)
  deliberately split apart by their distinct hardware MACs. It is therefore
  excluded from the default run order and only executes when explicitly
  re-enabled via config:

      config :serviceradar_core, ServiceRadar.Inventory.Remediation.DireRemediation,
        enable_armis_dups: true

  Leave it off unless an operator has confirmed the armis_device_id values are
  genuinely one-device-per-id for the data being remediated.

  ## `armis-unmerge` execute mode is gated

  Operators may explicitly request `armis-unmerge` in dry-run mode to collect
  the live-scoping report. Execute mode is rejected until the live population,
  Armis identifier disposition, and multi-NIC handling have been reviewed and
  the following runtime configuration is deliberately enabled:

      config :serviceradar_core, ServiceRadar.Inventory.Remediation.DireRemediation,
        enable_armis_unmerge_execute: true

  Enabling the gate does not add the step to the default run. It remains an
  explicit-request-only operation.

  ## `proxmox-unfuse`

  See `Mix.Tasks.Serviceradar.DireRemediation` for the authoritative operator
  workflow, runtime execute gate, and live device/source scoping options.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Remediation.AgentLinks
  alias ServiceRadar.Inventory.Remediation.ArmisDups
  alias ServiceRadar.Inventory.Remediation.ArmisUnmerge
  alias ServiceRadar.Inventory.Remediation.BlobPurge
  alias ServiceRadar.Inventory.Remediation.LinkLocalAliasArchive
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.NetprobeAliasDebris
  alias ServiceRadar.Inventory.Remediation.ProxmoxDups
  alias ServiceRadar.Inventory.Remediation.ProxmoxUnfuse
  alias ServiceRadar.Inventory.Remediation.StaleAgentDevices
  alias ServiceRadar.Inventory.Remediation.TestDebris

  require Logger

  # The armis-overmerge root cause: collapsing all devices that share one
  # armis_device_id onto a single canonical. Excluded from the default order so
  # it can never re-collapse the devices the ingest-time distinct-MAC veto
  # splits apart. Re-enable only via config (`enable_armis_dups: true`).
  @armis_dups_step "armis-dups"

  # The armis-overmerge DISPOSITION (inverse of armis-dups): reconstruct
  # per-hardware devices from a mega-device's distinct universal MACs and rescue
  # the orphaned sole-copy MAC rows. Omitted from the default order so it only
  # runs when an operator explicitly requests `steps: ["armis-unmerge"]` (after
  # the live scoping that excludes the faker fleet); it is otherwise dormant.
  @armis_unmerge_step "armis-unmerge"

  # The proxmox cross-cluster over-merge DISPOSITION (GitHub #4051): split
  # devices whose registered v2 ids span clusters back into per-cluster
  # devices. Omitted from the default order so it only runs when an operator
  # explicitly requests `steps: ["proxmox-unfuse"]` (after reviewing the
  # dry-run cluster/MAC attribution report); it is otherwise dormant.
  @proxmox_unfuse_step "proxmox-unfuse"

  # Split-disposition steps are always explicit-request-only (dormant): they
  # mutate live devices and each has its own execute gate below.
  @explicit_only_steps [@armis_unmerge_step, @proxmox_unfuse_step]

  @step_order [
    "blob-purge",
    "test-debris",
    "stale-agent-devices",
    # Archive leftover link-local aliases before any step that can merge.
    "link-local-alias-archive",
    "netprobe-alias-debris",
    "agent-links",
    "proxmox-dups",
    @proxmox_unfuse_step,
    @armis_unmerge_step,
    @armis_dups_step
  ]

  @doc """
  Ordered list of steps included by a default `all` run.

  Split-disposition steps (`armis-unmerge`, `proxmox-unfuse`) are always
  omitted. `armis-dups` is omitted unless explicitly re-enabled via config
  (it is the armis-overmerge re-collapse vector — see the moduledoc).
  """
  @spec steps() :: [String.t()]
  def steps, do: default_steps()

  @doc """
  Ordered list of steps accepted by an explicit invocation in `mode`.

  This is distinct from `steps/0`: split-disposition steps are available for
  explicit dry-runs but never belong to a default `all` run. Execute
  availability also reflects each step's live-scoping runtime gate.
  """
  @spec available_steps(:dry_run | :execute) :: [String.t()]
  def available_steps(mode \\ :dry_run)

  def available_steps(:dry_run), do: configured_steps()

  def available_steps(:execute) do
    Enum.reject(configured_steps(), fn step ->
      step in @explicit_only_steps and not split_execute_enabled?(step)
    end)
  end

  # Default run order with armis-dups gated off unless config opts back in.
  # Split-disposition steps are always excluded from the default order — they
  # are explicit-request-only (dormant) until live scoping confirms the
  # population.
  defp default_steps do
    configured_steps() -- @explicit_only_steps
  end

  defp configured_steps do
    if armis_dups_enabled?() do
      @step_order
    else
      @step_order -- [@armis_dups_step]
    end
  end

  defp armis_dups_enabled? do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enable_armis_dups, false)
  end

  defp armis_unmerge_execute_enabled? do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enable_armis_unmerge_execute, false)
  end

  defp split_execute_enabled?(@armis_unmerge_step), do: armis_unmerge_execute_enabled?()

  defp split_execute_enabled?(@proxmox_unfuse_step) do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enable_proxmox_unfuse_execute, false)
  end

  defp split_execute_enabled?(_step), do: false

  @doc """
  Run the remediation.

  Options:

    * `:mode` — `:dry_run` (default) or `:execute`
    * `:steps` — subset of `#{inspect(@step_order)}` (or `["all"]`, default)
    * `:manifest_path` — rollback manifest path (execute mode only; default
      `dire_remediation_<ts>.ndjson` under the system tmp dir)
    * `:batch_size` — blob purge batch size (default 50_000)
    * `:actor` — Ash actor (default `SystemActor.system(:dire_remediation)`)
    * step-specific options: `:debris_date`, `:debris_null_patterns`,
      `:debris_sim_patterns`, `:debris_device_agent_prefix`,
      `:debris_hostnames`, `:stale_agent_uids`, `:stale_agent_prefixes`,
      `:stale_agent_before`, `:agent_uids`, `:agent_statuses`, `:ip_literal`,
      `:proxmox_source`, `:hostname_denylist`, `:armis_plan_sample_limit`,
      `:armis_unmerge_candidate_limit`, `:armis_unmerge_plan_sample_limit`,
      `:armis_unmerge_include_live`, `:armis_unmerge_live_device_uids`,
      `:armis_unmerge_live_source_ids`, `:proxmox_unfuse_candidate_limit`,
      `:proxmox_unfuse_plan_sample_limit`, `:proxmox_unfuse_include_live`,
      `:proxmox_unfuse_live_device_uids`, `:proxmox_unfuse_live_source_ids`

  Returns `{:ok, result}` when all selected steps complete without reported
  failures. If any report contains a positive `errors` or `*_failures` count,
  returns `{:error, {:step_failures, result}}`; `result` still contains every
  report, the failure counts, and the rollback manifest path.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :dry_run)
    actor = Keyword.get(opts, :actor) || SystemActor.system(:dire_remediation)

    with {:ok, steps} <- resolve_steps(Keyword.get(opts, :steps, ["all"]), mode) do
      {manifest, manifest_path} = maybe_open_manifest(mode, opts, steps)

      try do
        reports =
          Enum.reduce(steps, %{}, fn step, reports ->
            Logger.info("DireRemediation: running step #{step} (#{mode})")

            Map.put(
              reports,
              step,
              run_step(step, mode, runtime_step_opts(step, opts), manifest, actor)
            )
          end)

        result = %{mode: mode, manifest_path: manifest_path, reports: reports}
        failures = report_failures(reports)

        if map_size(failures) == 0 do
          {:ok, result}
        else
          {:error, {:step_failures, Map.put(result, :failures, failures)}}
        end
      after
        Manifest.close(manifest)
      end
    end
  end

  @doc false
  @spec report_failures(map()) :: map()
  def report_failures(reports) when is_map(reports) do
    Enum.reduce(reports, %{}, fn {step, report}, failures ->
      step_failures =
        report
        |> Enum.filter(fn {key, value} -> failure_value?(key, value) end)
        |> Map.new()

      if map_size(step_failures) == 0 do
        failures
      else
        Map.put(failures, step, step_failures)
      end
    end)
  end

  defp failure_counter?(:errors), do: true
  defp failure_counter?("errors"), do: true

  defp failure_counter?(key) when is_atom(key) or is_binary(key) do
    key
    |> to_string()
    |> String.ends_with?("_failures")
  end

  defp failure_counter?(_key), do: false

  defp failure_value?(:execution_blocked, true), do: true
  defp failure_value?("execution_blocked", true), do: true

  defp failure_value?(key, value), do: failure_counter?(key) and is_integer(value) and value > 0

  defp resolve_steps(steps, mode) when is_list(steps) do
    steps = Enum.map(steps, &to_string/1)
    runnable = default_steps()
    unknown = steps -- @step_order

    cond do
      "all" in steps and Enum.any?(steps, &(&1 != "all")) ->
        {:error, {:mixed_all_steps, steps}}

      steps == [] or "all" in steps ->
        {:ok, runnable}

      unknown != [] ->
        {:error, {:unknown_steps, unknown}}

      # Explicitly requesting the disabled armis-dups step is refused unless
      # config opted it back in, so it cannot re-collapse split devices even
      # via a targeted `steps:` invocation.
      @armis_dups_step in steps and not armis_dups_enabled?() ->
        {:error, {:disabled_steps, [@armis_dups_step]}}

      mode == :execute and @armis_unmerge_step in steps and
          not armis_unmerge_execute_enabled?() ->
        {:error, {:execute_disabled, [@armis_unmerge_step]}}

      mode == :execute and @proxmox_unfuse_step in steps and
          not split_execute_enabled?(@proxmox_unfuse_step) ->
        {:error, {:execute_disabled, [@proxmox_unfuse_step]}}

      Enum.all?(steps, &(&1 in @step_order)) ->
        {:ok, Enum.filter(@step_order, &(&1 in steps))}

      true ->
        {:error, {:unknown_steps, unknown}}
    end
  end

  defp maybe_open_manifest(:dry_run, _opts, _steps), do: {nil, nil}

  defp maybe_open_manifest(:execute, opts, steps) do
    path = Keyword.get(opts, :manifest_path) || default_manifest_path()
    manifest = Manifest.open(path, %{mode: "execute", steps: steps})
    {manifest, path}
  end

  defp default_manifest_path do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

    Path.join(System.tmp_dir!(), "dire_remediation_#{timestamp}_#{Ecto.UUID.generate()}.ndjson")
  end

  # Do not trust caller-supplied values for the destructive execution gate.
  # Only release runtime configuration may enable the exact option consumed by
  # each split-disposition step, giving both the orchestrator and the step
  # fail-closed checks.
  defp runtime_step_opts("armis-unmerge", opts) do
    Keyword.put(opts, :armis_unmerge_execute_enabled, armis_unmerge_execute_enabled?())
  end

  defp runtime_step_opts("proxmox-unfuse", opts) do
    Keyword.put(
      opts,
      :proxmox_unfuse_execute_enabled,
      split_execute_enabled?(@proxmox_unfuse_step)
    )
  end

  defp runtime_step_opts(_step, opts), do: opts

  defp run_step("blob-purge", mode, opts, manifest, actor),
    do: BlobPurge.run(mode, opts, manifest, actor)

  defp run_step("test-debris", mode, opts, manifest, actor),
    do: TestDebris.run(mode, opts, manifest, actor)

  defp run_step("stale-agent-devices", mode, opts, manifest, actor),
    do: StaleAgentDevices.run(mode, opts, manifest, actor)

  defp run_step("agent-links", mode, opts, manifest, actor),
    do: AgentLinks.run(mode, opts, manifest, actor)

  defp run_step("proxmox-dups", mode, opts, manifest, actor),
    do: ProxmoxDups.run(mode, opts, manifest, actor)

  defp run_step("proxmox-unfuse", mode, opts, manifest, actor),
    do: ProxmoxUnfuse.run(mode, opts, manifest, actor)

  defp run_step("netprobe-alias-debris", mode, opts, manifest, actor),
    do: NetprobeAliasDebris.run(mode, opts, manifest, actor)

  defp run_step("link-local-alias-archive", mode, opts, manifest, actor),
    do: LinkLocalAliasArchive.run(mode, opts, manifest, actor)

  defp run_step("armis-unmerge", mode, opts, manifest, actor),
    do: ArmisUnmerge.run(mode, opts, manifest, actor)

  defp run_step("armis-dups", mode, opts, manifest, actor),
    do: ArmisDups.run(mode, opts, manifest, actor)
end
