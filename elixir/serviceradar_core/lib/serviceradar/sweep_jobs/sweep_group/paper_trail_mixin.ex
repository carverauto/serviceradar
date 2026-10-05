defmodule ServiceRadar.SweepJobs.SweepGroup.PaperTrailMixin do
  @moduledoc false

  def mixin do
    quote do
      postgres do
        schema "platform"
      end

      changes do
        change ServiceRadar.Security.Changes.StampAuditActor, on: :create
      end

      attributes do
        attribute :actor, :map do
          public? true
        end

        attribute :actor_id, :string do
          public? true
        end

        attribute :request_id, :string do
          public? true
        end
      end
    end
  end
end
