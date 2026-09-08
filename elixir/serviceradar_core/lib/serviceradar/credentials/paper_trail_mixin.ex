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
end
