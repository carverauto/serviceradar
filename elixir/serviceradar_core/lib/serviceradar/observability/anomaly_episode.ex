defmodule ServiceRadar.Observability.AnomalyEpisode do
  @moduledoc """
  Bounded lifecycle state for anomaly findings.

  `platform.ocsf_events` remains an append-only transition log; this resource is
  the current episode surface keyed by the producer's deterministic episode UID.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @episode_fields [
    :episode_uid,
    :finding_uid,
    :device_uid,
    :series_key,
    :metric_name,
    :if_index,
    :metric_class,
    :detector,
    :status,
    :severity_id,
    :peak_severity_id,
    :effect_size,
    :peak_score,
    :opened_at,
    :last_seen_at,
    :cleared_at,
    :clear_reason,
    :occurrence_count,
    :reopen_count,
    :producer_version,
    :last_transition,
    :last_payload
  ]

  @episode_upsert_fields @episode_fields -- [:episode_uid, :finding_uid, :opened_at]

  postgres do
    table "anomaly_episodes"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_episode_uid, action: :by_episode_uid, args: [:episode_uid]
    define :list_open, action: :open
    define :upsert_episode, action: :upsert
  end

  actions do
    defaults [:read]

    read :by_episode_uid do
      get? true
      argument :episode_uid, :string, allow_nil?: false
      filter expr(episode_uid == ^arg(:episode_uid))
    end

    read :open do
      filter expr(status == "open")
      prepare build(sort: [last_seen_at: :desc])
    end

    create :upsert do
      accept @episode_fields

      upsert? true
      upsert_identity :unique_episode

      upsert_fields @episode_upsert_fields ++ [:updated_at]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action(:upsert)
  end

  attributes do
    attribute :episode_uid, :string do
      primary_key? true
      allow_nil? false
      public? true
      description "Deterministic producer episode identity"
    end

    attribute :finding_uid, :string do
      allow_nil? false
      public? true
      description "Stable finding identity shared across episode reopens"
    end

    attribute :device_uid, :string do
      allow_nil? false
      public? true
    end

    attribute :series_key, :string do
      allow_nil? false
      public? true
    end

    attribute :metric_name, :string do
      public? true
    end

    attribute :if_index, :integer do
      public? true
    end

    attribute :metric_class, :string do
      public? true
    end

    attribute :detector, :string do
      allow_nil? false
      public? true
      description "Detector family, for example spike, drift, central_seasonal, or capacity"
    end

    attribute :status, :string do
      allow_nil? false
      default "open"
      public? true
      description "Episode lifecycle status: open, cleared, or stale_closed"
    end

    attribute :severity_id, :integer do
      allow_nil? false
      default 1
      public? true
    end

    attribute :peak_severity_id, :integer do
      allow_nil? false
      default 1
      public? true
    end

    attribute :effect_size, :float do
      public? true
    end

    attribute :peak_score, :float do
      public? true
    end

    attribute :opened_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :cleared_at, :utc_datetime_usec do
      public? true
    end

    attribute :clear_reason, :string do
      public? true
    end

    attribute :occurrence_count, :integer do
      allow_nil? false
      default 1
      public? true
    end

    attribute :reopen_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :producer_version, :string do
      public? true
    end

    attribute :last_transition, :string do
      public? true
    end

    attribute :last_payload, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_episode, [:episode_uid]
  end
end
