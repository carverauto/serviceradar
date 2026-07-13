defmodule ServiceRadar.Automation.CallbackGrants.Runtime do
  @moduledoc false

  alias ServiceRadar.Automation.CallbackGrants.AshStore
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
         verifier_config: verifier_config,
         authority_context: Keyword.get(config, :authority_context),
         store_context: Keyword.get(config, :store_context)
       ], Keyword.get(config, :consumer, Lifecycle)}
    else
      _ -> {:error, :callback_unavailable}
    end
  end
end
