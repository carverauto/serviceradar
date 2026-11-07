defmodule ServiceRadar.Ingestion.Admission do
  @moduledoc """
  Bounded status routing; payloads move only after a metadata reservation.
  """

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Ingestion.StatusIngestor

  @core_budget_ms 15_000

  def budget_ms, do: @core_budget_ms

  def reserve(%{headers: headers} = descriptor, owner, timeout) when is_map(headers) do
    Lane.reserve(server(classify(headers)), descriptor, owner, timeout)
  end

  def reserve(_descriptor, _owner, _timeout), do: {:error, :invalid_admission_descriptor}

  @doc """
  Hands a reservation to its lane, which answers `from` itself.

  The router that receives reservations must not wait for the lane: the caller
  that owns `from` keeps its own deadline and holds no payload until the lane
  has answered. A reservation the lane reaches more than `timeout` milliseconds
  after it was forwarded is refused with `{:error, :admission_timeout}` without
  holding capacity.
  """
  def forward_reserve(%{headers: headers} = descriptor, {owner, _tag} = from, timeout)
      when is_map(headers) and is_pid(owner) do
    Lane.forward_reserve(server(classify(headers)), descriptor, owner, from, timeout)
  end

  def forward_reserve(_descriptor, _from, _timeout), do: {:error, :invalid_admission_descriptor}

  def admit(status, reply_to, timeout \\ 1_000) do
    descriptor = Lane.descriptor(status, @core_budget_ms)

    owner =
      case reply_to do
        {pid, _} -> pid
        _ -> self()
      end

    with {:ok, {lane, id}} <- reserve(descriptor, owner, timeout) do
      Lane.submit(lane, id, status, reply_to, timeout)
    end
  end

  def ingest(status) do
    StatusIngestor.ingest(status, best_effort?: status[:ingestion_best_effort] == true)
  end

  def classify(_), do: :status

  def server(type), do: {:via, Registry, {ServiceRadar.Ingestion.Registry, {:lane, type}}}
end
