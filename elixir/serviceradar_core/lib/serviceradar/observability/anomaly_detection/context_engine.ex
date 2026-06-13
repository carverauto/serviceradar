defmodule ServiceRadar.Observability.AnomalyDetection.ContextEngine do
  @moduledoc """
  Routes anomaly samples to their single-writer per-series context owner.
  """

  alias ServiceRadar.Observability.AnomalyDetection.ContextOwner
  alias ServiceRadar.ProcessRegistry

  @type sample :: ServiceRadar.Observability.AnomalyDetection.SampleExtractor.sample()

  @doc """
  Evaluates a sample through its Horde-owned series context.
  """
  @spec evaluate(sample()) :: {:ok, map()} | {:drop, term()} | {:error, term()}
  def evaluate(%{series_key: series_key} = sample) when is_binary(series_key) do
    with {:ok, pid} <- ensure_owner(series_key) do
      ContextOwner.evaluate(pid, sample)
    end
  end

  def evaluate(_sample), do: {:error, :missing_series_key}

  @doc """
  Evaluates samples in input order.

  The owner-backed engine preserves per-series single-writer semantics by
  delegating to `evaluate/1`. Shard-owned engines can override this boundary to
  use batch-capable native reasoner paths for independent series that are
  already grouped in one Broadway message.
  """
  @spec evaluate_batch([sample()]) :: [{:ok, map()} | {:drop, term()} | {:error, term()}]
  def evaluate_batch(samples) when is_list(samples), do: Enum.map(samples, &evaluate/1)

  @doc """
  Ensures a context owner exists for `series_key`.
  """
  @spec ensure_owner(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_owner(series_key) when is_binary(series_key) do
    case lookup_owner(series_key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        start_owner(series_key)
    end
  end

  @doc false
  @spec registry_key(String.t()) :: tuple()
  def registry_key(series_key), do: {:anomaly_context, series_key}

  @doc false
  @spec via(String.t()) :: {:via, module(), {atom(), term()}}
  def via(series_key), do: ProcessRegistry.via(registry_key(series_key))

  defp lookup_owner(series_key) do
    case ProcessRegistry.lookup(registry_key(series_key)) do
      [{pid, _metadata} | _] when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp start_owner(series_key) do
    child_spec = ContextOwner.child_spec(series_key: series_key)

    case ProcessRegistry.start_child(child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, {:already_registered, pid}} ->
        {:ok, pid}

      {:error, _reason} = error ->
        case lookup_owner(series_key) do
          {:ok, pid} -> {:ok, pid}
          :error -> error
        end
    end
  end
end
