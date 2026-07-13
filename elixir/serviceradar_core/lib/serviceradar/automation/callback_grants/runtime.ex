defmodule ServiceRadar.Automation.CallbackGrants.Runtime do
  @moduledoc false

  alias ServiceRadar.Automation.CallbackGrants.AshStore
  alias ServiceRadar.Automation.CallbackGrants.AwxCleanup
  alias ServiceRadar.Automation.CallbackGrants.CurrentAuthority
  alias ServiceRadar.Automation.CallbackGrants.Lifecycle

  @config_key :automation_callback_grants

  @spec consume(binary(), binary(), binary(), map()) ::
          {:ok, map()} | {:retry, map()} | {:error, term()}
  def consume(grant_id, bearer, idempotency_key, request) do
    with {:ok, opts, consumer} <- lifecycle_opts_and_consumer() do
      consumer.consume(grant_id, bearer, idempotency_key, request, opts)
    end
  rescue
    _ -> {:error, :callback_unavailable}
  catch
    _, _ -> {:error, :callback_unavailable}
  end

  @doc "Queues post-activation AWX credential deletion without waiting for confirmation."
  @spec delete_activated_credential(binary()) :: {:ok, map()} | {:error, term()}
  @spec delete_activated_credential(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_activated_credential(grant_id, cleanup_opts \\ [])

  def delete_activated_credential(grant_id, cleanup_opts)
      when is_binary(grant_id) and is_list(cleanup_opts) do
    with {:ok, opts, consumer} <- lifecycle_opts_and_consumer(),
         true <- Code.ensure_loaded?(consumer),
         true <- function_exported?(consumer, :delete_activated_credential, 2) do
      opts = maybe_enable_deleting_retry(opts, cleanup_opts)
      consumer.delete_activated_credential(grant_id, opts)
    else
      _ -> {:error, :callback_unavailable}
    end
  rescue
    _ -> {:error, :callback_unavailable}
  catch
    _, _ -> {:error, :callback_unavailable}
  end

  def delete_activated_credential(_grant_id, _cleanup_opts), do: {:error, :callback_unavailable}

  @doc "Returns the production lifecycle adapters without logging verifier material."
  @spec lifecycle_opts() :: {:ok, keyword()} | {:error, :callback_unavailable}
  def lifecycle_opts do
    with {:ok, opts, _consumer} <- lifecycle_opts_and_consumer(), do: {:ok, opts}
  end

  defp lifecycle_opts_and_consumer do
    with {:ok, config} <- Application.fetch_env(:serviceradar_core, @config_key),
         true <- is_list(config),
         {:ok, verifier_config} <- Keyword.fetch(config, :verifier_config) do
      {:ok,
       [
         store: Keyword.get(config, :store, AshStore),
         authorizer: Keyword.get(config, :authorizer, CurrentAuthority),
         cleanup: Keyword.get(config, :cleanup, AwxCleanup),
         cleanup_context: Keyword.get(config, :cleanup_context),
         verifier_config: verifier_config,
         authority_context: Keyword.get(config, :authority_context),
         store_context: Keyword.get(config, :store_context)
       ], Keyword.get(config, :consumer, Lifecycle)}
    else
      _ -> {:error, :callback_unavailable}
    end
  end

  defp maybe_enable_deleting_retry(opts, cleanup_opts) do
    if Keyword.get(cleanup_opts, :retry_deleting?, false) do
      context = Keyword.get(opts, :cleanup_context)

      context =
        cond do
          is_list(context) -> Keyword.put(context, :retry_deleting?, true)
          is_map(context) -> Map.put(context, :retry_deleting?, true)
          true -> [retry_deleting?: true]
        end

      Keyword.put(opts, :cleanup_context, context)
    else
      opts
    end
  end
end
