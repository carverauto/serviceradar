defmodule ServiceRadar.Security.PaperTrailMixin do
  @moduledoc false

  def mixin do
    quote do
      postgres do
        schema "platform"
      end
    end
  end
end
