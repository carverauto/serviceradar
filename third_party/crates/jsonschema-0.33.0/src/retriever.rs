//! Logic for retrieving external resources.
use referencing::{Retrieve, Uri};
use serde_json::Value;

pub(crate) struct DefaultRetriever;

impl Retrieve for DefaultRetriever {
    #[allow(unused)]
    fn retrieve(
        &self,
        uri: &Uri<String>,
    ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        #[cfg(target_arch = "wasm32")]
        {
            Err("External references are not supported in WASM".into())
        }
        #[cfg(not(target_arch = "wasm32"))]
        match uri.scheme().as_str() {
            "http" | "https" => {
                #[cfg(any(feature = "resolve-http", test))]
                {
                    Ok(reqwest::blocking::get(uri.as_str())?.json()?)
                }
                #[cfg(not(any(feature = "resolve-http", test)))]
                Err("`resolve-http` feature or a custom resolver is required to resolve external schemas via HTTP".into())
            }
            "file" => {
                #[cfg(any(feature = "resolve-file", test))]
                {
                    let path = uri.path().as_str();
                    let path = {
                        #[cfg(windows)]
                        {
                            // Remove the leading slash and replace forward slashes with backslashes
                            let path = path.trim_start_matches('/').replace('/', "\\");
                            std::path::PathBuf::from(path)
                        }
                        #[cfg(not(windows))]
                        {
                            std::path::PathBuf::from(path)
                        }
                    };
                    let file = std::fs::File::open(path)?;
                    Ok(serde_json::from_reader(file)?)
                }
                #[cfg(not(any(feature = "resolve-file", test)))]
                {
                    Err("`resolve-file` feature or a custom resolver is required to resolve external schemas via files".into())
                }
            }
            scheme => Err(format!("Unknown scheme {scheme}").into()),
        }
    }
}

#[cfg(feature = "resolve-async")]
#[async_trait::async_trait]
impl referencing::AsyncRetrieve for DefaultRetriever {
    async fn retrieve(
        &self,
        uri: &Uri<String>,
    ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        #[cfg(target_arch = "wasm32")]
        {
            Err("External references are not supported in WASM".into())
        }
        #[cfg(not(target_arch = "wasm32"))]
        match uri.scheme().as_str() {
            "http" | "https" => {
                #[cfg(any(feature = "resolve-http", test))]
                {
                    Ok(reqwest::get(uri.as_str()).await?.json().await?)
                }
                #[cfg(not(any(feature = "resolve-http", test)))]
                Err("`resolve-http` feature or a custom resolver is required to resolve external schemas via HTTP".into())
            }
            "file" => {
                #[cfg(any(feature = "resolve-file", test))]
                {
                    // File operations are blocking, so we use tokio's spawn_blocking
                    let path = uri.path().as_str().to_string();
                    let contents = tokio::task::spawn_blocking(
                        move || -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
                            let path = {
                                #[cfg(windows)]
                                {
                                    let path = path.trim_start_matches('/').replace('/', "\\");
                                    std::path::PathBuf::from(path)
                                }
                                #[cfg(not(windows))]
                                {
                                    std::path::PathBuf::from(path)
                                }
                            };
                            let file = std::fs::File::open(path)?;
                            Ok(serde_json::from_reader(file)?)
                        },
                    )
                    .await??;
                    Ok(contents)
                }
                #[cfg(not(any(feature = "resolve-file", test)))]
                {
                    Err("`resolve-file` feature or a custom resolver is required to resolve external schemas via files".into())
                }
            }
            scheme => Err(format!("Unknown scheme {scheme}").into()),
        }
    }
}

