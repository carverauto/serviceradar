defmodule ServiceRadarWebNG.Topology.BitmapQueries do
  @moduledoc "Current-membership queries with one local native snapshot per authorized response."
  use Supervisor

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.BitmapAuthority
  alias ServiceRadarWebNG.Topology.BitmapCursor
  alias ServiceRadarWebNG.Topology.BitmapExpression
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapPrefixTags
  alias ServiceRadarWebNG.Topology.BitmapQueryAdmission
  alias ServiceRadarWebNG.Topology.Native

  @tasks ServiceRadarWebNG.Topology.BitmapQueryTasks
  @deadline_ms 1_000

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  # BitmapQueryAdmission is the only starter of query tasks and counts them, so a
  # restart of either child must restart both.
  def init(_opts), do: Supervisor.init([{Task.Supervisor, name: @tasks}, BitmapQueryAdmission], strategy: :one_for_all)

  def enabled? do
    Application.get_env(:serviceradar_web_ng, :god_view_enabled, false) == true
  end

  @doc "Each page evaluates current membership; the cursor carries only an authorized ordinal position."
  def run(scope, params) when is_map(params) do
    with {:ok, {fence, result}} <- dispatch(scope, params, &page/2, []) do
      {:ok, Map.merge(json_fence(fence), result)}
    end
  end

  def run(_scope, _params), do: {:error, :invalid_query}

  @doc "Authorized lexical label discovery from an already prepared local prefix snapshot."
  def prefix_tags(scope, params) when is_map(params) do
    with :ok <- require_user(scope), :ok <- enabled(), :ok <- BitmapExpression.request_budget(params) do
      deadline = now() + @deadline_ms

      bounded(
        fn ->
          with {:ok, authority} <- BitmapAuthority.current(scope),
               {:ok, result} <- BitmapPrefixTags.page(params, authority, deadline),
               :ok <- authorize_delivery(scope, authority, %{result.source => result.version}),
               :ok <- enabled() do
            {:ok, result}
          end
        end,
        deadline
      )
    end
  end

  @doc """
  Runs a bounded callback on one pinned snapshot, closing the native query afterwards.

  Callers pass their original monotonic `:deadline` to include all response work
  in admission. Trusted geometry selectors may be built before admission or inside
  the callback. All tile rows and aggregate counts must use this single context
  and its remaining deadline.
  The callback returns `{:ok, result}`; the response is `{:ok, {fence, result}}`.
  """
  def with_query(scope, expression, fun, opts \\ []) when is_function(fun, 1) do
    dispatch(scope, %{"expression" => expression}, fn context, _parsed -> fun.(context) end, opts)
  end

  @doc "Remaining milliseconds for a native operation on an admitted response."
  def remaining(%{deadline: deadline}), do: remaining(deadline)

  def remaining(deadline) when is_integer(deadline) do
    case deadline - now() do
      budget when budget > 0 -> {:ok, min(budget, @deadline_ms)}
      _ -> {:error, :query_timeout}
    end
  end

  @doc "HTTP status for a bitmap query reason. Nil leaves tile-only world errors to the tile controller."
  def http_status(reason) do
    case reason do
      :unauthorized ->
        {401, "unauthorized"}

      :forbidden ->
        {403, "forbidden"}

      :bitmap_disabled ->
        {404, "bitmap_disabled"}

      :invalid_cursor ->
        {400, "invalid_cursor"}

      reason
      when reason in [:query_budget, :expression_budget, "expression_budget", :prefix_range_budget, "range_budget"] ->
        {413, "query_budget"}

      reason when reason in [:unsupported_entity, :unsupported_facet, "unsupported_facet"] ->
        {422, "unsupported_query"}

      reason when reason in ["facet_unavailable", "ip_unavailable"] ->
        {422, reason}

      reason
      when reason in [
             :prefix_source_unavailable,
             :prefix_registry_unavailable,
             "catalog_not_ready",
             "catalog_budget",
             "label_budget"
           ] ->
        {503, "prefix_source_unavailable"}

      reason
      when reason in [:invalid_query, :invalid_expression, :invalid_predicate, :invalid_page_limit, :invalid_cidr] ->
        {400, "invalid_query"}

      :query_timeout ->
        {503, "query_timeout"}

      :query_busy ->
        {503, "query_busy"}

      :index_not_ready ->
        {503, "index_not_ready"}

      :source_changed ->
        {503, "source_changed"}

      :query_unavailable ->
        {503, "query_unavailable"}

      reason
      when reason in [
             :invalid_tiles,
             :invalid_tile_receipt,
             :invalid_layout_version,
             :unsupported_membership_protocol
           ] ->
        {400, Atom.to_string(reason)}

      :membership_budget ->
        {413, "membership_budget"}

      :god_view_disabled ->
        {404, "god_view_disabled"}

      _ ->
        nil
    end
  end

  @doc "Client-visible reason shared by HTTP responses and channel membership errors."
  def public_reason(reason)
      when reason in [:membership_replaced, :membership_not_ready, "membership_replaced", "membership_not_ready"] do
    to_string(reason)
  end

  def public_reason(reason) when is_atom(reason) or is_binary(reason) do
    case http_status(reason) do
      {_status, name} -> name
      nil -> "query_unavailable"
    end
  end

  def public_reason(_reason), do: "query_unavailable"

  @busy_sources %{
    "pin_budget" => :pin_budget,
    "reader_budget" => :reader_budget,
    "native_memory_budget" => :native_memory_budget,
    "publisher_busy" => :publisher_busy,
    "reader_busy" => :reader_busy,
    "busy" => :native_busy,
    "catalog_busy" => :catalog_busy,
    :busy => :world_cache_busy
  }

  @doc """
  Counts one public `query_busy` by its origin, so a saturated deployment can
  tell admission, stream, task-pool, tile-cache and native budget refusals
  apart. Sources are a fixed atom set; the event carries no request data.
  """
  def busy(source) when is_atom(source),
    do: :telemetry.execute([:serviceradar, :topology, :bitmap_query, :busy], %{count: 1}, %{source: source})

  @doc "Shared retry and authorization errors for HTTP queries and streamed Atlas overlays."
  def normalize({:ok, _} = result), do: result

  def normalize({:error, reason}) when is_map_key(@busy_sources, reason), do: {:error, :query_busy}

  def normalize({:error, reason}) when reason in ["deadline_exceeded", :deadline_exceeded, :timeout],
    do: {:error, :query_timeout}

  def normalize({:error, reason}) when reason in ["not_ready", "closed", :index_unavailable],
    do: {:error, :index_not_ready}

  def normalize({:error, reason}) when reason in ["restart_required", "identity_mismatch", "revision_conflict"],
    do: {:error, :source_changed}

  def normalize({:error, reason}) when reason in ["authority_mismatch", "invalid_authority"], do: {:error, :forbidden}

  def normalize({:error, reason})
      when reason in [
             "catalog_not_ready",
             "catalog_budget",
             "label_budget",
             :prefix_registry_unavailable,
             :prefix_source_unavailable
           ], do: {:error, :prefix_source_unavailable}

  def normalize({:error, reason} = result) when is_atom(reason) or is_binary(reason), do: result
  def normalize(_), do: {:error, :query_unavailable}

  defp dispatch(scope, params, fun, opts) do
    with :ok <- require_user(scope), :ok <- enabled(), :ok <- BitmapExpression.request_budget(params) do
      deadline = min(Keyword.get(opts, :deadline, now() + @deadline_ms), now() + @deadline_ms)
      bounded(fn -> query(scope, params, fun, deadline) end, deadline)
    end
  end

  defp query(scope, params, fun, deadline) do
    with {:ok, authority} <- BitmapAuthority.current(scope),
         {:ok, snapshot} <- BitmapIndex.snapshot(),
         {:ok, parsed} <- BitmapExpression.parse(params, snapshot.supported_facets),
         {:ok, program, prefix_sources} <- BitmapPrefixTags.resolve(parsed.program, deadline) do
      context = %{
        dictionary_epoch: snapshot.dictionary_epoch,
        index_epoch: snapshot.index_epoch,
        authority: authority,
        query_digest: parsed.digest,
        deadline: deadline,
        progress: snapshot.progress,
        prefix_sources: prefix_sources
      }

      with {:ok, after_ordinal} <- BitmapCursor.after_ordinal(Map.get(params, "cursor"), context),
           {:ok, budget} <- remaining(deadline),
           {:ok, {ref, revision, source, total}} <-
             Native.bitmap_index_query(
               snapshot.device,
               snapshot.dictionary_epoch,
               snapshot.index_epoch,
               :device,
               authority,
               program,
               budget
             ) do
        context =
          Map.merge(context, %{
            ref: ref,
            revision: revision,
            source_revision: source,
            total: total,
            after_ordinal: after_ordinal
          })

        try do
          with {:ok, result} <- fun.(context, parsed), :ok <- delivery(scope, context) do
            {:ok, {fence(context), result}}
          end
        after
          Native.bitmap_query_close(ref)
        end
      end
    end
  end

  defp page(context, parsed) do
    with {:ok, budget} <- remaining(context),
         {:ok, ordinals} <-
           Native.bitmap_query_page(context.ref, context.authority, context.after_ordinal, parsed.limit, budget),
         {:ok, budget} <- remaining(context),
         {:ok, counts} <- Native.bitmap_query_facets(context.ref, context.authority, parsed.facets, budget) do
      cursor = if length(ordinals) == parsed.limit, do: BitmapCursor.sign(context, List.last(ordinals))

      facets =
        Enum.zip_with(parsed.facets, counts, fn {key, value}, count -> %{facet: key, value: value, count: count} end)

      {:ok, %{ordinals: ordinals, cursor: cursor, facets: facets}}
    end
  end

  defp delivery(scope, context) do
    with :ok <- enabled(),
         :ok <- authorize_delivery(scope, context.authority, context.prefix_sources),
         {:ok, budget} <- remaining(context),
         {:ok, []} <- Native.bitmap_query_facets(context.ref, context.authority, [], budget) do
      :ok
    end
  end

  defp authorize_delivery(scope, expected_authority, prefix_sources) do
    with {:ok, authority} <- BitmapAuthority.current(scope),
         true <- authority == expected_authority do
      BitmapPrefixTags.current(prefix_sources)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp bounded(work, deadline) do
    with {:ok, _budget} <- remaining(deadline),
         {:ok, result} <- BitmapQueryAdmission.run(work, deadline) do
      count_busy(result)
      if now() < deadline, do: normalize(result), else: {:error, :query_timeout}
    end
  end

  defp count_busy({:error, reason}) when is_map_key(@busy_sources, reason), do: busy(Map.fetch!(@busy_sources, reason))
  defp count_busy(_result), do: :ok

  defp require_user(%Scope{user: user}) when not is_nil(user), do: :ok
  defp require_user(_scope), do: {:error, :unauthorized}

  defp fence(context),
    do:
      Map.take(context, [:dictionary_epoch, :index_epoch, :revision, :source_revision, :prefix_sources, :total, :progress])

  defp json_fence(fence) do
    fence
    |> Map.put(:kind, "device")
    |> Map.update!(:dictionary_epoch, &Ecto.UUID.load!/1)
    |> Map.update!(:index_epoch, &Ecto.UUID.load!/1)
    |> Map.update!(:source_revision, &Base.encode64/1)
  end

  defp enabled, do: if(enabled?(), do: :ok, else: {:error, :bitmap_disabled})
  defp now, do: System.monotonic_time(:millisecond)
end
