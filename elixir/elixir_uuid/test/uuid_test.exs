defmodule UUIDTest do
  use ExUnit.Case, async: true

  test "info parses a default UUID" do
    assert {:ok,
            [
              uuid: "870df8e8-3107-4487-8316-81e089b8c2cf",
              binary: <<135, 13, 248, 232, 49, 7, 68, 135, 131, 22, 129, 224, 137, 184, 194, 207>>,
              type: :default,
              version: 4,
              variant: :rfc4122
            ]} = UUID.info("870df8e8-3107-4487-8316-81e089b8c2cf")
  end

  test "uuid4 generates a default UUID string" do
    assert UUID.uuid4() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end
end
