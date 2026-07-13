defmodule ServiceRadar.Credentials.RequestBodyPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.RequestBodyPolicy

  test "builds exact empty, bound-bytes, and trusted-rewrite policies" do
    body = ~s({"extra_vars":{"ratio":1.0},"limit":"node-1"})

    assert RequestBodyPolicy.empty(content_type: "application/json") == %{
             "mode" => "empty",
             "content_type" => "application/json",
             "max_mutations" => 1
           }

    assert RequestBodyPolicy.bound_bytes(body, max_bytes: 256 * 1024) == %{
             "mode" => "bound_bytes",
             "sha256" => body |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
             "source" => "command.authorized_request_body_b64",
             "content_type" => "application/json",
             "max_bytes" => 256 * 1024,
             "max_mutations" => 1
           }

    assert RequestBodyPolicy.trusted_rewrite("awx_callback_credential.v1") == %{
             "mode" => "trusted_rewrite",
             "handler" => "awx_callback_credential.v1",
             "content_type" => "application/json",
             "max_bytes" => 256 * 1024,
             "max_mutations" => 1
           }
  end

  test "normalizes atom keys but rejects unknown fields and handlers" do
    assert {:ok, %{"mode" => "empty", "max_mutations" => 1}} =
             RequestBodyPolicy.normalize(%{mode: "empty", max_mutations: 1})

    assert {:error, :invalid_request_body_policy_fields} =
             RequestBodyPolicy.validate(%{
               "mode" => "empty",
               "max_mutations" => 1,
               "permit_any_body" => true
             })

    assert {:error, :unreviewed_request_body_rewrite_handler} =
             RequestBodyPolicy.validate(%{
               "mode" => "trusted_rewrite",
               "handler" => "plugin_selected",
               "content_type" => "application/json",
               "max_bytes" => 1024,
               "max_mutations" => 1
             })
  end

  test "rejects malformed digests, sources, media types, sizes, and use limits" do
    base = %{
      "mode" => "bound_bytes",
      "sha256" => String.duplicate("a", 64),
      "source" => "command.authorized_request_body_b64",
      "content_type" => "application/json",
      "max_bytes" => 1024,
      "max_mutations" => 1
    }

    for invalid <- [
          Map.put(base, "sha256", String.duplicate("A", 64)),
          Map.put(base, "source", "plugin.body"),
          Map.put(base, "content_type", "application/json; charset=utf-8"),
          Map.put(base, "max_bytes", 0),
          Map.put(base, "max_mutations", 0)
        ] do
      refute RequestBodyPolicy.matches_type?(invalid, [])
    end
  end
end
