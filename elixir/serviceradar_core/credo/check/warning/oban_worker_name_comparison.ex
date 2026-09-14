defmodule ServiceRadar.Credo.Check.Warning.ObanWorkerNameComparison do
  @moduledoc """
  Detects an Oban worker name built with `to_string/1` of a module.

  `to_string(MyApp.Worker)` returns `"Elixir.MyApp.Worker"`, but Oban stores the
  worker without the `Elixir.` prefix, as `"MyApp.Worker"`. A query such as

      where: j.worker == ^to_string(__MODULE__)

  therefore matches no job, and nothing reports it: an "already scheduled" guard
  never fires and every call inserts another self-rescheduling chain, while a
  cancel or reap query silently does nothing.

  ## The Solution

  Compare against the name Oban itself stores:

      where: j.worker == ^Oban.Worker.to_string(__MODULE__)

  ## What Is Flagged

  A module name built with `to_string/1`, `Atom.to_string/1` or `Kernel.to_string/1`
  (called or piped into), or as a string that consists of a single interpolation, when
  it is either:

    * compared with a `.worker` field: on one side of `==`, `!=`, `===` or `!==`, as an
      element of a list literal on the right of `in`, or as the pinned value of a
      `worker:` keyword filter; or
    * built from `__MODULE__` anywhere in a file that does `use Oban.Worker`. This also
      catches the name being bound to a variable or module attribute first and
      compared later.

  Not flagged: a name built from another module and compared through a variable, and
  a raw SQL string that spells out the `Elixir.` prefix.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Build an Oban worker name with `Oban.Worker.to_string/1`, not `to_string/1`.
      `to_string/1` of a module keeps the `Elixir.` prefix that Oban strips from the
      stored worker name, so comparing it with a job's `worker` matches no jobs.
      """
    ]

  @comparison_operators [:==, :!=, :===, :!==, :in]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    oban_worker? = Credo.Code.prewalk(source_file, &oban_worker_use/2, false)

    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta, oban_worker?))
    |> Enum.uniq_by(& &1.line_no)
  end

  defp oban_worker_use({:use, _, [{:__aliases__, _, [:Oban, :Worker]} | _]} = ast, _found?),
    do: {ast, true}

  defp oban_worker_use(ast, found?), do: {ast, found?}

  # j.worker == ^to_string(__MODULE__), in either operand order, or j.worker in ^[...]
  defp traverse({operator, meta, [left, right]} = ast, issues, issue_meta, _oban_worker?)
       when operator in @comparison_operators do
    if stringified_worker_comparison?(left, right) or
         stringified_worker_comparison?(right, left) do
      {ast, issues ++ [issue_for(issue_meta, meta, "worker")]}
    else
      {ast, issues}
    end
  end

  # where(query, worker: ^to_string(SomeWorker))
  defp traverse({:worker, {:^, meta, [value]}} = ast, issues, issue_meta, _oban_worker?) do
    if module_string?(value) do
      {ast, issues ++ [issue_for(issue_meta, meta, "worker")]}
    else
      {ast, issues}
    end
  end

  # worker = to_string(__MODULE__) in an Oban worker, compared with j.worker later
  defp traverse({_node, meta, _args} = ast, issues, issue_meta, true) do
    if self_module_string?(ast) do
      {ast, issues ++ [issue_for(issue_meta, meta, "__MODULE__")]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _oban_worker?) do
    {ast, issues}
  end

  defp stringified_worker_comparison?(field, value) do
    worker_field?(field) and module_string?(value)
  end

  defp worker_field?({{:., _, [_struct, :worker]}, _, []}), do: true
  defp worker_field?(_ast), do: false

  defp self_module_string?({:|>, _, [{:__MODULE__, _, _}, _call]} = ast),
    do: module_string?(ast)

  defp self_module_string?({:<<>>, _, [{:"::", _, [{_, _, [{:__MODULE__, _, _}]}, _]}]} = ast),
    do: module_string?(ast)

  defp self_module_string?({_callee, _, [{:__MODULE__, _, _}]} = ast), do: module_string?(ast)
  defp self_module_string?(_ast), do: false

  defp module_string?({:^, _, [value]}), do: module_string?(value)
  defp module_string?(values) when is_list(values), do: Enum.any?(values, &module_string?/1)

  defp module_string?(
         {:<<>>, _, [{:"::", _, [{{:., _, [Kernel, :to_string]}, _, [_value]}, {:binary, _, _}]}]}
       ),
       do: true

  defp module_string?({:|>, _, [_value, {callee, _, []}]}), do: to_string_callee?(callee)
  defp module_string?({callee, _, [_value]}), do: to_string_callee?(callee)
  defp module_string?(_ast), do: false

  defp to_string_callee?(:to_string), do: true

  defp to_string_callee?({:., _, [{:__aliases__, _, [module]}, :to_string]})
       when module in [:Atom, :Kernel],
       do: true

  defp to_string_callee?(_callee), do: false

  defp issue_for(issue_meta, meta, trigger) do
    line_no = Keyword.get(meta, :line, 1)

    format_issue(
      issue_meta,
      message:
        "Build an Oban worker name with `Oban.Worker.to_string/1`; " <>
          "`to_string/1` keeps the `Elixir.` prefix Oban strips, so it matches no jobs",
      trigger: trigger,
      line_no: line_no
    )
  end
end
