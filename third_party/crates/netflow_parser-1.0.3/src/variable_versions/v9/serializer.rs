//! V9 binary serialization — `to_be_bytes()` and flowset body helpers.
//!
//! Type definitions live in the parent `v9` module (`mod.rs`).

use super::{
    Data, FlowSetBody, OptionsData, OptionsTemplates, ScopeDataField, Templates, V9,
    calculate_padding,
};

impl V9 {
    /// Serialize Template flowset body to bytes
    fn serialize_template_body(templates: &Templates) -> Vec<u8> {
        let mut result = Vec::new();
        for template in templates.templates.iter() {
            result.extend_from_slice(&template.template_id.to_be_bytes());
            result.extend_from_slice(&template.field_count.to_be_bytes());
            for field in template.fields.iter() {
                result.extend_from_slice(&field.field_type_number.to_be_bytes());
                result.extend_from_slice(&field.field_length.to_be_bytes());
            }
        }

        let content_len = result.len();
        // Auto-calculate padding if not provided (for manually created packets)
        let padding = if templates.padding.is_empty() {
            calculate_padding(content_len)
        } else {
            &templates.padding[..]
        };
        result.extend_from_slice(padding);
        result
    }

    /// Serialize OptionsTemplate flowset body to bytes
    fn serialize_options_template_body(options_templates: &OptionsTemplates) -> Vec<u8> {
        let mut result = Vec::new();
        for template in options_templates.templates.iter() {
            result.extend_from_slice(&template.template_id.to_be_bytes());
            result.extend_from_slice(&template.options_scope_length.to_be_bytes());
            result.extend_from_slice(&template.options_length.to_be_bytes());
            for field in template.scope_fields.iter() {
                result.extend_from_slice(&field.field_type_number.to_be_bytes());
                result.extend_from_slice(&field.field_length.to_be_bytes());
            }
            for field in template.option_fields.iter() {
                result.extend_from_slice(&field.field_type_number.to_be_bytes());
                result.extend_from_slice(&field.field_length.to_be_bytes());
            }
        }

        let content_len = result.len();
        // Auto-calculate padding if not provided (for manually created packets)
        let padding = if options_templates.padding.is_empty() {
            calculate_padding(content_len)
        } else {
            &options_templates.padding[..]
        };
        result.extend_from_slice(padding);
        result
    }

    /// Serialize Data flowset body to bytes
    fn serialize_data_body(data: &Data) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let mut result = Vec::new();
        for data_field in data.fields.iter() {
            for (_, field_value) in data_field.iter() {
                field_value.write_be_bytes(&mut result)?;
            }
        }

        let content_len = result.len();
        // Auto-calculate padding if not provided (for manually created packets)
        let padding = if data.padding.is_empty() {
            calculate_padding(content_len)
        } else {
            &data.padding[..]
        };
        result.extend_from_slice(padding);
        Ok(result)
    }

    /// Serialize OptionsData flowset body to bytes
    fn serialize_options_data_body(
        options_data: &OptionsData,
    ) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let mut result = Vec::new();
        for options_data_field in options_data.fields.iter() {
            for field in options_data_field.scope_fields.iter() {
                match field {
                    ScopeDataField::System(value)
                    | ScopeDataField::Interface(value)
                    | ScopeDataField::LineCard(value)
                    | ScopeDataField::NetFlowCache(value)
                    | ScopeDataField::Template(value)
                    | ScopeDataField::Unknown(_, value) => {
                        result.extend_from_slice(value);
                    }
                }
            }
            for (_field_type, field_value) in options_data_field.options_fields.iter() {
                field_value.write_be_bytes(&mut result)?;
            }
        }

        let content_len = result.len();
        result.extend_from_slice(calculate_padding(content_len));
        Ok(result)
    }

    /// Convert the V9 struct to a `Vec<u8>` of bytes in big-endian order for exporting.
    ///
    /// `NoTemplate` flowsets are omitted from the output, and `header.count`
    /// is recomputed to match the number of actually-serialized flowsets.
    pub fn to_be_bytes(&self) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let mut result = Vec::new();

        // V9 header: version(2) + count(2) + sys_up_time(4) + unix_secs(4) + seq(4) + source_id(4) = 20 bytes
        result.extend_from_slice(&self.header.version.to_be_bytes());
        result.extend_from_slice(&[0u8; 2]); // placeholder for count
        result.extend_from_slice(&self.header.sys_up_time.to_be_bytes());
        result.extend_from_slice(&self.header.unix_secs.to_be_bytes());
        result.extend_from_slice(&self.header.sequence_number.to_be_bytes());
        result.extend_from_slice(&self.header.source_id.to_be_bytes());

        let mut emitted_count: u16 = 0;
        for set in self.flowsets.iter() {
            let body_bytes = match &set.body {
                FlowSetBody::Template(t) => Self::serialize_template_body(t),
                FlowSetBody::OptionsTemplate(o) => Self::serialize_options_template_body(o),
                FlowSetBody::Data(d) => Self::serialize_data_body(d)?,
                FlowSetBody::OptionsData(o) => Self::serialize_options_data_body(o)?,
                FlowSetBody::NoTemplate(_) | FlowSetBody::Empty => continue,
            };
            // Compute flowset length from actual serialized body instead
            // of trusting set.header.length, which can be stale when
            // padding was auto-calculated or the body was modified.
            let flowset_length: u16 = (body_bytes.len() + 4).try_into().map_err(|_| {
                format!(
                    "V9 flowset body size {} exceeds u16::MAX - 4",
                    body_bytes.len()
                )
            })?;
            result.extend_from_slice(&set.header.flowset_id.to_be_bytes());
            result.extend_from_slice(&flowset_length.to_be_bytes());
            result.extend_from_slice(&body_bytes);
            emitted_count = emitted_count
                .checked_add(1)
                .ok_or_else(|| format!("V9 flowset count exceeds u16::MAX ({})", u16::MAX))?;
        }

        // Patch header.count with actual number of serialized flowsets
        result[2..4].copy_from_slice(&emitted_count.to_be_bytes());

        Ok(result)
    }
}
