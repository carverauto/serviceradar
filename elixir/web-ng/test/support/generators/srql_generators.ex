defmodule ServiceRadarWebNG.Generators.SRQLGenerators do
  @moduledoc false

  import StreamData

  def printable_query_string(opts \\ []) do
    max_length = Keyword.get(opts, :max_length, 200)
    string(:printable, max_length: max_length)
  end

  def json_key(opts \\ []) do
    min_length = Keyword.get(opts, :min_length, 1)
    max_length = Keyword.get(opts, :max_length, 24)

    string(:alphanumeric, min_length: min_length, max_length: max_length)
  end

  def json_value do
    one_of([
      string(:printable, max_length: 200),
      integer(),
      boolean(),
      constant(nil)
    ])
  end

  def json_map(opts \\ []) do
    max_length = Keyword.get(opts, :max_length, 12)
    map_of(json_key(), json_value(), max_length: max_length)
  end

  def untrusted_param_value do
    one_of([
      string(:printable, max_length: 200),
      integer(),
      boolean(),
      constant(nil),
      list_of(string(:printable, max_length: 40), max_length: 5),
      map_of(json_key(max_length: 12), string(:printable, max_length: 60), max_length: 6)
    ])
  end
end
