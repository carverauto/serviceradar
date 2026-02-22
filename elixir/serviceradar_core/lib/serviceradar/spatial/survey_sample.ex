defmodule ServiceRadar.Spatial.SurveySample do
  @moduledoc """
  Represents a cyber-physical survey sample captured by an iOS agent.
  Includes LiDAR physical coordinates, Wi-Fi attributes, and ML vectors (pgvector).
  """
  use Ash.Resource,
    domain: ServiceRadar.Spatial,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "survey_samples"
    repo ServiceRadar.Repo

    # Define custom PostGIS & pgvector types where needed.
    # The actual database columns will be created via standard Ecto migrations.
    custom_indexes do
      # pgvector hnsw index for rapid Nearest Neighbor RF matching
      index ["rf_vector"], name: "survey_samples_rf_vector_idx", using: "hnsw"
      index ["ble_vector"], name: "survey_samples_ble_vector_idx", using: "hnsw"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [
        :session_id,
        :scanner_device_id,
        :bssid,
        :ssid,
        :rssi,
        :frequency,
        :security_type,
        :is_secure,
        :x,
        :y,
        :z,
        :latitude,
        :longitude,
        :uncertainty
      ]
      
      # Vectors require special casting
      argument :rf_vector_array, {:array, :float}
      argument :ble_vector_array, {:array, :float}
      
      change set_attribute(:rf_vector, arg(:rf_vector_array))
      change set_attribute(:ble_vector, arg(:ble_vector_array))
      change set_attribute(:timestamp, &DateTime.utc_now/0)
    end

    action :bulk_insert, :boolean do
      argument :session_id, :string, allow_nil?: false
      argument :samples, {:array, :map}, allow_nil?: false
      
      run ServiceRadar.Spatial.Actions.BulkInsertSamples
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :session_id, :string, allow_nil?: false
    attribute :scanner_device_id, :string, allow_nil?: false
    attribute :timestamp, :utc_datetime_usec, allow_nil?: false
    
    # RF Identification
    attribute :bssid, :string, allow_nil?: false
    attribute :ssid, :string, allow_nil?: false
    attribute :rssi, :float, allow_nil?: false
    attribute :frequency, :integer, allow_nil?: false
    attribute :security_type, :string
    attribute :is_secure, :boolean

    # Local Spatial Positioning (ARKit/LiDAR relative coordinates)
    attribute :x, :float, allow_nil?: false
    attribute :y, :float, allow_nil?: false
    attribute :z, :float, allow_nil?: false
    attribute :uncertainty, :float
    
    # Global Spatial Positioning (GPS)
    attribute :latitude, :float
    attribute :longitude, :float

    # Note: Using :string for vectors in Ash schemas as a passthrough to the
    # underlying Ecto Vector type configured in the Repo.
    attribute :rf_vector, :string
    attribute :ble_vector, :string
  end
end
