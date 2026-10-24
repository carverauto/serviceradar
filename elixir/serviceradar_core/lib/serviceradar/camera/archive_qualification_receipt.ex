defmodule ServiceRadar.Camera.ArchiveQualificationReceipt do
  @moduledoc """
  Current qualification submission or withdrawal received for an archive binding.

  `ArchiveQualifications` serializes these trusted persistence primitives using
  the retained binding. A receipt records desired input, not applied configuration,
  verified evidence, credential revocation or permission to send storage requests.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "camera_archive_qualification_receipts"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :archive_binding, on_delete: :restrict
    end

    check_constraints do
      check_constraint :revision, "camera_qualification_receipt_bounds",
        check: "revision > 0 AND receipt_sha256 ~ '^[0-9a-f]{64}$'"

      check_constraint :report, "camera_qualification_receipt_state",
        check: """
        (state = 'withdrawn' AND report IS NULL AND report_sha256 IS NULL) OR
        (state = 'submitted' AND report IS NOT NULL AND report_sha256 IS NOT NULL AND
         report_sha256 ~ '^[0-9a-f]{64}$' AND jsonb_typeof(report) = 'object' AND
         octet_length(report::text) <= 16384)
        """
    end
  end

  actions do
    defaults [:read]

    create :receive do
      accept [
        :archive_binding_id,
        :revision,
        :state,
        :report,
        :report_sha256,
        :receipt_sha256,
        :received_at
      ]
    end

    update :replace do
      accept [:revision, :state, :report, :report_sha256, :receipt_sha256, :received_at]
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :archive_binding_id, :uuid, allow_nil?: false, primary_key?: true
    attribute :revision, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :state, :atom, allow_nil?: false, constraints: [one_of: [:submitted, :withdrawn]]
    attribute :report, :map, sensitive?: true
    attribute :report_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :receipt_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :received_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :archive_binding, ServiceRadar.Camera.ArchiveBinding,
      allow_nil?: false,
      define_attribute?: false
  end
end
