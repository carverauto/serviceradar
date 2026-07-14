//! IPFIX binary serialization — `to_be_bytes()` and flowset body helpers.
//!
//! Type definitions live in the parent `ipfix` module (`mod.rs`).

use super::{FlowSetBody, IPFix, TemplateField, calculate_padding};
use crate::variable_versions::v9::ScopeDataField as V9ScopeDataField;

/// Write an RFC 7011 Section 7 variable-length encoding prefix.
///
/// - If `value_len < 255`: writes a single byte with the length.
/// - If `value_len >= 255`: writes `0xFF` followed by the length as a big-endian `u16`.
///
/// Returns an error if `value_len` exceeds `u16::MAX`.
fn write_varlen_prefix(
    buf: &mut Vec<u8>,
    value_len: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    if value_len == 0 {
        return Err(
            "IPFIX variable-length field cannot have zero length (RFC 7011 Section 7)".into(),
        );
    }
    if value_len < 255 {
        buf.push(value_len as u8);
    } else {
        let len_u16: u16 = value_len.try_into().map_err(|_| {
            format!(
                "IPFIX variable-length field size {} exceeds u16::MAX",
                value_len
            )
        })?;
        buf.push(255);
        buf.extend_from_slice(&len_u16.to_be_bytes());
    }
    Ok(())
}

/// Serialize IPFIX or V9 data fields into `result`, emitting RFC 7011
/// variable-length prefixes for any field whose template length is 65535.
fn serialize_data_fields(
    result: &mut Vec<u8>,
    fields: &[Vec<(
        impl std::fmt::Debug,
        crate::variable_versions::field_value::FieldValue,
    )>],
    template_field_lengths: &[u16],
) -> Result<(), Box<dyn std::error::Error>> {
    // If template_field_lengths is empty but records have fields, we cannot
    // determine which fields are variable-length.  This is safe for fixed-length
    // templates (the common case) but would silently omit the variable-length
    // prefix for varlen fields.  Log-level diagnostics are impractical here,
    // so we proceed — callers constructing Data with variable-length fields
    // must populate template_field_lengths via parse or explicit construction.
    for item in fields.iter() {
        for (idx, (_, v)) in item.iter().enumerate() {
            let is_varlen = template_field_lengths
                .get(idx)
                .is_some_and(|&len| len == 65535);
            if is_varlen {
                write_varlen_prefix(result, v.byte_len())?;
            }
            v.write_be_bytes(result)?;
        }
    }
    Ok(())
}

impl IPFix {
    /// Write an IPFIX template field, restoring the enterprise bit if needed.
    fn write_ipfix_template_field(buf: &mut Vec<u8>, field: &TemplateField) {
        let type_number = if field.enterprise_number.is_some() {
            field.field_type_number | 0x8000
        } else {
            field.field_type_number
        };
        buf.extend_from_slice(&type_number.to_be_bytes());
        buf.extend_from_slice(&field.field_length.to_be_bytes());
        if let Some(enterprise) = field.enterprise_number {
            buf.extend_from_slice(&enterprise.to_be_bytes());
        }
    }

