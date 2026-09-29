defmodule ServiceRadarCore.Mix.JsonApiPrimaryKeyPatch do
  @moduledoc false
  @marker "U+001F"

  def apply! do
    root = Path.expand("../deps/ash_json_api", __DIR__)
    resource = Path.join(root, "lib/ash_json_api/resource/resource.ex")

    cond do
      not File.regular?(resource) ->
        :ok

      File.read!(resource) =~ @marker ->
        :ok

      true ->
        patch =
          Path.expand(
            "../../../third_party/patches/ash_json_api/null_composite_id.patch",
            __DIR__
          )

        case System.cmd("patch", ["-p1", "-N", "-t", "-i", patch],
               cd: root,
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            :ok

          {output, status} ->
            Mix.raise("ash_json_api composite id patch failed (#{status}): #{output}")
        end
    end
  end
end
