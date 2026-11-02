defmodule ServiceRadar.Edge.StaticNatsPermissionProjectionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.StaticNatsPermissionProjection, as: Projection

  test "an empty static allow keeps the same denies and does not widen an explicit allow" do
    static = %{
      "publish" => %{
        "allow" => ["metrics.example.>", "$JS.API.>"],
        "deny" => ["$SYS.>", "events.example.>"]
      },
      "subscribe" => %{
        "allow" => [],
        "deny" => ["$SYS.>", "flow.example.>"]
      }
    }

    assert {:ok, grants} = Projection.project(static)

    assert grants == %{
             "publish" => ["metrics.example.>", "$JS.API.>"],
             "subscribe" => [">"],
             "publish_deny" => ["$SYS.>", "events.example.>"],
             "subscribe_deny" => ["$SYS.>", "flow.example.>"]
           }

    refute grants["publish"] == [">"]
  end

  test "a non-empty allow is copied and a missing allow is unrestricted except its denies" do
    explicit = %{
      publish: %{allow: ["_INBOX.>"], deny: ["$SYS.>"]},
      subscribe: %{allow: ["config.example.>"]}
    }

    assert {:ok, copied} = Projection.project(explicit)
    assert copied["publish"] == ["_INBOX.>"]
    assert copied["subscribe"] == ["config.example.>"]
    assert copied["publish_deny"] == ["$SYS.>"]
    assert copied["subscribe_deny"] == []

    unrestricted = %{
      "publish" => %{"deny" => ["$SYS.>"]},
      "subscribe" => %{}
    }

    assert {:ok, legacy} = Projection.project(unrestricted)
    assert legacy["publish"] == [">"]
    assert legacy["publish_deny"] == ["$SYS.>"]
    assert legacy["subscribe"] == [">"]
    assert legacy["subscribe_deny"] == []
  end

  test "rejects a grant that is not an explicit static permission block" do
    assert {:error, :invalid_permissions} = Projection.project(:all)
    assert {:error, :invalid_permissions} = Projection.project(%{publish: %{allow: [">"]}})

    assert {:error, :invalid_permissions} =
             Projection.project(%{
               "publish" => %{"allow" => [">"]},
               "subscribe" => %{"allow" => [">"]},
               "allow_responses" => true
             })

    assert {:error, :invalid_permissions} =
             Projection.project(%{publish: %{allow: [">"]}, subscribe: "all"})

    assert {:error, :invalid_subject} =
             Projection.project(%{
               publish: %{allow: ["example.>.events"]},
               subscribe: %{allow: ["example.>"]}
             })
  end
end
