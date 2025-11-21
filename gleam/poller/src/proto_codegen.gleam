import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import protozoa/internal/codegen
import protozoa/internal/import_resolver
import protozoa/parser
import simplifile
import snag

const proto_input = "proto/monitoring.proto"

const output_dir = "src"

const default_import_paths = ["proto"]

pub fn main() -> Nil {
  io.println("🔄 Generating Gleam bindings from protobuf definitions...")

  case generate_files(proto_input, output_dir, default_import_paths) {
    Ok(files) -> {
      io.println(
        "✅ Successfully generated "
        <> int.to_string(list.length(files))
        <> " file(s):",
      )
      list.each(files, fn(path) { io.println("  - " <> path) })
    }
    Error(error) -> {
      io.println_error("❌ Generation failed: " <> snag.pretty_print(error))
      exit(1)
    }
  }
}

fn generate_files(
  input: String,
  output: String,
  import_paths: List(String),
) -> snag.Result(List(String)) {
  let _ = simplifile.create_directory_all(output)

  use #(_, resolver) <- result.try(resolve_all_imports(input, import_paths))
  let files = import_resolver.get_all_loaded_files(resolver)
  let registry = import_resolver.get_type_registry(resolver)

  io.println("Loaded proto files:")
  list.each(files, fn(entry) {
    let #(path, proto_file) = entry
    let enum_names = proto_file.enums |> list.map(fn(e) { e.name })
    let message_names = proto_file.messages |> list.map(fn(m) { m.name })
    io.println(
      "  - "
      <> path
      <> " ("
      <> int.to_string(list.length(message_names))
      <> " messages, "
      <> int.to_string(list.length(enum_names))
      <> " enums)",
    )
  })

  let paths =
    list.map(files, fn(entry) {
      let #(path, content) = entry
      parser.Path(path, content)
    })

  use generated <- result.try(
    codegen.generate_combined_proto_file(paths, registry, output)
    |> result.map_error(fn(err) { snag.new("Code generation failed: " <> err) }),
  )

  use _ <- result.try(rewrite_generated_files(generated))

  Ok(list.map(generated, fn(entry) { entry.0 }))
}

fn resolve_all_imports(
  input: String,
  import_paths: List(String),
) -> snag.Result(#(parser.ProtoFile, import_resolver.ImportResolver)) {
  let resolver =
    import_resolver.new()
    |> import_resolver.with_search_paths([".", ..import_paths])

  import_resolver.resolve_imports(resolver, input)
  |> result.map_error(fn(err) {
    snag.new(
      "Import resolution failed: " <> import_resolver.describe_error(err),
    )
  })
}

fn rewrite_generated_files(files: List(#(String, String))) -> snag.Result(Nil) {
  case files {
    [] -> Ok(Nil)
    [#(path, _), ..rest] -> {
      use _ <- result.try(rewrite_generated_file(path))
      rewrite_generated_files(rest)
    }
  }
}

fn rewrite_generated_file(path: String) -> snag.Result(Nil) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) {
      snag.new("Failed to read generated file: " <> path)
    }),
  )

  let updated =
    content
    |> string.replace("gleam run -m protozoa", "gleam run -m proto_codegen")

  use _ <- result.try(
    simplifile.write(path, updated)
    |> result.map_error(fn(_) {
      snag.new("Failed to update generated file: " <> path)
    }),
  )

  Ok(Nil)
}

@external(erlang, "erlang", "halt")
fn exit(status: Int) -> Nil
