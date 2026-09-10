defmodule ServiceRadar.Credentials.PaperTrailMixin do
  @moduledoc false

  def mixin do
    quote do
      postgres do
        schema "platform"
      end
    end
  end

  def cascade_versions do
    quote do
      postgres do
        schema "platform"

        references do
          reference :version_source, on_delete: :delete
        end
      end
    end
  end

  def retained_versions do
    quote do
      postgres do
        schema "platform"

        references do
          # Audit source UUIDs survive permanent configuration deletion.
          reference :version_source, ignore?: true
        end
      end
    end
  end

  # `_with_audit_actor` variants: identical to their counterparts above, plus
  # `ServiceRadar.Security.Changes.StampAuditActor` and the `:actor`/`:actor_id`/
  # `:request_id` attributes it writes to. Separate functions (rather than
  # changing `mixin/0` etc. in place) so this stays scoped to the resources
  # the Settings -> Audit -> History allow-list actually surfaces
  # (`ServiceRadar.Security.AuditHistory.resources/0`) instead of also
  # changing every other consumer of this module's plain variants.
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

  def cascade_versions_with_audit_actor do
    quote do
      postgres do
        schema "platform"

        references do
          reference :version_source, on_delete: :delete
        end
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

  def retained_versions_with_audit_actor do
    quote do
      postgres do
        schema "platform"

        references do
          # Audit source UUIDs survive permanent configuration deletion.
          reference :version_source, ignore?: true
        end
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
