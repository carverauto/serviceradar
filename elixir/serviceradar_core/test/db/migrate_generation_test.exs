defmodule ServiceRadar.DB.MigrateGenerationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @moduletag timeout: :infinity

  test "the prepared generation is verified and published" do
    ServiceRadar.DB.TemplateGeneration.run!()
  end
end
