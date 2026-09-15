defmodule ServiceRadar.AnalyticsStore.DeliveryReceipt do
  @moduledoc """
  Durable JetStream admission receipts for the hybrid EventWriter.

  Receipts share the primary transaction with hot rows and archive batches.
  They deliberately outlive hot retention: a late redelivery must not create
  another archive batch after its Timescale chunk has been removed.
  """

  use Ash.Resource,
    domain: ServiceRadar.AnalyticsStore.Catalog,
    data_layer: AshPostgres.DataLayer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.EventWriter.Processors.Telemetry
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  postgres do
    table "analytics_delivery_receipts"
    repo Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]

    create :claim do
      accept [:id, :claim_group]
      upsert? true
      upsert_fields []
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false
    attribute :claim_group, :uuid, allow_nil?: false
    create_timestamp :inserted_at
  end

  @doc "Process new deliveries atomically; other processors and storage modes retain their behavior."
  @spec process_batch(module(), [map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_batch(processor, messages, opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    process = Keyword.get(opts, :processor_fn, &processor.process_batch/1)

    if processor in [Metrics, Telemetry] and
         Config.driver_for(cfg, "timeseries_metrics") == :hybrid do
      process = Keyword.get(opts, :processor_fn, hybrid_processor(processor))
      process_new(messages, process, Keyword.put(opts, :config, cfg))
    else
      process.(messages)
    end
  end

  defp hybrid_processor(Metrics), do: &Metrics.process_batch(&1, defer_facts: true)
  defp hybrid_processor(processor), do: &processor.process_batch/1

  defp process_new(messages, process, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    claim = Keyword.get(opts, :claim_fn, &claim/2)
    transaction = Keyword.get(opts, :transaction, &Ash.transact(__MODULE__, &1))

    with {:ok, {count, after_commit}} <-
           transaction.(fn ->
             with {:ok, fresh} <- claim.(messages, opts),
                  {:ok, count, after_commit} <- process_fresh(fresh, process) do
               {count, after_commit}
             else
               {:error, reason} -> repo.rollback(reason)
             end
           end) do
      run_after_commit(after_commit)
      {:ok, count}
    end
  rescue
    error -> {:error, error}
  end

  defp process_fresh([], _process), do: {:ok, 0, nil}

  defp process_fresh(messages, process) do
    case process.(messages) do
      {:ok, count} -> {:ok, count, nil}
      result -> result
    end
  end

  defp run_after_commit(nil), do: :ok

  defp run_after_commit(callback) do
    callback.()
    :ok
  rescue
    error ->
      Logger.warning("Post-commit metric facts could not be written",
        error: inspect(error.__struct__)
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning("Post-commit metric facts could not be written", error: kind)
      :ok
  end

  @doc "Claim receipt identities inside the caller's primary transaction."
  @spec claim([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def claim(messages, _opts \\ []) do
    with {:ok, identified} <- identify(messages) do
      claim_identified(identified)
    end
  end

  defp identify(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, identified} ->
      case identity(message) do
        {:ok, id} -> {:cont, {:ok, [{id, message} | identified]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, identified} -> {:ok, identified |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))}
      error -> error
    end
  end

  defp claim_identified([]), do: {:ok, []}

  defp claim_identified(identified) do
    group = Ecto.UUID.generate()
    actor = SystemActor.system(:analytics_store)

    attrs =
      identified
      |> Enum.map(fn {id, _message} -> %{id: id, claim_group: group} end)
      |> Enum.sort_by(& &1.id)

    case Ash.bulk_create(attrs, __MODULE__, :claim,
           actor: actor,
           return_errors?: true,
           stop_on_error?: true
         ) do
      %Ash.BulkResult{status: :success} ->
        read_claimed(identified, group, actor)

      %Ash.BulkResult{errors: errors} ->
        {:error, {:delivery_receipt_claim_failed, errors}}
    end
  end

  defp read_claimed(identified, group, actor) do
    ids = Enum.map(identified, &elem(&1, 0))

    query =
      __MODULE__
      |> Ash.Query.filter(id in ^ids and claim_group == ^group)
      |> Ash.Query.select([:id])

    case Ash.read(query, actor: actor) do
      {:ok, receipts} ->
        claimed = MapSet.new(receipts, & &1.id)
        {:ok, for({id, message} <- identified, MapSet.member?(claimed, id), do: message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Identity excludes delivery-attempt and consumer fields, which change on redelivery."
  @spec identity(map()) :: {:ok, String.t()} | {:error, :missing_jetstream_identity}
  def identity(%{metadata: %{jetstream_ack: ack}}) when is_map(ack) do
    scope = Map.get(ack, :source_scope, "")

    case ack do
      %{stream: stream, stream_sequence: sequence, timestamp: timestamp}
      when is_binary(stream) and stream != "" and is_integer(sequence) and sequence > 0 and
             is_integer(timestamp) and timestamp > 0 and is_binary(scope) ->
        encoded = Jason.encode!(["analytics-delivery-v1", scope, stream, sequence, timestamp])
        {:ok, :sha256 |> :crypto.hash(encoded) |> Base.encode16(case: :lower)}

      _ ->
        {:error, :missing_jetstream_identity}
    end
  end

  def identity(_message), do: {:error, :missing_jetstream_identity}
end