    /// Serialize FlowSetBody to bytes
    fn serialize_flowset_body(
        body: &FlowSetBody,
    ) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        match body {
            FlowSetBody::Template(template) => {
                let mut result = Vec::new();
                result.extend_from_slice(&template.template_id.to_be_bytes());
                result.extend_from_slice(&template.field_count.to_be_bytes());
                for field in template.fields.iter() {
                    Self::write_ipfix_template_field(&mut result, field);
                }
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::Templates(templates) => {
                let mut result = Vec::new();
                for template in templates.iter() {
                    result.extend_from_slice(&template.template_id.to_be_bytes());
                    result.extend_from_slice(&template.field_count.to_be_bytes());
                    for field in template.fields.iter() {
                        Self::write_ipfix_template_field(&mut result, field);
                    }
                }
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::V9Template(template) => {
                let mut result = Vec::new();
                result.extend_from_slice(&template.template_id.to_be_bytes());
                result.extend_from_slice(&template.field_count.to_be_bytes());
                for field in template.fields.iter() {
                    result.extend_from_slice(&field.field_type_number.to_be_bytes());
                    result.extend_from_slice(&field.field_length.to_be_bytes());
                }
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::OptionsTemplate(options_template) => {
                let mut result = Vec::new();
                result.extend_from_slice(&options_template.template_id.to_be_bytes());
                result.extend_from_slice(&options_template.field_count.to_be_bytes());
                result.extend_from_slice(&options_template.scope_field_count.to_be_bytes());
                for field in options_template.fields.iter() {
                    Self::write_ipfix_template_field(&mut result, field);
                }
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::V9OptionsTemplate(template) => {
                let mut result = Vec::new();
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
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::V9Templates(templates) => {
                let mut result = Vec::new();
                for template in templates.iter() {
                    result.extend_from_slice(&template.template_id.to_be_bytes());
                    result.extend_from_slice(&template.field_count.to_be_bytes());
                    for field in template.fields.iter() {
                        result.extend_from_slice(&field.field_type_number.to_be_bytes());
                        result.extend_from_slice(&field.field_length.to_be_bytes());
                    }
                }
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::OptionsTemplates(templates) => {
                let mut result = Vec::new();
                for template in templates.iter() {
                    result.extend_from_slice(&template.template_id.to_be_bytes());
                    result.extend_from_slice(&template.field_count.to_be_bytes());
                    result.extend_from_slice(&template.scope_field_count.to_be_bytes());
                    for field in template.fields.iter() {
                        Self::write_ipfix_template_field(&mut result, field);
                    }
                }
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::V9OptionsTemplates(templates) => {
                let mut result = Vec::new();
                for template in templates.iter() {
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
                result.extend_from_slice(calculate_padding(result.len()));
                Ok(result)
            }
            FlowSetBody::Data(data) => {
                let mut result = Vec::new();
                serialize_data_fields(&mut result, &data.fields, &data.template_field_lengths)?;
                let content_len = result.len();
                let padding = if data.padding.is_empty() {
                    calculate_padding(content_len)
                } else {
                    &data.padding[..]
                };
                result.extend_from_slice(padding);
                Ok(result)
            }
            FlowSetBody::OptionsData(data) => {
                let mut result = Vec::new();
                serialize_data_fields(&mut result, &data.fields, &data.template_field_lengths)?;
                let content_len = result.len();
                let padding = if data.padding.is_empty() {
                    calculate_padding(content_len)
                } else {
                    &data.padding[..]
                };
                result.extend_from_slice(padding);
                Ok(result)
            }
            FlowSetBody::V9Data(data) => {
                let mut result = Vec::new();
                for item in data.fields.iter() {
                    for (_, v) in item.iter() {
                        v.write_be_bytes(&mut result)?;
                    }
                }
                let content_len = result.len();
                let padding = if data.padding.is_empty() {
                    calculate_padding(content_len)
                } else {
                    &data.padding[..]
                };
                result.extend_from_slice(padding);
                Ok(result)
            }
            FlowSetBody::V9OptionsData(options_data) => {
                let mut result = Vec::new();
                for options_data_field in options_data.fields.iter() {
                    for field in options_data_field.scope_fields.iter() {
                        match field {
                            V9ScopeDataField::System(value)
                            | V9ScopeDataField::Interface(value)
                            | V9ScopeDataField::LineCard(value)
                            | V9ScopeDataField::NetFlowCache(value)
                            | V9ScopeDataField::Template(value)
                            | V9ScopeDataField::Unknown(_, value) => {
                                result.extend_from_slice(value)
                            }
                        }
                    }
                    for (_field_type, field_value) in options_data_field.options_fields.iter() {
                        field_value.write_be_bytes(&mut result)?;
                    }
                }
                let content_len = result.len();
                // V9 OptionsData has no padding field, so always calculate
                result.extend_from_slice(calculate_padding(content_len));
                Ok(result)
            }
            FlowSetBody::NoTemplate(_) | FlowSetBody::Empty => {
                Err("serialize_flowset_body called with NoTemplate or Empty variant".into())
            }
        }
    }

    /// Convert the IPFix to a `Vec<u8>` of bytes in big-endian order for exporting.
    ///
    /// `NoTemplate` and `Empty` flowsets are omitted from the output, and
    /// `header.length` is recomputed to match the actual serialized size.
    pub fn to_be_bytes(&self) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let mut result = Vec::new();

        // IPFIX header: version(2) + length(2) + export_time(4) + seq(4) + obs_domain(4) = 16 bytes
        result.extend_from_slice(&self.header.version.to_be_bytes());
        result.extend_from_slice(&[0u8; 2]); // placeholder for length
        result.extend_from_slice(&self.header.export_time.to_be_bytes());
        result.extend_from_slice(&self.header.sequence_number.to_be_bytes());
        result.extend_from_slice(&self.header.observation_domain_id.to_be_bytes());

        for flow in &self.flowsets {
            if matches!(&flow.body, FlowSetBody::NoTemplate(_) | FlowSetBody::Empty) {
                continue;
            }

            let flowset_bytes = Self::serialize_flowset_body(&flow.body)?;

            // Compute set length from actual serialized body instead of
            // trusting flow.header.length, which can be stale when
            // padding was auto-calculated or the body was modified.
            let set_length: u16 = (flowset_bytes.len() + 4).try_into().map_err(|_| {
                format!(
                    "IPFIX set body size {} exceeds u16::MAX - 4",
                    flowset_bytes.len()
                )
            })?;
            result.extend_from_slice(&flow.header.header_id.to_be_bytes());
            result.extend_from_slice(&set_length.to_be_bytes());
            result.extend_from_slice(&flowset_bytes);
        }

        // Patch header.length with actual serialized size
        let total_length: u16 = result.len().try_into().map_err(|_| {
            format!(
                "IPFIX message size {} exceeds u16::MAX ({})",
                result.len(),
                u16::MAX
            )
        })?;
        result[2..4].copy_from_slice(&total_length.to_be_bytes());

        Ok(result)
    }
}