#[cfg(all(test, not(target_arch = "wasm32")))]
fn path_to_uri(path: &std::path::Path) -> String {
    use percent_encoding::{percent_encode, AsciiSet, CONTROLS};

    let mut result = "file://".to_owned();
    const SEGMENT: &AsciiSet = &CONTROLS
        .add(b' ')
        .add(b'"')
        .add(b'<')
        .add(b'>')
        .add(b'`')
        .add(b'#')
        .add(b'?')
        .add(b'{')
        .add(b'}')
        .add(b'/')
        .add(b'%');

    #[cfg(not(target_os = "windows"))]
    {
        use std::os::unix::ffi::OsStrExt;

        const CUSTOM_SEGMENT: &AsciiSet = &SEGMENT.add(b'\\');
        for component in path.components().skip(1) {
            result.push('/');
            result.extend(percent_encode(
                component.as_os_str().as_bytes(),
                CUSTOM_SEGMENT,
            ));
        }
    }
    #[cfg(target_os = "windows")]
    {
        use std::path::{Component, Prefix};
        let mut components = path.components();

        match components.next() {
            Some(Component::Prefix(ref p)) => match p.kind() {
                Prefix::Disk(letter) | Prefix::VerbatimDisk(letter) => {
                    result.push('/');
                    result.push(letter as char);
                    result.push(':');
                }
                _ => panic!("Unexpected path"),
            },
            _ => panic!("Unexpected path"),
        }

        for component in components {
            if component == Component::RootDir {
                continue;
            }

            let component = component.as_os_str().to_str().expect("Unexpected path");

            result.push('/');
            result.extend(percent_encode(component.as_bytes(), SEGMENT));
        }
    }
    result
}

#[cfg(test)]
mod tests {
    #[cfg(not(target_arch = "wasm32"))]
    use super::path_to_uri;
    use serde_json::json;
    #[cfg(not(target_arch = "wasm32"))]
    use std::io::Write;

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn test_retrieve_from_file() {
        let mut temp_file = tempfile::NamedTempFile::new().expect("Failed to create temp file");
        let external_schema = json!({
            "type": "object",
            "properties": {
                "name": { "type": "string" }
            },
            "required": ["name"]
        });
        write!(temp_file, "{external_schema}").expect("Failed to write to temp file");

        let uri = path_to_uri(temp_file.path());

        let schema = json!({
            "type": "object",
            "properties": {
                "user": { "$ref": uri }
            }
        });

        let validator = crate::validator_for(&schema).expect("Schema compilation failed");

        let valid = json!({"user": {"name": "John Doe"}});
        assert!(validator.is_valid(&valid));

        let invalid = json!({"user": {}});
        assert!(!validator.is_valid(&invalid));
    }

