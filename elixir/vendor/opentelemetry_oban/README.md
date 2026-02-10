# OpentelemetryOban

OpentelemetryOban uses [telemetry](https://hexdocs.pm/telemetry/) handlers to
create `OpenTelemetry` spans from Oban events.

## Installation

The package can be installed by adding `opentelemetry_oban` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:opentelemetry_oban, "~> 1.0"}
  ]
end
```

In your application start:

```elixir
    def start(_type, _args) do
      OpentelemetryOban.setup()

      # ...
    end
```

## Usage

By default a new trace is automatically started when a job is processed.

To also record a span when a job is created and to link traces together
`Oban.insert/2` has to be replaced by `OpentelemetryOban.insert/2`.

Before:

```elixir
  %{id: 1, in_the: "business", of_doing: "business"}
  |> MyApp.Business.new()
  |> Oban.insert()
```

After:

```elixir
  %{id: 1, in_the: "business", of_doing: "business"}
  |> MyApp.Business.new()
  |> OpentelemetryOban.insert()
```

Oban also supports inserting jobs using `Oban.insert/4` and `Oban.insert_all/4`.
These are currently not supported by OpentelemetryOban and are just proxied through to Oban.
