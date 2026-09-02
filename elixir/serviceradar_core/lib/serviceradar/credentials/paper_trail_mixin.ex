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
end
