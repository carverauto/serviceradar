defmodule ServiceRadar.Camera.SourceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.Source

  test "camera source update and upsert accept device_uid" do
    update_action = Ash.Resource.Info.action(Source, :update)
    upsert_action = Ash.Resource.Info.action(Source, :upsert)

    assert :device_uid in update_action.accept
    assert :device_uid in upsert_action.accept
  end
end
