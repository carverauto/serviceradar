defmodule ServiceRadar.Observability.SeasonalDisposition.ChronologicalState do
  @moduledoc """
  Durable hourly verdicts used to confirm adjacent seasonal anomalies.

  The explicit upgrade migration owns this table and the idempotent legacy reset.
  `StateStore` batches its writes and selects chronological state across hour-of-week
  rows; this resource provides the read model for the same persisted state.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "seasonal_disposition_chronological_states"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    attribute :source, :string, primary_key?: true, allow_nil?: false
    attribute :series_key, :string, primary_key?: true, allow_nil?: false
    attribute :dow, :integer, primary_key?: true, allow_nil?: false, constraints: [min: 0, max: 6]

    attribute :hod, :integer,
      primary_key?: true,
      allow_nil?: false,
      constraints: [min: 0, max: 23]

    attribute :consecutive_anomalous, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]

    attribute :last_disposition, :string
    attribute :last_status, :string
    attribute :last_score, :float
    attribute :last_evaluated_at, :utc_datetime_usec
    attribute :last_bucket_started_at, :utc_datetime_usec
    attribute :last_bucket_ended_at, :utc_datetime_usec
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
