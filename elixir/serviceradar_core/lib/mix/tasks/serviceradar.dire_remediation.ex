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
      `blob-purge`, `test-debris`, `agent-links`, `proxmox-dups`, `all`
      (default `all`)
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
    * `--agent <uid>` — restrict agent-links to specific agents (repeatable)
    * `--agent-status <status>` — agent-links scope (repeatable; default connected)
    * `--ip-literal <value>` — corrupted device ip literal to NULL (default "agent")
    * `--proxmox-source <name>` — discovery source for proxmox-dups (default proxmox)
    * `--skip-hostname <hostname>` — hostname denylist for proxmox-dups
      (repeatable; defaults: localhost, unknown)

  ## Examples

      # Dry-run everything (default)
      mix serviceradar.dire_remediation

      # Dry-run just the blob purge
      mix serviceradar.dire_remediation --step blob-purge

      # Execute the test-debris cleanup with a manifest path
      mix serviceradar.dire_remediation --step test-debris --execute \\
          --manifest /var/tmp/dire_remediation.ndjson
  """

  use Mix.Task

  alias ServiceRadar.Inventory.Remediation.DireRemediation

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
    agent: :keep,
    agent_status: :keep,
    ip_literal: :string,
    proxmox_source: :string,
    skip_hostname: :keep
  ]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise(
        "Invalid arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}. " <>
          "See `mix help serviceradar.dire_remediation`."
      )
    end

    Mix.Task.run("app.start")

    engine_opts = build_engine_opts(opts)
    mode = Keyword.fetch!(engine_opts, :mode)

    case DireRemediation.run(engine_opts) do
      {:ok, %{reports: reports, manifest_path: manifest_path}} ->
        print_reports(mode, reports, manifest_path)

      {:error, {:unknown_steps, unknown}} ->
        Mix.raise(
          "Unknown step(s): #{Enum.join(unknown, ", ")}. " <>
            "Valid steps: #{Enum.join(DireRemediation.steps(), ", ")}, all"
        )

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
    |> put_if_nonempty(:agent_uids, Keyword.get_values(opts, :agent))
    |> put_if_nonempty(
      :agent_statuses,
      opts |> Keyword.get_values(:agent_status) |> Enum.map(&parse_status/1)
    )
    |> put_if(:ip_literal, opts[:ip_literal])
    |> put_if(:proxmox_source, opts[:proxmox_source])
    |> put_if_nonempty(:hostname_denylist, Keyword.get_values(opts, :skip_hostname))
  end

  defp values_or(opts, key, default) do
    case Keyword.get_values(opts, key) do
      [] -> default
      values -> values
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

  defp print_reports(mode, reports, manifest_path) do
    shell = Mix.shell()

    if mode == :dry_run do
      shell.info("DRY RUN — no changes made. Re-run with --execute to apply.")
    else
      shell.info("EXECUTED. Rollback manifest: #{manifest_path}")
    end

    Enum.each(DireRemediation.steps(), fn step ->
      case Map.fetch(reports, step) do
        {:ok, report} ->
          shell.info("")
          shell.info("== #{step} ==")
          print_report(shell, report)

        :error ->
          :ok
      end
    end)
  end

  defp print_report(shell, report) do
    {details, counts} =
      Map.split(report, [:plans, :merge_plan, :sample_extractions])

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
end
