defmodule ServiceRadar.Camera.RecordingControlState do
  @moduledoc """
  Deployment-local, irreversible administrative restriction on new recording work.

  The singleton baseline preserves explicitly enabled local recording until its
  first stop. RecordingControl owns ordering and origin checks; these actions are
  trusted persistence primitives and never grant storage or recording authority.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "camera_recording_control"
    schema "platform"
    repo ServiceRadar.Repo

    check_constraints do
      check_constraint :id, "camera_recording_control_singleton", check: "id = 'deployment'"

      check_constraint :stopped, "camera_recording_control_state",
        check: """
        (NOT stopped AND deployment_ref IS NULL AND generation IS NULL AND
         revision IS NULL AND desired_digest IS NULL AND received_at IS NULL) OR
        (stopped AND deployment_ref IS NOT NULL AND generation IS NOT NULL AND generation > 0 AND
         revision IS NOT NULL AND revision > 0 AND desired_digest IS NOT NULL AND
         desired_digest ~ '^[0-9a-f]{64}$' AND received_at IS NOT NULL)
        """
    end
  end

  actions do
    defaults [:read]

    create :initialize do
      accept []
      upsert? true
      upsert_fields []
    end

    update :stop do
      accept [:deployment_ref, :generation, :revision, :desired_digest, :received_at]
      change set_attribute(:stopped, true)
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :id, :string,
      primary_key?: true,
      allow_nil?: false,
      default: "deployment",
      constraints: [match: ~r/\Adeployment\z/]

    attribute :stopped, :boolean, allow_nil?: false, default: false
    attribute :deployment_ref, :uuid
    attribute :generation, :integer, constraints: [min: 1, max: 9_223_372_036_854_775_807]
    attribute :revision, :integer, constraints: [min: 1, max: 9_223_372_036_854_775_807]
    attribute :desired_digest, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :received_at, :utc_datetime_usec
  end
end
