defmodule ServiceRadar.Credo.Check.Warning.DirectTelemetryWrite do
  @moduledoc """
  Detects a write to the `ocsf_events` or `logs` table, or an in-process call of
  an EventWriter processor, outside the EventWriter consumers.

  Events and logs reach storage only after a JetStream hop: a producer publishes
  (`ServiceRadar.Events.OcsfEventPublisher`,
  `ServiceRadar.Events.InternalLogPublisher`,
  `ServiceRadar.Events.SignalPublisher`) and EventWriter stores the message in
  whichever telemetry backend is active. A row inserted anywhere else never
  reaches the warehouse, is invisible to every stream subscriber, and is
  evaluated against stateful rules by nobody -- and calling a processor's
  `process_batch/1` in-process skips JetStream just the same, with no
  redelivery when the batch fails.

  ## The Solution

      OcsfEventPublisher.publish(attrs, family: :inventory)
      InternalLogPublisher.publish("sync", payload)
      SignalPublisher.publish("signals.analytics.vulnerability", payload)

  ## What Is Flagged

    * an Ecto insert (`insert`, `insert!`, `insert_all`, and the
      `insert_all_count` / `insert_all_returning` helpers) or an Ash create
      (`for_create`, `create`, `create!`, `bulk_create`, `bulk_create!`,
      `seed!`), remote or local, called on or piped from the table: the string
      `"ocsf_events"` or `"logs"`, a `{"logs", Schema}` source tuple, the
      `OcsfEvent` or `Log` resource, or a struct literal of either;
    * a `process_batch` call on a module under
      `ServiceRadar.EventWriter.Processors`;
    * such a processor module used as a value -- a default in
      `Keyword.get(opts, :processor, Processors.Logs)`, say. Outside EventWriter
      a processor is handed around only to be called. Calling any other
      function of a processor, such as `parse_message/1`, is not flagged.

  Aliases declared in the file are resolved, so `Processors.Logs` and an
  aliased `OcsfEvent` are caught.

  Not flagged: files under a `test/` directory, and the `:allowed_paths`
  param -- by default EventWriter itself (its pipeline, configuration and
  processors) and `ServiceRadar.Observability.LogPromotion`, whose only
  callers are the two JetStream consumers of logs (`Processors.Logs` and
  `LogPromotionConsumer`).
  A module or table reached through a variable is not resolved.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      allowed_paths: [
        "lib/serviceradar/event_writer/",
        "lib/serviceradar/observability/log_promotion.ex"
      ]
    ],
    explanations: [
      check: """
      Publish events, logs and analytics signals to JetStream; do not insert into
      `ocsf_events` or `logs`, or call an EventWriter processor, from anywhere but
      the EventWriter consumers. A direct write never reaches the telemetry
      warehouse or any stream subscriber.
      """,
      params: [
        allowed_paths: "Path fragments of files allowed to write these tables directly."
      ]
    ]

  @write_functions [
    :insert,
    :insert!,
    :insert_all,
    :insert_all_count,
    :insert_all_returning,
    :for_create,
    :create,
    :create!,
    :bulk_create,
    :bulk_create!,
    :seed!
  ]
  @tables ["ocsf_events", "logs"]
  @schemas [
    [:ServiceRadar, :Monitoring, :OcsfEvent],
    [:ServiceRadar, :Observability, :Log]
  ]
  @processors_namespace [:ServiceRadar, :EventWriter, :Processors]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params \\ []) do
    if exempt?(source_file.filename, Params.get(params, :allowed_paths, __MODULE__)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      aliases = Credo.Code.prewalk(source_file, &collect_alias/2, %{})

      source_file
      |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta, aliases))
      |> Enum.uniq_by(& &1.line_no)
    end
  end

  defp exempt?(filename, allowed_paths) do
    path = String.replace(filename, "\\", "/")

    String.starts_with?(path, "test/") or String.contains?(path, "/test/") or
      Enum.any?(allowed_paths, &String.contains?(path, &1))
  end

  # alias A.B.C / alias A.B.C, as: D / alias A.B.{C, D}
  defp collect_alias({:alias, _, [{:__aliases__, _, segments}]} = ast, aliases),
    do: {ast, Map.put(aliases, List.last(segments), segments)}

  defp collect_alias({:alias, _, [{:__aliases__, _, segments}, opts]} = ast, aliases)
       when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [name]} -> {ast, Map.put(aliases, name, segments)}
      _ -> {ast, Map.put(aliases, List.last(segments), segments)}
    end
  end

  defp collect_alias(
         {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = ast,
         aliases
       ) do
    aliases =
      Enum.reduce(children, aliases, fn
        {:__aliases__, _, segments}, acc -> Map.put(acc, List.last(segments), base ++ segments)
        _child, acc -> acc
      end)

    {ast, aliases}
  end

  defp collect_alias(ast, aliases), do: {ast, aliases}

  # The module named in an alias, require or import is not a use of it.
  defp traverse({directive, _, _}, issues, _issue_meta, _aliases)
       when directive in [:alias, :require, :import],
       do: {nil, issues}

  # A call on an EventWriter processor: `process_batch` is flagged. The receiver
  # is not walked, so a call such as `parse_message/1` is not read as the
  # processor used as a value.
  defp traverse(
         {{:., dot_meta, [{:__aliases__, _, _} = receiver, function]}, meta, args} = ast,
         issues,
         issue_meta,
         aliases
       ) do
    if processor?(resolve(receiver, aliases)) do
      issues =
        if function == :process_batch,
          do: [issue_for(issue_meta, meta, "process_batch", :processor) | issues],
          else: issues

      {{{:., dot_meta, [nil, function]}, meta, args}, issues}
    else
      write_call(ast, issues, issue_meta, aliases)
    end
  end

  # OcsfEvent |> Ash.Changeset.for_create(...), "logs" |> insert_all_count(rows)
  defp traverse({:|>, _, [source, call]} = ast, issues, issue_meta, aliases) do
    case write_function(call) do
      {function, meta} ->
        if telemetry_table?(source, aliases),
          do: {ast, [issue_for(issue_meta, meta, Atom.to_string(function), :table) | issues]},
          else: {ast, issues}

      nil ->
        {ast, issues}
    end
  end

  # An EventWriter processor module used as a value
  defp traverse({:__aliases__, meta, _} = ast, issues, issue_meta, aliases) do
    if processor?(resolve(ast, aliases)) do
      {ast, [issue_for(issue_meta, meta, Macro.to_string(ast), :processor_value) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, issue_meta, aliases),
    do: write_call(ast, issues, issue_meta, aliases)

  # Repo.insert_all("ocsf_events", ...), Ecto.Multi.insert_all(multi, :name, "logs", ...),
  # Ash.Changeset.for_create(OcsfEvent, ...), insert_all_count("logs", ...)
  defp write_call(ast, issues, issue_meta, aliases) do
    with {function, meta} <- write_function(ast),
         {_, _, args} = ast,
         true <- Enum.any?(args, &telemetry_table?(&1, aliases)) do
      {ast, [issue_for(issue_meta, meta, Atom.to_string(function), :table) | issues]}
    else
      _ -> {ast, issues}
    end
  end

  defp write_function({{:., _, [_receiver, function]}, meta, args})
       when function in @write_functions and is_list(args),
       do: {function, meta}

  defp write_function({function, meta, args}) when function in @write_functions and is_list(args),
    do: {function, meta}

  defp write_function(_ast), do: nil

  defp telemetry_table?(table, _aliases) when table in @tables, do: true
  defp telemetry_table?({table, _schema}, _aliases) when table in @tables, do: true

  defp telemetry_table?({:%, _, [schema, _fields]}, aliases),
    do: telemetry_table?(schema, aliases)

  defp telemetry_table?({:__aliases__, _, _} = schema, aliases),
    do: resolve(schema, aliases) in @schemas

  defp telemetry_table?(_arg, _aliases), do: false

  defp processor?([_, _, _, _ | _] = module), do: List.starts_with?(module, @processors_namespace)
  defp processor?(_module), do: false

  defp resolve({:__aliases__, _, [first | rest]}, aliases) when is_atom(first) do
    case Map.fetch(aliases, first) do
      {:ok, segments} -> segments ++ rest
      :error -> [first | rest]
    end
  end

  defp resolve(_receiver, _aliases), do: nil

  defp issue_for(issue_meta, meta, trigger, kind) do
    format_issue(issue_meta,
      message: message(kind),
      trigger: trigger,
      line_no: Keyword.get(meta, :line, 1)
    )
  end

  defp message(:table),
    do:
      "Publish events and logs to JetStream (OcsfEventPublisher, InternalLogPublisher); " <>
        "only EventWriter inserts into `ocsf_events` and `logs`"

  defp message(:processor),
    do:
      "Publish to JetStream instead of calling an EventWriter processor in-process; " <>
        "the batch would skip the warehouse, stream subscribers and redelivery"

  defp message(:processor_value),
    do:
      "Publish to JetStream instead of handing an EventWriter processor to code that " <>
        "calls it in-process; only EventWriter runs its processors"
end
