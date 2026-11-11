defmodule ServiceRadar.Edge.ManagedCertificateReconcileWorker do
  @moduledoc "Finds pending rotations and due renewals without relying on a live web-node notifier."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ManagedCertificateLifecycleWorker
  alias ServiceRadar.Edge.ManagedCertificateOperation

  require Ash.Query

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    ManagedCertificateOperation
    |> Ash.Query.for_read(:reconcile)
    |> Ash.Query.filter(
      status in [:preparing, :issuing, :installing] or
        (status == :activated and renew_after <= ^now)
    )
    |> Ash.Query.select([:id])
    |> Ash.stream!(actor: SystemActor.system(:managed_certificate_renewal), batch_size: 100)
    |> Enum.reduce_while(:ok, fn operation, :ok ->
      case ManagedCertificateLifecycleWorker.enqueue(operation.id) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
