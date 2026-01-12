defmodule ServiceRadar.Credo.Check.Warning.AuthorizeFalseUsage do
  @moduledoc """
  Detects usage of `authorize?: false` in Ash operations.

  Using `authorize?: false` bypasses ALL authorization policies, including tenant
  isolation. This creates security vulnerabilities where background operations
  could inadvertently access cross-tenant data.

  ## Why This Is Problematic

  With schema-isolated multi-tenancy, most resources are protected by PostgreSQL
  schema boundaries. However, some resources live in the public schema and rely
  on policy-level tenant isolation. Bypassing authorization removes this protection.

  ## The Solution: SystemActor

  Instead of `authorize?: false`, use `ServiceRadar.Actors.SystemActor`:

      # For tenant-scoped operations
      actor = SystemActor.for_tenant(tenant_id, :my_component)
      Resource |> Ash.read(actor: actor, tenant: tenant_schema)

      # For platform-wide operations (bootstrap, tenant management)
      actor = SystemActor.platform(:my_component)
      Resource |> Ash.read(actor: actor)

  ## Exceptions

  The only acceptable uses of `authorize?: false` are:
  - In test files (`_test.exs`)
  - In comments or documentation
  - In Ash resource definitions (for internal framework use)

  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid `authorize?: false` - use SystemActor.for_tenant/2 or SystemActor.platform/1 instead.
      See ServiceRadar.Actors.SystemActor for the proper pattern.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    filename = source_file.filename

    cond do
      # Skip test files
      String.ends_with?(filename, "_test.exs") ->
        []

      # Skip this check file itself (contains authorize?: false in docs)
      String.ends_with?(filename, "authorize_false_usage.ex") ->
        []

      true ->
        Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # Match authorize?: false in keyword lists
  defp traverse({:authorize?, {:__block__, meta, [false]}} = ast, issues, issue_meta) do
    {ast, issues ++ [issue_for(issue_meta, meta)]}
  end

  # Match authorize?: false with line metadata
  defp traverse({:authorize?, meta, [false]} = ast, issues, issue_meta) when is_list(meta) do
    {ast, issues ++ [issue_for(issue_meta, meta)]}
  end

  # Match keyword list style: [authorize?: false] (no metadata)
  defp traverse({:authorize?, false} = ast, issues, issue_meta) do
    {ast, issues ++ [issue_for(issue_meta, [])]}
  end

  # Match keyword list style: {{:authorize?, meta}, false}
  defp traverse({{:authorize?, meta}, false} = ast, issues, issue_meta) when is_list(meta) do
    {ast, issues ++ [issue_for(issue_meta, meta)]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, meta) do
    line_no = Keyword.get(meta, :line, 1)

    format_issue(
      issue_meta,
      message:
        "Avoid `authorize?: false` - use SystemActor.for_tenant/2 or SystemActor.platform/1 instead",
      trigger: "authorize?: false",
      line_no: line_no
    )
  end
end
