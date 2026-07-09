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
    3. `agent-links`  — rebuild agent->device links from ocsf_agents ground
       truth, fix stranded identifiers/poisoned aliases/ip literal (4.3)
    4. `proxmox-dups` — collapse intra-Proxmox duplicate hostname groups (4.4)
    5. `armis-dups`   — collapse Armis rows onto their armis_device_id owner
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
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Remediation.AgentLinks
  alias ServiceRadar.Inventory.Remediation.ArmisDups
  alias ServiceRadar.Inventory.Remediation.ArmisUnmerge
  alias ServiceRadar.Inventory.Remediation.BlobPurge
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Inventory.Remediation.ProxmoxDups
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

  @step_order [
    "blob-purge",
    "test-debris",
    "stale-agent-devices",
    "agent-links",
    "proxmox-dups",
    @armis_unmerge_step,
    @armis_dups_step
  ]

  @doc """
  Ordered list of runnable step names.

  `armis-dups` is omitted unless explicitly re-enabled via config (it is the
  armis-overmerge re-collapse vector — see the moduledoc).
  """
  @spec steps() :: [String.t()]
  def steps, do: default_steps()

  # Default run order with armis-dups gated off unless config opts back in.
  # armis-unmerge is always excluded from the default order — it is
  # explicit-request-only (dormant) until live scoping confirms the population.
  defp default_steps do
    base = @step_order -- [@armis_unmerge_step]

    if armis_dups_enabled?() do
      base
    else
      base -- [@armis_dups_step]
    end
  end

  defp armis_dups_enabled? do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enable_armis_dups, false)
  end

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
      `:proxmox_source`, `:hostname_denylist`, `:armis_plan_sample_limit`

  Returns `{:ok, %{mode: mode, manifest_path: path | nil, reports: %{step => report}}}`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :dry_run)
    actor = Keyword.get(opts, :actor) || SystemActor.system(:dire_remediation)

    with {:ok, steps} <- resolve_steps(Keyword.get(opts, :steps, ["all"])) do
      {manifest, manifest_path} = maybe_open_manifest(mode, opts, steps)

      try do
        reports =
          Enum.reduce(steps, %{}, fn step, reports ->
            Logger.info("DireRemediation: running step #{step} (#{mode})")
            Map.put(reports, step, run_step(step, mode, opts, manifest, actor))
          end)

        {:ok, %{mode: mode, manifest_path: manifest_path, reports: reports}}
      after
        Manifest.close(manifest)
      end
    end
  end

  defp resolve_steps(steps) when is_list(steps) do
    steps = Enum.map(steps, &to_string/1)
    runnable = default_steps()

    cond do
      steps == [] or "all" in steps ->
        {:ok, runnable}

      # Explicitly requesting the disabled armis-dups step is refused unless
      # config opted it back in, so it cannot re-collapse split devices even
      # via a targeted `steps:` invocation.
      @armis_dups_step in steps and not armis_dups_enabled?() ->
        {:error, {:disabled_steps, [@armis_dups_step]}}

      Enum.all?(steps, &(&1 in @step_order)) ->
        {:ok, Enum.filter(@step_order, &(&1 in steps))}

      true ->
        {:error, {:unknown_steps, steps -- @step_order}}
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

    Path.join(System.tmp_dir!(), "dire_remediation_#{timestamp}.ndjson")
  end

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

  defp run_step("armis-unmerge", mode, opts, manifest, actor),
    do: ArmisUnmerge.run(mode, opts, manifest, actor)

  defp run_step("armis-dups", mode, opts, manifest, actor),
    do: ArmisDups.run(mode, opts, manifest, actor)
end
