[
  import_deps: [
    :ash,
    :ash_postgres,
    :ash_authentication,
    :ash_oban,
    :ash_state_machine,
    :ash_json_api,
    :ecto,
    :ecto_sql
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
