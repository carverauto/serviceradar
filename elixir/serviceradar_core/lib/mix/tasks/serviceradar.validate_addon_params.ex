defmodule Mix.Tasks.Serviceradar.ValidateAddonParams do
  @shortdoc "Backfill-validate addon assignment params against package schemas (dry-run by default)"

  @moduledoc """
  Backfill validation for fj#4383 (OpenSpec `refactor-addon-lifecycle-operability`
  task 4.1).

  `AddonAssignment` params are validated against the add-on package's
  `config_schema` on every write path today, but rows persisted BEFORE those
  guards existed (or written by raw-SQL data migrations) were never checked.
  The delivery path now refuses to ship params that stay schema-invalid after
  coercion, so a legacy-invalid row silently withholds that add-on's config
  from its agent until fixed. This task finds those rows.

  For every `platform.addon_assignments` row it:

    1. runs the delivery-path coercion (`ConfigSchema.coerce_params/2`) against
       the package's `config_schema`, then validates the coerced params
       (`ConfigSchema.validate_params/2`) — exactly what delivery does;
    2. classifies the row:
       * `ok` — params already valid as stored;
       * `coercible` — invalid or drifted as stored, but the coerced form is
         valid (e.g. scalar string where the schema declares an array). With
         `--execute` the coerced params are written back;
       * `invalid` — still schema-invalid after coercion. Delivery refuses
         these; they are reported with field errors and MUST be fixed by an
         operator (there is no per-assignment validation-status field to flag
         them on yet — tracked for fj#4386b);
       * `unvalidatable` — the package declares no `config_schema` but the row
         carries params; nothing can be type-checked (empty-schema policy, see
         `ServiceRadar.Plugins.Validations.AddonAssignmentParams`).

  Idempotent: re-running after `--execute` reports previously-coercible rows
  as `ok` and writes nothing.

  ## Usage

      # Dry run (default): classify and report every row, write nothing
      mix serviceradar.validate_addon_params

      # Rewrite coercible rows with their coerced params; report the rest
      mix serviceradar.validate_addon_params --execute

  ## Options

    * `--execute` — apply coercible rewrites (default: dry run)
  """

  use Mix.Task

  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Repo

  @select_sql """
  SELECT a.id::text, a.agent_uid, p.addon_id, a.params, p.config_schema
  FROM platform.addon_assignments a
  JOIN platform.addon_packages p ON p.id = a.addon_package_id
  ORDER BY a.inserted_at
  """

  # Guarded on the stored params still matching what we classified, so a
  # concurrent operator edit between SELECT and UPDATE is never clobbered.
  @update_sql """
  UPDATE platform.addon_assignments
  SET params = $2::jsonb,
      updated_at = now()
  WHERE id::text = $1
    AND params = $3::jsonb
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [execute: :boolean])
    execute? = Keyword.get(opts, :execute, false)

    Mix.Task.run("app.start")

    %{rows: rows} = Repo.query!(@select_sql, [])

    counts =
      rows
      |> Enum.map(&classify_row/1)
      |> Enum.reduce(%{ok: 0, coercible: 0, invalid: 0, unvalidatable: 0}, fn row, acc ->
        report_row(row, execute?)
        Map.update!(acc, row.status, &(&1 + 1))
      end)

    Mix.shell().info(
      "#{length(rows)} assignment(s): #{counts.ok} ok, " <>
        "#{counts.coercible} coercible#{if execute?, do: " (rewritten)", else: ""}, " <>
        "#{counts.invalid} invalid (delivery refused until fixed), " <>
        "#{counts.unvalidatable} unvalidatable (package has no config_schema)"
    )

    if !execute? and counts.coercible > 0 do
      Mix.shell().info("Dry run: nothing was written. Re-run with --execute to apply.")
    end
  end

  defp classify_row([id, agent_uid, addon_id, params, schema]) do
    params = params || %{}
    schema = schema || %{}
    coerced = ConfigSchema.coerce_params(schema, params)

    status =
      cond do
        map_size(schema) == 0 and map_size(params) > 0 -> :unvalidatable
        valid?(schema, params) and coerced == params -> :ok
        valid?(schema, coerced) -> :coercible
        true -> :invalid
      end

    %{
      id: id,
      agent_uid: agent_uid,
      addon_id: addon_id,
      params: params,
      coerced: coerced,
      errors: errors_for(schema, coerced),
      status: status
    }
  end

  defp valid?(schema, params), do: ConfigSchema.validate_params(schema, params) == :ok

  defp errors_for(schema, coerced) do
    case ConfigSchema.validate_params(schema, coerced) do
      :ok -> []
      {:error, errors} -> errors
    end
  end

  defp report_row(%{status: :ok}, _execute?), do: :ok

  defp report_row(%{status: :unvalidatable} = row, _execute?) do
    Mix.shell().info(
      "unvalidatable #{row.id} (agent #{row.agent_uid}, addon #{row.addon_id}): " <>
        "params present but the package declares no config_schema; cannot type-check"
    )
  end

  defp report_row(%{status: :invalid} = row, _execute?) do
    Mix.shell().error(
      "INVALID #{row.id} (agent #{row.agent_uid}, addon #{row.addon_id}): " <>
        "params fail schema validation even after coercion — delivery is refused " <>
        "for this add-on until fixed: #{Enum.join(row.errors, "; ")}"
    )
  end

  defp report_row(%{status: :coercible} = row, false = _execute?) do
    Mix.shell().info(
      "would coerce #{row.id} (agent #{row.agent_uid}, addon #{row.addon_id}): " <>
        "#{inspect(row.params)} -> #{inspect(row.coerced)}"
    )
  end

  defp report_row(%{status: :coercible} = row, true = _execute?) do
    case Repo.query!(@update_sql, [row.id, row.coerced, row.params]) do
      %{num_rows: 1} ->
        Mix.shell().info(
          "coerced #{row.id} (agent #{row.agent_uid}, addon #{row.addon_id}): " <>
            "#{inspect(row.params)} -> #{inspect(row.coerced)}"
        )

      %{num_rows: 0} ->
        Mix.shell().info(
          "skipped #{row.id} (agent #{row.agent_uid}, addon #{row.addon_id}): " <>
            "row changed concurrently; re-run to re-classify"
        )
    end
  end
end
