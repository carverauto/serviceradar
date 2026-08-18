//! Enumerates the schema's leaf field paths from its own descriptor.
//!
//! The meta-rule -- every field carries at least one rule -- needs a list of fields, and the
//! only list that cannot fall behind the schema is the one protoc emits from it. A hand-kept
//! list would be one more place to forget, which is the exact failure the meta-rule catches.

use prost_types::{field_descriptor_proto::Type, DescriptorProto, FileDescriptorSet};

const ROOT: &str = "EnvironmentConfig";

#[derive(Debug)]
pub struct SchemaError(pub String);

fn find<'a>(messages: &'a [DescriptorProto], name: &str) -> Option<&'a DescriptorProto> {
    messages.iter().find(|m| m.name() == name)
}

fn walk(
    messages: &[DescriptorProto],
    message: &DescriptorProto,
    prefix: &str,
    out: &mut Vec<String>,
) -> Result<(), SchemaError> {
    for field in &message.field {
        let path = if prefix.is_empty() {
            field.name().to_string()
        } else {
            format!("{prefix}.{}", field.name())
        };

        if field.r#type() == Type::Message {
            // type_name is fully qualified (".serviceradar.config.v1.DatabaseConfig").
            let leaf = field.type_name().rsplit('.').next().unwrap_or_default();
            let nested = find(messages, leaf)
                .ok_or_else(|| SchemaError(format!("{path}: no descriptor for {leaf}")))?;
            walk(messages, nested, &path, out)?;
        } else {
            out.push(path);
        }
    }
    Ok(())
}

/// Every leaf field path reachable from `EnvironmentConfig`, in declaration order.
///
/// Leaves only: a rule constrains a value, and `database` is not a value. Reaching them by
/// recursion rather than by listing the four sections means a new section is covered the moment
/// it is added to the schema.
pub fn leaf_field_paths(descriptor: &FileDescriptorSet) -> Result<Vec<String>, SchemaError> {
    let messages: Vec<DescriptorProto> =
        descriptor.file.iter().flat_map(|f| f.message_type.clone()).collect();
    let root = find(&messages, ROOT)
        .ok_or_else(|| SchemaError(format!("no {ROOT} in the descriptor set")))?;

    let mut out = Vec::new();
    walk(&messages, root, "", &mut out)?;
    Ok(out)
}
