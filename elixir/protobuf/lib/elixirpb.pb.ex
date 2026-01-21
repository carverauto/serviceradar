defmodule Elixirpb.FileOptions do
  @moduledoc false

  use Protobuf,
    full_name: "elixirpb.FileOptions",
    protoc_gen_elixir_version: "0.15.0",
    syntax: :proto2

  field :module_prefix, 1, optional: true, type: :string, json_name: "modulePrefix"
end
