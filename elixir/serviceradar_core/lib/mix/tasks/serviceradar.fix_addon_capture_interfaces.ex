defmodule Mix.Tasks.Serviceradar.FixAddonCaptureInterfaces do
  @shortdoc "Rewrite scalar-string capture_interfaces addon params as lists (dry-run by default)"

  @moduledoc """
  Data remediation for fj#4381 (OpenSpec `refactor-addon-lifecycle-operability`
  task 1.1).

  A corrupt `AddonAssignment.params` row that stored `capture_interfaces` as a
  scalar STRING (where the package config schema declares an array of strings)
  was delivered verbatim to agents. The agent-side netprobe decoder
  (`[]string`) failed permanently on every config cycle, the agent stopped
  acknowledging config versions, and flow attribution halted fleet-wide.

  Delivery-path schema coercion and a tolerant agent decoder now make that
  shape survivable; this task fixes the data at rest. It finds
  `platform.addon_assignments` rows whose `params` carry a scalar-string
  `capture_interfaces` and rewrites the value as a string list using the same
  splitting rules as `ServiceRadar.Plugins.ConfigSchema` coercion (split on
  commas/newlines, trim whitespace, drop blanks).

  Idempotent: once every row stores a list — including when the affected demo
  row was already remediated by hand (see
  `fix-staging-observability-addon-regressions` PR6.3) — the task matches
  nothing and is a no-op.

  ## Usage

      # Dry run (default): print what would change, write nothing
      mix serviceradar.fix_addon_capture_interfaces

      # Apply the rewrite
      mix serviceradar.fix_addon_capture_interfaces --execute

  ## Options

    * `--execute` — apply changes (default: dry run)
  """

  use Mix.Task

  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Repo

  @coercion_schema %{
    "type" => "object",
    "properties" => %{
      "capture_interfaces" => %{"type" => "array", "items" => %{"type" => "string"}}
    }
  }

  @select_sql """
  SELECT id::text, agent_uid, params->>'capture_interfaces'
  FROM platform.addon_assignments
  WHERE jsonb_typeof(params->'capture_interfaces') = 'string'
  ORDER BY inserted_at
  """

  # The re-check in the WHERE clause keeps concurrent/repeated executions
  # idempotent: a row already rewritten (here or by hand) no longer matches.
  @update_sql """
  UPDATE platform.addon_assignments
  SET params = jsonb_set(params, '{capture_interfaces}', $2),
      updated_at = now()
  WHERE id::text = $1
    AND jsonb_typeof(params->'capture_interfaces') = 'string'
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [execute: :boolean])
    execute? = Keyword.get(opts, :execute, false)

    Mix.Task.run("app.start")

    %{rows: rows} = Repo.query!(@select_sql, [])

    if rows == [] do
      Mix.shell().info(
        "No addon_assignments rows store capture_interfaces as a scalar string; nothing to do."
      )
    else
      Enum.each(rows, &remediate_row(&1, execute?))
      Mix.shell().info("#{length(rows)} row(s) #{if execute?, do: "fixed", else: "affected"}.")

      if !execute? do
        Mix.shell().info("Dry run: nothing was written. Re-run with --execute to apply.")
      end
    end
  end

  defp remediate_row([id, agent_uid, raw], execute?) do
    coerced = coerce_capture_interfaces(raw)

    if execute? do
      case Repo.query!(@update_sql, [id, coerced]) do
        %{num_rows: 1} ->
          Mix.shell().info(
            "fixed #{id} (agent #{agent_uid}): #{inspect(raw)} -> #{inspect(coerced)}"
          )

        %{num_rows: 0} ->
          Mix.shell().info("skipped #{id} (agent #{agent_uid}): already fixed")
      end
    else
      Mix.shell().info(
        "would fix #{id} (agent #{agent_uid}): #{inspect(raw)} -> #{inspect(coerced)}"
      )
    end
  end

  # Reuse the delivery-path coercion so the rewrite matches exactly what the
  # generator would ship (and what author-time normalization would have stored).
  defp coerce_capture_interfaces(raw) do
    @coercion_schema
    |> ConfigSchema.coerce_params(%{"capture_interfaces" => raw})
    |> Map.fetch!("capture_interfaces")
  end
end
