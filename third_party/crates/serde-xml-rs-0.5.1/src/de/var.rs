use std::io::Read;

use serde::de::{self, Deserializer as SerdeDeserializer, IntoDeserializer};
use xml::name::OwnedName;
use xml::reader::XmlEvent;

use crate::de::Deserializer;
use crate::error::{Error, Result};
use crate::expect;

use super::buffer::BufferedXmlReader;

pub struct EnumAccess<'a, R: Read, B: BufferedXmlReader<R>> {
    de: &'a mut Deserializer<R, B>,
}

impl<'a, R: 'a + Read, B: BufferedXmlReader<R>> EnumAccess<'a, R, B> {
    pub fn new(de: &'a mut Deserializer<R, B>) -> Self {
        EnumAccess { de: de }
    }
}

impl<'de, 'a, R: 'a + Read, B: BufferedXmlReader<R>> de::EnumAccess<'de> for EnumAccess<'a, R, B> {
    type Error = Error;
    type Variant = VariantAccess<'a, R, B>;

    fn variant_seed<V: de::DeserializeSeed<'de>>(
        self,
        seed: V,
    ) -> Result<(V::Value, VariantAccess<'a, R, B>)> {
        let name = expect!(
            self.de.peek()?,

            &XmlEvent::Characters(ref name) |
            &XmlEvent::StartElement { name: OwnedName { local_name: ref name, .. }, .. } => {
                seed.deserialize(name.as_str().into_deserializer())
            }
        )?;
        self.de.set_map_value();
        Ok((name, VariantAccess::new(self.de)))
    }
}

pub struct VariantAccess<'a, R: Read, B: BufferedXmlReader<R>> {
    de: &'a mut Deserializer<R, B>,
}

impl<'a, R: 'a + Read, B: BufferedXmlReader<R>> VariantAccess<'a, R, B> {
    pub fn new(de: &'a mut Deserializer<R, B>) -> Self {
        VariantAccess { de: de }
    }
}

impl<'de, 'a, R: 'a + Read, B: BufferedXmlReader<R>> de::VariantAccess<'de>
    for VariantAccess<'a, R, B>
{
    type Error = Error;

    fn unit_variant(self) -> Result<()> {
        self.de.unset_map_value();
        match self.de.next()? {
            XmlEvent::StartElement {
                name, attributes, ..
            } => {
                if attributes.is_empty() {
                    self.de.expect_end_element(name)
                } else {
                    Err(de::Error::invalid_length(attributes.len(), &"0"))
                }
            }
            XmlEvent::Characters(_) => Ok(()),
            _ => unreachable!(),
        }
    }

    fn newtype_variant_seed<T: de::DeserializeSeed<'de>>(self, seed: T) -> Result<T::Value> {
        seed.deserialize(&mut *self.de)
    }

    fn tuple_variant<V: de::Visitor<'de>>(self, len: usize, visitor: V) -> Result<V::Value> {
        self.de.deserialize_tuple(len, visitor)
    }

    fn struct_variant<V: de::Visitor<'de>>(
        self,
        _fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value> {
        self.de.deserialize_map(visitor)
    }
}
