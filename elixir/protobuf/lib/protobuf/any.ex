defmodule Protobuf.Any do

  @moduledoc """
  Provides functions for working with the `google.protobuf.Any` type.
  """
  @moduledoc since: "0.16.0"

  @type_url_prefix "type.googleapis.com/"

  @doc """
  Packs a Protobuf message into a `Google.Protobuf.Any` message.

  ## Example

      message = MyPkg.MyMessage.new(%{field: "value"})
      any = Protobuf.Any.pack(message)
      #=> %Google.Protobuf.Any{
      #=>   type_url: "type.googleapis.com/my_pkg.MyMessage",
      #=>   value: <<...>>
      #=> }

  """
  @spec pack(struct()) :: Google.Protobuf.Any.t()
  def pack(%mod{} = data) do
    %Google.Protobuf.Any{
      type_url: "#{@type_url_prefix}#{mod.full_name()}",
      value: mod.encode(data)
    }
  end

  @doc false
  @spec type_url_to_module(String.t()) :: module()
  def type_url_to_module(type_url) when is_binary(type_url) do
    case type_url do
      @type_url_prefix <> package_and_message ->
        package_and_message
        |> String.split(".")
        |> Enum.map(&Macro.camelize/1)
        |> Module.safe_concat()

      _other ->
        raise ArgumentError,
              "type_url must be in the form: type.googleapis.com/<package>.<message name>, " <>
                "got: #{inspect(type_url)}"
    end
  end
end
