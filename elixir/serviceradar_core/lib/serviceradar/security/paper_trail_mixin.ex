defmodule ServiceRadar.Security.PaperTrailMixin do
  @moduledoc false

  def mixin do
    quote do
      postgres do
        schema "platform"
      end
    end
  end

  # Identical to `mixin/0`, plus `ServiceRadar.Security.Changes.StampAuditActor`
  # and the `:actor`/`:actor_id`/`:request_id` attributes it writes to. A
  # separate function so this stays scoped to resources the Settings ->
  # Audit -> History allow-list surfaces (`AuditHistory.resources/0`).
  def mixin_with_audit_actor do
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
