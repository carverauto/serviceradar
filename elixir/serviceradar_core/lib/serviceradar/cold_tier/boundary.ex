defmodule ServiceRadar.ColdTier.Boundary do
  @moduledoc """
  Per-table cold-tier boundary state.

  `frontier` (F) is the cold completeness frontier: everything strictly below
  it is verified-durable in object storage; it only advances over contiguously
  verified chunks. `query_boundary` (B) is the boundary the analytics head has
  acknowledged for its stitched views. Invariant (design D3): drop point <= B
  <= F, enforced by ordering — the head acknowledges B before any chunk at or
  below it becomes drop-eligible; the table's CHECK enforces B <= F. Maps to
  `platform.cold_tier_boundaries` (raw SQL migration 20260716200000).
  """

  use Ash.Resource,
    domain: ServiceRadar.ColdTier,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "cold_tier_boundaries"
    repo ServiceRadar.Repo
    schema "platform"
    # Managed by raw SQL migration (text PK, CHECK constraint)
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [:table_name, :frontier, :query_boundary, :boundary_acked_at]
      upsert? true
    end

    update :update do
      accept [:frontier, :query_boundary, :boundary_acked_at]
    end
  end

  attributes do
    attribute :table_name, :string, primary_key?: true, allow_nil?: false
    attribute :frontier, :utc_datetime_usec
    attribute :query_boundary, :utc_datetime_usec
    attribute :boundary_acked_at, :utc_datetime_usec

    update_timestamp :updated_at
  end
end
