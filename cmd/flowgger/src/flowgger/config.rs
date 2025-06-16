use std::fs::File;
use std::io::prelude::*;
use std::io::{Error, ErrorKind};
use std::path::Path;
use toml::Value;

/// [`Configuration`][] storage for flowgger configs
/// This is a dumb storage, no validation is other that this is parsable toml is performed
/// All validations must be implemented on the functionality module level
///
/// [`Configuration`]: https://github.com/jedisct1/flowgger/wiki/Configuration
#[derive(Clone)]
pub struct Config {
    #[cfg(not(test))]
    config: Value,
    #[cfg(test)]
    pub config: Value,
}

impl Config {
    /// Constructor for the Config object from a file source
    /// Ingest path for toml configuration file in toml format and parse it using the
    /// `Config::from_string` method
    /// This does not make any validation on the content of the configuration file
    ///
    /// # Parameters
    ///
    /// - `path`: path to existing, readable and valid configuration file in toml format
    ///
    /// # Type parameters
    ///
    /// - `P`: is an implicit converion to [`std::path::Path`][https://doc.rust-lang.org/std/path/struct.Path.html]
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    ///
    /// - `Ok`: Containing the Config object
    /// - `Err`: if the file doesn't exist, is not readable, cannot be parsed into a string or is
    /// not valid [`TOML`][https://github.com/toml-lang/toml#user-content-array]
    ///
    /// # Errors
    ///
    /// This function will return error if the file does not exists,is unreadbale, or is not valid
    /// toml format
    pub fn from_path<P: AsRef<Path>>(path: P) -> Result<Config, Error> {
        let mut fd = File::open(path)?;
        let mut toml = String::new();
        fd.read_to_string(&mut toml)?;
        Config::from_string(&toml)
    }

    /// Constructor for the Config object from a string
    /// This does not make any validation on the content of the configuration file
    ///
    /// # Parameters
    ///
    /// - `toml`: str containing a valid toml confiration in string format
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    ///
    /// - `Ok`: Containing the Config object
    /// - `Err`: if the parameter string is is not valid [`TOML`][https://github.com/toml-lang/toml#user-content-array]
    ///
    ///
    /// # Errors
    ///
    /// - `InvalidData: Syntax error - config file is not valid TOML`: will be returned if the toml
    /// string is not valid toml and cannot be parsed
    ///
    pub fn from_string(toml: &str) -> Result<Config, Error> {
        let config: Value = match toml.parse() {
            Ok(config) => config,
            Err(_) => {
                return Err(Error::new(
                    ErrorKind::InvalidData,
                    "Syntax error - config file is not valid TOML",
                ))
            }
        };
        Ok(Config { config })
    }

    /// Lookup a toml prefix from a string in dotted format
    ///
    /// # Paramters
    /// - `path`: a dotted string like 'input.type`
    ///
    /// # Returns
    /// Return an `Option` which is:
    ///
    /// - `Some`: Containing a toml::Value if the path pointed to an existing Value
    /// - `None`: if the path is not associated to any Value in the configuration
    pub fn lookup<'a>(&'a self, path: &'a str) -> Option<&'a Value> {
        let path_parts: Vec<&str> = path.split('.').collect();
        let mut current_value = &(self.config);
        for index in path_parts.iter() {
            if current_value.is_table() {
                current_value = match current_value.get(index) {
                    Some(value) => value,
                    None => return None,
                };
            }
        }
        Some(&current_value)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_config_from_string() {
        let section_name = "section";
        let field_name = "field";
        let field_value = "This is only a test";
        let config = Config::from_string(
            format!("[{}]\n{} = \"{}\"", section_name, field_name, field_value).as_str(),
        )
        .unwrap();
        assert_eq!(
            config.config[section_name][field_name].as_str().unwrap(),
            field_value
        );
        assert_eq!(
            config
                .lookup(&[section_name, field_name].join("."))
                .unwrap()
                .as_str(),
            Some(field_value)
        );
        assert!(config.lookup("non_existing_section").is_none());
    }

    #[test]
    #[should_panic(expected = "Syntax error - config file is not valid TOML")]
    fn test_config_from_string_bad() {
        let _config = Config::from_string("[section]\n= \"no key\"").unwrap();
    }

    #[test]
    fn test_config_from_path() {
        let config = Config::from_path("tests/resources/good_config.toml").unwrap();
        assert_eq!(
            config
                .lookup("this_is_a_valid_section.this_is_valid_field")
                .unwrap()
                .as_str(),
            Some("this is a valid value")
        );
        assert_eq!(
            config
                .lookup("this_is_a_valid_section.with_a_valid_subsection.this_is_another_valid_field.dotted")
                .unwrap()
                .as_str(),
            Some("with a valid value")
        );
        assert_eq!(
            config
                .lookup("this_is_a_valid_section.with_a_valid_subsection.integer_value")
                .unwrap()
                .as_integer(),
            Some(42)
        );
        assert!(config.lookup("non_existing_section").is_none());
    }

    #[test]
    #[should_panic(expected = "Syntax error - config file is not valid TOML")]
    fn test_config_from_path_bad_format() {
        let _config = Config::from_path("tests/resources/bad_config.toml").unwrap();
    }

    #[test]
    #[should_panic(
        expected = "Os { code: 2, kind: NotFound, message: \"No such file or directory\" }"
    )]
    fn test_config_from_path_no_file() {
        let _config = Config::from_path("doesnotexist.toml").unwrap();
    }

    #[test]
    fn test_config_clone() {
        let config = Config::from_path("tests/resources/good_config.toml").unwrap();
        let _config_cloned = config.clone();
        assert_eq!(config.config, _config_cloned.config);
    }
}
