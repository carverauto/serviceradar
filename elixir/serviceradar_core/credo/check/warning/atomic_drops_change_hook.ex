defmodule ServiceRadar.Credo.Check.Warning.AtomicDropsChangeHook do
  @moduledoc """
  Detects an Ash change whose `atomic/3` returns a bare `:ok` while the module
  registers an after-action or after-transaction hook.

  Ash can upgrade an update to an atomic one. It then builds a second changeset
  and calls `atomic/3` instead of `change/3`. Attribute changes and errors that
  `change/3` produced are carried over; a hook it registered is not. With

      def atomic(_changeset, _opts, _context), do: :ok

  the update succeeds and the hook never runs, and nothing reports it: an event
  is not published, a job is not scheduled, a credential is not revoked.

  ## The Solution

  Register the hook on the atomic path too:

      def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  When `change/3` also changes attributes, register only the hook in `atomic/3`
  and let it decide from the saved record. When every action that uses the
  change is `require_atomic? false`, delete `atomic/3`: it is never called.

  ## What Is Flagged

  An `atomic/3` clause whose body is `:ok`, in a file that does
  `use Ash.Resource.Change` and calls a function named `after_action`,
  `after_action_result` or `after_transaction`.

  Not flagged: a hook registered by a helper in another module under a
  different name.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      An Ash change that registers an after hook must register it in `atomic/3`
      as well. A bare `:ok` from `atomic/3` drops the hook on atomic updates.
      """
    ]

  @hook_functions [:after_action, :after_action_result, :after_transaction]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params \\ []) do
    if Credo.Code.prewalk(source_file, &hook_registering_change/2, %{change?: false, hook?: false}) ==
         %{change?: true, hook?: true} do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &bare_ok_atomic(&1, &2, issue_meta))
    else
      []
    end
  end

  defp hook_registering_change({:use, _, [{:__aliases__, _, [:Ash, :Resource, :Change]} | _]} = ast, found),
    do: {ast, %{found | change?: true}}

  defp hook_registering_change({{:., _, [_module, function]}, _, _args} = ast, found)
       when function in @hook_functions,
       do: {ast, %{found | hook?: true}}

  defp hook_registering_change({function, _, args} = ast, found)
       when function in @hook_functions and is_list(args),
       do: {ast, %{found | hook?: true}}

  defp hook_registering_change(ast, found), do: {ast, found}

  defp bare_ok_atomic({:def, meta, [head, [{:do, body} | _]]} = ast, issues, issue_meta) do
    if atomic_head?(head) and returns_bare_ok?(body) do
      {ast, issues ++ [issue_for(issue_meta, meta)]}
    else
      {ast, issues}
    end
  end

  defp bare_ok_atomic(ast, issues, _issue_meta), do: {ast, issues}

  defp atomic_head?({:when, _, [head | _guards]}), do: atomic_head?(head)
  defp atomic_head?({:atomic, _, [_changeset, _opts, _context]}), do: true
  defp atomic_head?(_head), do: false

  defp returns_bare_ok?(:ok), do: true
  defp returns_bare_ok?({:__block__, _, expressions}), do: List.last(expressions) == :ok
  defp returns_bare_ok?(_body), do: false

  defp issue_for(issue_meta, meta) do
    format_issue(
      issue_meta,
      message:
        "`atomic/3` returns `:ok` but this change registers an after hook; " <>
          "an atomic update drops it. Register the hook in `atomic/3` or delete `atomic/3`",
      trigger: "atomic",
      line_no: Keyword.get(meta, :line, 1)
    )
  end
end
