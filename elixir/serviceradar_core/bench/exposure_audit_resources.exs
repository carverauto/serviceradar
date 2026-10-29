defmodule ServiceRadar.ExposureAudit.Domain do
  @moduledoc "Scratch-only audit metadata. This domain is not registered by the application."
  use Ash.Domain

  resources do
    resource ServiceRadar.ExposureAudit.Epoch
    resource ServiceRadar.ExposureAudit.Run
    resource ServiceRadar.ExposureAudit.Proof
    resource ServiceRadar.ExposureAudit.Work
  end
end

defmodule ServiceRadar.ExposureAudit.Epoch do
  @moduledoc "Read-only metadata; fenced batch writes belong to ExposureAudit.State."
  use Ash.Resource,
    domain: ServiceRadar.ExposureAudit.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "exposure_audit_epoch"
    schema "platform"
    repo ServiceRadar.Repo
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :id, :boolean, primary_key?: true, allow_nil?: false
    attribute :fence, :integer, allow_nil?: false
  end
end

defmodule ServiceRadar.ExposureAudit.Run do
  @moduledoc "Read-only metadata; fenced batch writes belong to ExposureAudit.State."
  use Ash.Resource,
    domain: ServiceRadar.ExposureAudit.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "exposure_audit_runs"
    schema "platform"
    repo ServiceRadar.Repo
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :fence, :integer, allow_nil?: false
    attribute :format_version, :integer, allow_nil?: false
    attribute :status, :string, allow_nil?: false
    attribute :started_at, :utc_datetime_usec, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :cursor, :integer, allow_nil?: false
    attribute :enumerated, :boolean, allow_nil?: false
  end
end

defmodule ServiceRadar.ExposureAudit.Proof do
  @moduledoc "Read-only metadata; fenced batch writes belong to ExposureAudit.State."
  use Ash.Resource,
    domain: ServiceRadar.ExposureAudit.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "exposure_audit_proofs"
    schema "platform"
    repo ServiceRadar.Repo
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :run_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :kind, :string, primary_key?: true, allow_nil?: false
    attribute :ordinal, :integer, primary_key?: true, allow_nil?: false
    attribute :source_seq, :integer, primary_key?: true, allow_nil?: false
    attribute :source_hash, :binary, primary_key?: true, allow_nil?: false
    attribute :warehouse_hash, :string, allow_nil?: false
    attribute :checked_at, :utc_datetime_usec, allow_nil?: false
    attribute :source_view, :string, allow_nil?: false
  end
end

defmodule ServiceRadar.ExposureAudit.Work do
  @moduledoc "Read-only metadata; fenced batch writes belong to ExposureAudit.State."
  use Ash.Resource,
    domain: ServiceRadar.ExposureAudit.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "exposure_audit_work"
    schema "platform"
    repo ServiceRadar.Repo
    migrate? false
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
  end

  attributes do
    attribute :run_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :device_ord, :integer, primary_key?: true, allow_nil?: false
    attribute :status, :string, allow_nil?: false
    attribute :evidence_at, :utc_datetime_usec
    attribute :result, :map, allow_nil?: false
  end
end
