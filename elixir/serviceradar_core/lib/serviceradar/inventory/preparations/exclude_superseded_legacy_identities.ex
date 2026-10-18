defmodule ServiceRadar.Inventory.Preparations.ExcludeSupersededLegacyIdentities do
  @moduledoc """
  Hides legacy virtualization rows that a source-scoped v3 row has replaced.

  Legacy Proxmox rows are no longer written, and the identity migration keeps
  them instead of deleting them. A legacy row is superseded when its
  `platform.virtualization_identity_aliases` entry is:

    * `resolved` and its `target_provider_ref` row exists, or
    * `ambiguous` and at least one of its `candidate_provider_refs` rows exists.

  Either way, current v3 inventory now describes the object, so the legacy row
  holds only stale status, utilization, and ownership, and its alias is
  non-authoritative. An `unresolved` alias, or no alias at all, leaves the row
  visible, because no v3 row describes that object yet.

  Exact provider-ref lookups are not prepared with this module, so alias
  resolution and migration evidence can still reach legacy rows.
  `superseded_sql/3` renders the same predicate for raw-SQL readers.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @tables %{
    cluster: "virtualization_clusters",
    host: "virtualization_hosts",
    guest: "virtualization_guests"
  }

  @template """
  EXISTS (
    SELECT 1
    FROM platform.virtualization_identity_aliases superseding_alias
    WHERE superseding_alias.provider = {{provider}}
      AND superseding_alias.resource_kind = '{{resource_kind}}'
      AND superseding_alias.legacy_provider_ref = {{provider_ref}}
      AND superseding_alias.status IN ('resolved', 'ambiguous')
      AND EXISTS (
        SELECT 1
        FROM platform.{{table}} successor
        WHERE successor.provider = superseding_alias.provider
          AND successor.provider_ref = ANY(
            CASE superseding_alias.status
              WHEN 'resolved' THEN ARRAY[superseding_alias.target_provider_ref]
              ELSE superseding_alias.candidate_provider_refs
            END
          )
      )
  )
  """

  @kind_templates Map.new(@tables, fn {resource_kind, table} ->
                    {resource_kind,
                     @template
                     |> String.replace("{{table}}", table)
                     |> String.replace("{{resource_kind}}", Atom.to_string(resource_kind))}
                  end)

  @type resource_kind :: :cluster | :host | :guest

  @doc """
  Returns a SQL boolean that is true when the row whose provider and
  provider_ref are the given SQL expressions is superseded.
  """
  @spec superseded_sql(resource_kind(), String.t(), String.t()) :: String.t()
  def superseded_sql(resource_kind, provider_sql, provider_ref_sql) do
    @kind_templates
    |> Map.fetch!(resource_kind)
    |> String.replace("{{provider}}", provider_sql)
    |> String.replace("{{provider_ref}}", provider_ref_sql)
  end

  @impl true
  def init(opts) do
    if Map.has_key?(@tables, opts[:resource_kind]),
      do: {:ok, opts},
      else: {:error, "resource_kind must be one of #{inspect(Map.keys(@tables))}"}
  end

  @impl true
  def prepare(query, opts, _context) do
    Ash.Query.do_filter(query, current_filter(opts[:resource_kind]))
  end

  # Ash fragments accept only literal SQL, so each kind's predicate is rendered
  # from the shared template at compile time.
  for {resource_kind, template} <- @kind_templates do
    sql =
      "NOT " <>
        (template
         |> String.replace("{{provider}}", "?")
         |> String.replace("{{provider_ref}}", "?"))

    defp current_filter(unquote(resource_kind)) do
      Ash.Expr.expr(fragment(unquote(sql), provider, provider_ref))
    end
  end
end
