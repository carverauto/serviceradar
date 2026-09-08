defmodule Mix.Tasks.Serviceradar.DireRemediation do
  @shortdoc "Operator-invoked DIRE production data remediation (dry-run by default)"

  @moduledoc """
  Production data remediation for the device identity reconciliation engine
  (OpenSpec `refactor-device-identity-reconciliation`, tasks 4.1-4.4).

  This is intentionally an operator-invoked mix task, NOT an auto-run Ecto
  migration: it must only run after the phase-1 merge guards are verified
  live, and it is safe to ship dormant. It is idempotent — re-running a step
  is a no-op once the data is clean.

  ## Usage

      mix serviceradar.dire_remediation [options]

  Dry-run (default) prints what WOULD change, with counts, and writes
  nothing. `--execute` applies the changes and writes an NDJSON rollback
  manifest of every row touched (ids only).

  ## Options

    * `--execute` — apply changes (default: dry run)
    * `--step <name>` — run a single step (repeatable). One of:
      `blob-purge`, `test-debris`, `stale-agent-devices`, `agent-links`,
      `proxmox-dups`, `proxmox-unfuse`, `armis-unmerge`, `armis-dups`,
      `all` (default `all`).
      `all` cannot be combined with another step.
      `armis-unmerge` is explicit-only: dry-run is available for live scoping,
      while execute is disabled until the runtime signoff gate is enabled.
      `proxmox-unfuse` is explicit-only: dry-run reports fused devices with
      per-cluster MAC attribution for review, while execute is disabled until
      its own runtime signoff gate is enabled.
      `armis-dups` is disabled unless separately enabled by runtime config.
    * `--manifest <path>` — rollback manifest path (execute mode)
    * `--batch-size <n>` — blob purge delete/extract batch size (default 50000)
    * `--debris-date <yyyy-mm-dd>` — test debris creation date (default 2026-04-25)
    * `--debris-pattern <prefix>` — debris agent uid prefix requiring NULL
      device_uid (repeatable; defaults: test-agent-, local-config-agent-,
      recover-agent-, new-heartbeat-agent-)
    * `--debris-sim-pattern <prefix>` — debris agent uid prefix allowed to
      carry a simulated device link (repeatable; defaults:
      agent-active-ip-conflict-, agent-active-ip-owner-)
    * `--debris-device-agent-prefix <prefix>` — debris device agent_id prefix
      (default agent-reip-)
    * `--debris-hostname <hostname>` — debris device hostname (repeatable;
      defaults: k8s-pod-a, k8s-pod-b)
    * `--stale-agent <uid>` — exact unavailable historical agent uid to reap
      (repeatable; defaults: agent-dusk, agent-agent-dusk)
    * `--stale-agent-prefix <prefix>` — unavailable historical agent uid prefix
      to reap (repeatable; defaults: agent-dusk-, agent-agent-dusk-, agent-dusk01-)
    * `--stale-agent-before <iso8601>` — stale agent last_seen cutoff
      (default 2026-05-01T00:00:00Z)
    * `--agent <uid>` — restrict agent-links to specific agents (repeatable)
    * `--agent-status <status>` — agent-links scope (repeatable; default connected)
    * `--ip-literal <value>` — corrupted device ip literal to NULL (default "agent")
    * `--proxmox-source <name>` — discovery source for proxmox-dups (default proxmox)
    * `--skip-hostname <hostname>` — hostname denylist for proxmox-dups
      (repeatable; defaults: localhost, unknown)
    * `--armis-plan-sample-limit <n>` — number of planned Armis merges printed
      by the legacy `armis-dups` step (default 50)
    * `--armis-unmerge-candidate-limit <n>` — maximum Armis unmerge candidates
      inspected in one run (1..5000; default: dry-run 5000, execute 25)
    * `--armis-unmerge-plan-sample-limit <n>` — maximum Armis unmerge split
      plans printed in the report (0..5000; default 50)
    * `--armis-unmerge-live-device <uid>` — permit one live device UID during
      execute (repeatable; must be paired with at least one live source ID)
    * `--armis-unmerge-live-source <id>` — permit one live sync source ID during
      execute (repeatable; must be paired with at least one live device UID).
      Known faker-backed sources remain ineligible inside the remediation step.
    * `--proxmox-unfuse-candidate-limit <n>` — maximum unfuse candidates
      inspected in one run (1..5000; default: dry-run 5000, execute 25)
    * `--proxmox-unfuse-plan-sample-limit <n>` — maximum unfuse split plans
      printed in the report (0..5000; default 50)
    * `--proxmox-unfuse-live-device <uid>` — permit one live device UID during
      execute (repeatable; must be paired with at least one live source ID)
    * `--proxmox-unfuse-live-source <id>` — permit one live sync source ID during
      execute (repeatable; must be paired with at least one live device UID).
      Every v2/MAC identifier row that would move must come from a permitted
      source; a row with missing or foreign provenance excludes its candidate.
      Known faker-backed sources remain ineligible inside the remediation step.

  Every `--armis-unmerge-*` option requires an explicit
  `--step armis-unmerge` selection. Every `--proxmox-unfuse-*` option
  requires an explicit `--step proxmox-unfuse` selection.

  `armis-unmerge --execute` is rejected unless live scoping has been reviewed
  and the release runtime configuration deliberately sets:

      config :serviceradar_core, ServiceRadar.Inventory.Remediation.DireRemediation,
        enable_armis_unmerge_execute: true

  The gate does not add the step to `all`; execute still requires an explicit
  `--step armis-unmerge`.

  `proxmox-unfuse --execute` is rejected unless the split plan (cluster
  grouping plus per-cluster MAC attribution) has been reviewed against the
  live clusters and the release runtime configuration deliberately sets:

      config :serviceradar_core, ServiceRadar.Inventory.Remediation.DireRemediation,
        enable_proxmox_unfuse_execute: true

  The gate does not add the step to `all`; execute still requires an explicit
  `--step proxmox-unfuse`.

  ## Examples

      # Dry-run everything (default)
      mix serviceradar.dire_remediation

      # Dry-run just the blob purge
      mix serviceradar.dire_remediation --step blob-purge

      # Bounded Armis live-scoping dry-run; safe while execute is gated off
      mix serviceradar.dire_remediation --step armis-unmerge \\
          --armis-unmerge-candidate-limit 500 \\
          --armis-unmerge-plan-sample-limit 25

      # After signoff/config enablement, execute only an explicitly reviewed
      # live device/source intersection (ghost disposition remains the default)
      mix serviceradar.dire_remediation --step armis-unmerge --execute \\
          --armis-unmerge-live-device sr:reviewed-device \\
          --armis-unmerge-live-source reviewed-sync-source

      # Proxmox cross-cluster split planning (GitHub #4051); safe while
      # execute is gated off. Review the cluster/MAC attribution plan first.
      mix serviceradar.dire_remediation --step proxmox-unfuse \\
          --proxmox-unfuse-candidate-limit 500 \\
          --proxmox-unfuse-plan-sample-limit 25

      # After plan review and config enablement, execute only an explicitly
      # reviewed live device/source intersection
      mix serviceradar.dire_remediation --step proxmox-unfuse --execute \\
          --proxmox-unfuse-live-device sr:reviewed-device \\
          --proxmox-unfuse-live-source reviewed-sync-source

      # Execute the test-debris cleanup with a manifest path
      mix serviceradar.dire_remediation --step test-debris --execute \\
          --manifest /var/tmp/dire_remediation.ndjson
  """

  use Mix.Task

  alias ServiceRadar.Inventory.Remediation.DireRemediation

  @max_armis_unmerge_candidate_limit 5_000
  @max_armis_unmerge_plan_sample_limit 5_000
  @max_proxmox_unfuse_candidate_limit 5_000
  @max_proxmox_unfuse_plan_sample_limit 5_000

  @armis_unmerge_switches [
    :armis_unmerge_candidate_limit,
    :armis_unmerge_plan_sample_limit,
    :armis_unmerge_live_device,
    :armis_unmerge_live_source
  ]

  @proxmox_unfuse_switches [
    :proxmox_unfuse_candidate_limit,
    :proxmox_unfuse_plan_sample_limit,
    :proxmox_unfuse_live_device,
    :proxmox_unfuse_live_source
  ]

  @report_step_order [
    "blob-purge",
    "test-debris",
    "stale-agent-devices",
    "link-local-alias-archive",
    "netprobe-alias-debris",
    "agent-links",
    "proxmox-dups",
    "proxmox-unfuse",
    "armis-unmerge",
    "armis-dups"
  ]

  @switches [
    execute: :boolean,
    step: :keep,
    manifest: :string,
    batch_size: :integer,
    debris_date: :string,
    debris_pattern: :keep,
    debris_sim_pattern: :keep,
    debris_device_agent_prefix: :string,
    debris_hostname: :keep,
    stale_agent: :keep,
    stale_agent_prefix: :keep,
    stale_agent_before: :string,
    agent: :keep,
    agent_status: :keep,
    ip_literal: :string,
    proxmox_source: :string,
    skip_hostname: :keep,
    armis_plan_sample_limit: :integer,
    armis_unmerge_candidate_limit: :integer,
    armis_unmerge_plan_sample_limit: :integer,
    armis_unmerge_live_device: :keep,
    armis_unmerge_live_source: :keep,
    proxmox_unfuse_candidate_limit: :integer,
    proxmox_unfuse_plan_sample_limit: :integer,
    proxmox_unfuse_live_device: :keep,
    proxmox_unfuse_live_source: :keep
  ]

  @impl true
  def run(args) do
    run_with(args, &DireRemediation.run/1, fn -> Mix.Task.run("app.start") end)
  end

  @doc false
  def run_with(args, remediation_runner, app_starter)
      when is_function(remediation_runner, 1) and is_function(app_starter, 0) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise(
        "Invalid arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}. " <>
          "See `mix help serviceradar.dire_remediation`."
      )
    end

    validate_step_selection!(opts)
    validate_armis_unmerge_selection!(opts)
    validate_proxmox_unfuse_selection!(opts)

    engine_opts = build_engine_opts(opts)
    mode = Keyword.fetch!(engine_opts, :mode)
    app_starter.()

    case remediation_runner.(engine_opts) do
      {:ok, %{reports: reports, manifest_path: manifest_path}} ->
        print_reports(mode, reports, manifest_path)

      {:error,
       {:step_failures, %{reports: reports, manifest_path: manifest_path, failures: failures}}} ->
        print_reports(mode, reports, manifest_path)

        Mix.raise(
          "Remediation completed with failures: #{format_failures(failures)}. " <>
            "Review the report and rollback manifest before retrying."
        )

      {:error, {:unknown_steps, unknown}} ->
        Mix.raise(
          "Unknown step(s): #{Enum.join(unknown, ", ")}. " <>
            "Valid dry-run steps: #{Enum.join(DireRemediation.available_steps(:dry_run), ", ")}, all"
        )

      {:error, {:mixed_all_steps, _steps}} ->
        Mix.raise("--step all cannot be combined with another --step value")

      {:error, {:execute_disabled, ["armis-unmerge"]}} ->
        Mix.raise(
          "armis-unmerge execute mode is disabled pending live-scoping signoff. " <>
            "Run without --execute to review the bounded plan; only then enable " <>
            ":enable_armis_unmerge_execute in the DireRemediation runtime config."
        )

      {:error, {:execute_disabled, ["proxmox-unfuse"]}} ->
        Mix.raise(
          "proxmox-unfuse execute mode is disabled pending split-plan review. " <>
            "Run without --execute to review the cluster/MAC attribution plan; only then enable " <>
            ":enable_proxmox_unfuse_execute in the DireRemediation runtime config."
        )

      {:error, {:disabled_steps, disabled}} ->
        Mix.raise("Disabled step(s): #{Enum.join(disabled, ", ")}")

      {:error, error} ->
        Mix.raise("Remediation failed: #{inspect(error)}")
    end
  end

  defp build_engine_opts(opts) do
    [
      mode: if(opts[:execute], do: :execute, else: :dry_run),
      steps: values_or(opts, :step, ["all"])
    ]
    |> put_if(:manifest_path, opts[:manifest])
    |> put_if(:batch_size, opts[:batch_size])
    |> put_if(:debris_date, parse_date(opts[:debris_date]))
    |> put_if_nonempty(:debris_null_patterns, Keyword.get_values(opts, :debris_pattern))
    |> put_if_nonempty(:debris_sim_patterns, Keyword.get_values(opts, :debris_sim_pattern))
    |> put_if(:debris_device_agent_prefix, opts[:debris_device_agent_prefix])
    |> put_if_nonempty(:debris_hostnames, Keyword.get_values(opts, :debris_hostname))
    |> put_if_nonempty(:stale_agent_uids, Keyword.get_values(opts, :stale_agent))
    |> put_if_nonempty(:stale_agent_prefixes, Keyword.get_values(opts, :stale_agent_prefix))
    |> put_if(:stale_agent_before, parse_datetime(opts[:stale_agent_before]))
    |> put_if_nonempty(:agent_uids, Keyword.get_values(opts, :agent))
    |> put_if_nonempty(
      :agent_statuses,
      opts |> Keyword.get_values(:agent_status) |> Enum.map(&parse_status/1)
    )
    |> put_if(:ip_literal, opts[:ip_literal])
    |> put_if(:proxmox_source, opts[:proxmox_source])
    |> put_if_nonempty(:hostname_denylist, Keyword.get_values(opts, :skip_hostname))
    |> put_if(:armis_plan_sample_limit, opts[:armis_plan_sample_limit])
    |> put_if(
      :armis_unmerge_candidate_limit,
      validate_range(
        opts[:armis_unmerge_candidate_limit],
        "--armis-unmerge-candidate-limit",
        1,
        @max_armis_unmerge_candidate_limit
      )
    )
    |> put_if(
      :armis_unmerge_plan_sample_limit,
      validate_range(
        opts[:armis_unmerge_plan_sample_limit],
        "--armis-unmerge-plan-sample-limit",
        0,
        @max_armis_unmerge_plan_sample_limit
      )
    )
    |> put_armis_unmerge_live_scope(opts)
    |> put_if(
      :proxmox_unfuse_candidate_limit,
      validate_range(
        opts[:proxmox_unfuse_candidate_limit],
        "--proxmox-unfuse-candidate-limit",
        1,
        @max_proxmox_unfuse_candidate_limit
      )
    )
    |> put_if(
      :proxmox_unfuse_plan_sample_limit,
      validate_range(
        opts[:proxmox_unfuse_plan_sample_limit],
        "--proxmox-unfuse-plan-sample-limit",
        0,
        @max_proxmox_unfuse_plan_sample_limit
      )
    )
    |> put_proxmox_unfuse_live_scope(opts)
  end

  defp values_or(opts, key, default) do
    case Keyword.get_values(opts, key) do
      [] -> default
      values -> values
    end
  end

  defp validate_step_selection!(opts) do
    steps = Keyword.get_values(opts, :step)

    if "all" in steps and Enum.any?(steps, &(&1 != "all")) do
      Mix.raise("--step all cannot be combined with another --step value")
    end
  end

  defp validate_armis_unmerge_selection!(opts) do
    armis_opts? = Enum.any?(@armis_unmerge_switches, &Keyword.has_key?(opts, &1))
    armis_step? = "armis-unmerge" in Keyword.get_values(opts, :step)

    if armis_opts? and not armis_step? do
      Mix.raise("Armis unmerge options require an explicit --step armis-unmerge selection")
    end
  end

  defp validate_proxmox_unfuse_selection!(opts) do
    unfuse_opts? = Enum.any?(@proxmox_unfuse_switches, &Keyword.has_key?(opts, &1))
    unfuse_step? = "proxmox-unfuse" in Keyword.get_values(opts, :step)

    if unfuse_opts? and not unfuse_step? do
      Mix.raise("Proxmox unfuse options require an explicit --step proxmox-unfuse selection")
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_if_nonempty(opts, _key, []), do: opts
  defp put_if_nonempty(opts, key, values), do: Keyword.put(opts, key, values)

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> Mix.raise("--debris-date must be an ISO8601 date, got: #{value}")
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> Mix.raise("--stale-agent-before must be ISO8601, got: #{value}")
    end
  end

  defp parse_status(value) do
    case value do
      "connected" -> :connected
      "connecting" -> :connecting
      "degraded" -> :degraded
      "disconnected" -> :disconnected
      "unavailable" -> :unavailable
      other -> Mix.raise("Unknown --agent-status: #{other}")
    end
  end

  defp validate_range(nil, _flag, _minimum, _maximum), do: nil

  defp validate_range(value, _flag, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: value

  defp validate_range(value, flag, minimum, maximum) do
    Mix.raise("#{flag} must be between #{minimum} and #{maximum}, got: #{inspect(value)}")
  end

  defp put_armis_unmerge_live_scope(engine_opts, opts) do
    device_uids = validate_nonempty_values(opts, :armis_unmerge_live_device)
    source_ids = validate_nonempty_values(opts, :armis_unmerge_live_source)

    case {device_uids, source_ids} do
      {[], []} ->
        engine_opts

      {[], _sources} ->
        Mix.raise(
          "--armis-unmerge-live-source requires at least one " <>
            "--armis-unmerge-live-device"
        )

      {_devices, []} ->
        Mix.raise(
          "--armis-unmerge-live-device requires at least one " <>
            "--armis-unmerge-live-source"
        )

      {devices, sources} ->
        engine_opts
        |> Keyword.put(:armis_unmerge_include_live, true)
        |> Keyword.put(:armis_unmerge_live_device_uids, devices)
        |> Keyword.put(:armis_unmerge_live_source_ids, sources)
    end
  end

  defp put_proxmox_unfuse_live_scope(engine_opts, opts) do
    device_uids = validate_nonempty_values(opts, :proxmox_unfuse_live_device)
    source_ids = validate_nonempty_values(opts, :proxmox_unfuse_live_source)

    case {device_uids, source_ids} do
      {[], []} ->
        engine_opts

      {[], _sources} ->
        Mix.raise(
          "--proxmox-unfuse-live-source requires at least one " <>
            "--proxmox-unfuse-live-device"
        )

      {_devices, []} ->
        Mix.raise(
          "--proxmox-unfuse-live-device requires at least one " <>
            "--proxmox-unfuse-live-source"
        )

      {devices, sources} ->
        engine_opts
        |> Keyword.put(:proxmox_unfuse_include_live, true)
        |> Keyword.put(:proxmox_unfuse_live_device_uids, devices)
        |> Keyword.put(:proxmox_unfuse_live_source_ids, sources)
    end
  end

  defp validate_nonempty_values(opts, key) do
    values = opts |> Keyword.get_values(key) |> Enum.map(&String.trim/1)

    if Enum.any?(values, &(&1 == "")) do
      Mix.raise("--#{key |> to_string() |> String.replace("_", "-")} cannot be empty")
    end

    Enum.uniq(values)
  end

  defp print_reports(mode, reports, manifest_path) do
    shell = Mix.shell()

    if mode == :dry_run do
      shell.info("DRY RUN — no changes made. Re-run with --execute to apply.")
    else
      shell.info("EXECUTED. Rollback manifest: #{manifest_path}")
    end

    reports
    |> Enum.sort_by(fn {step, _report} -> report_order(step) end)
    |> Enum.each(fn {step, report} ->
      shell.info("")
      shell.info("== #{step} ==")
      print_report(shell, report)
    end)
  end

  defp print_report(shell, report) do
    {details, counts} =
      Map.split(report, [
        :plans,
        :merge_plan,
        :sample_extractions,
        :split_plan,
        :execution_split_plan,
        :skipped_device_sample
      ])

    counts
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.each(fn {key, value} -> shell.info("  #{key}: #{format_value(value)}") end)

    Enum.each(details, fn {key, entries} ->
      shell.info("  #{key}:")

      Enum.each(entries, fn entry ->
        shell.info("    - #{format_value(entry)}")
      end)
    end)
  end

  defp format_value(value) when is_list(value) do
    Enum.map_join(value, ", ", &format_value/1)
  end

  defp format_value(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join(" ", fn {key, val} -> "#{key}=#{format_value(val)}" end)
  end

  defp format_value(value), do: to_string(value)

  defp report_order(step) do
    case Enum.find_index(@report_step_order, &(&1 == step)) do
      nil -> {1, step}
      index -> {0, index}
    end
  end

  defp format_failures(failures) do
    failures
    |> Enum.sort_by(fn {step, _counts} -> report_order(step) end)
    |> Enum.map_join("; ", fn {step, counts} ->
      formatted_counts =
        counts
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)

      "#{step}: #{formatted_counts}"
    end)
  end
end