    #[test]
    fn test_unknown_scheme() {
        let schema = json!({
            "type": "object",
            "properties": {
                "test": { "$ref": "unknown-schema://test" }
            }
        });

        let result = crate::validator_for(&schema);

        assert!(result.is_err());
        let error = result.unwrap_err().to_string();
        #[cfg(not(target_arch = "wasm32"))]
        assert!(error.contains("Unknown scheme"));
        #[cfg(target_arch = "wasm32")]
        assert!(error.contains("External references are not supported in WASM"));
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn create_temp_file(dir: &tempfile::TempDir, name: &str, content: &str) -> String {
        let file_path = dir.path().join(name);
        std::fs::write(&file_path, content).unwrap();
        file_path.to_str().unwrap().to_string()
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn test_with_base_uri_resolution() {
        let dir = tempfile::tempdir().unwrap();

        let b_schema = r#"
        {
            "type": "object",
            "properties": {
                "age": { "type": "number" }
            },
            "required": ["age"]
        }
        "#;
        let _b_path = create_temp_file(&dir, "b.json", b_schema);

        let a_schema = r#"
        {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$ref": "./b.json",
            "type": "object"
        }
        "#;
        let a_path = create_temp_file(&dir, "a.json", a_schema);

        let valid_instance = serde_json::json!({ "age": 30 });

        let schema_str = std::fs::read_to_string(&a_path).unwrap();
        let schema_json: serde_json::Value = serde_json::from_str(&schema_str).unwrap();

        let base_uri = path_to_uri(dir.path());
        let validator = crate::options()
            .with_base_uri(format!("{base_uri}/"))
            .build(&schema_json)
            .expect("Schema compilation failed");

        assert!(validator.is_valid(&valid_instance));

        let invalid_instance = serde_json::json!({ "age": "thirty" });
        assert!(!validator.is_valid(&invalid_instance));
    }
}

#[cfg(all(test, feature = "resolve-async", not(target_arch = "wasm32")))]
mod async_tests {
    use super::*;
    use crate::Registry;
    use serde_json::json;
    use std::io::Write;

    #[tokio::test]
    async fn test_async_retrieve_from_file() {
        let mut temp_file = tempfile::NamedTempFile::new().expect("Failed to create temp file");
        let external_schema = json!({
            "type": "object",
            "properties": {
                "name": { "type": "string" }
            },
            "required": ["name"]
        });
        write!(temp_file, "{external_schema}").expect("Failed to write to temp file");

        let uri = path_to_uri(temp_file.path());

        let schema = json!({
            "type": "object",
            "properties": {
                "user": { "$ref": uri }
            }
        });

        // Create registry with default async retriever
        let registry = Registry::options()
            .async_retriever(DefaultRetriever)
            .build([(
                "http://example.com/schema",
                crate::Draft::Draft202012.create_resource(schema.clone()),
            )])
            .await
            .expect("Registry creation failed");

        let validator = crate::options()
            .with_registry(registry)
            .build(&schema)
            .expect("Invalid schema");

        let valid = json!({"user": {"name": "John Doe"}});
        assert!(validator.is_valid(&valid));

        let invalid = json!({"user": {}});
        assert!(!validator.is_valid(&invalid));
    }

    #[tokio::test]
    async fn test_async_unknown_scheme() {
        let schema = json!({
            "type": "object",
            "properties": {
                "test": { "$ref": "unknown-schema://test" }
            }
        });

        let result = Registry::options()
            .async_retriever(DefaultRetriever)
            .build([(
                "http://example.com/schema",
                crate::Draft::Draft202012.create_resource(schema),
            )])
            .await;

        assert!(result.is_err());
        let error = result.unwrap_err().to_string();
        assert!(error.contains("Unknown scheme"));
    }

    #[tokio::test]
    async fn test_async_concurrent_retrievals() {
        let mut temp_files = vec![];
        let mut uris = vec![];

        // Create multiple temp files with different schemas
        for i in 0..3 {
            let mut temp_file = tempfile::NamedTempFile::new().expect("Failed to create temp file");
            let schema = json!({
                "type": "object",
                "properties": {
                    "field": { "type": "string", "minLength": i }
                }
            });
            write!(temp_file, "{schema}").expect("Failed to write to temp file");
            uris.push(path_to_uri(temp_file.path()));
            temp_files.push(temp_file);
        }

        // Create a schema that references all temp files
        let schema = json!({
            "type": "object",
            "properties": {
                "obj1": { "$ref": uris[0] },
                "obj2": { "$ref": uris[1] },
                "obj3": { "$ref": uris[2] }
            }
        });

        let registry = Registry::options()
            .async_retriever(DefaultRetriever)
            .build([(
                "http://example.com/schema",
                crate::Draft::Draft202012.create_resource(schema.clone()),
            )])
            .await
            .expect("Registry creation failed");

        let validator = crate::options()
            .with_registry(registry)
            .build(&schema)
            .expect("Invalid schema");

        let valid = json!({
            "obj1": { "field": "" },      // minLength: 0
            "obj2": { "field": "a" },     // minLength: 1
            "obj3": { "field": "ab" }     // minLength: 2
        });
        assert!(validator.is_valid(&valid));

        // Test invalid data
        let invalid = json!({
            "obj1": { "field": "" },
            "obj2": { "field": "" },      // should be at least 1 char
            "obj3": { "field": "a" }      // should be at least 2 chars
        });
        assert!(!validator.is_valid(&invalid));
    }
}
