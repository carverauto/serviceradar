use std::{io::Read, marker::PhantomData};

use log::debug;
use serde::de::{self, Unexpected};
use serde::forward_to_deserialize_any;
use xml::name::OwnedName;
use xml::reader::{EventReader, ParserConfig, XmlEvent};

use self::buffer::{BufferedXmlReader, ChildXmlBuffer, RootXmlBuffer};
use self::map::MapAccess;
use self::seq::SeqAccess;
use self::var::EnumAccess;
use crate::error::{Error, Result};
use crate::{debug_expect, expect};

mod buffer;
mod map;
mod seq;
mod var;

/// A convenience method for deserialize some object from a string.
///
/// ```rust
/// # #[macro_use]
/// # extern crate serde_derive;
/// # extern crate serde;
/// # extern crate serde_xml_rs;
/// # use serde_xml_rs::from_str;
/// #[derive(Debug, Deserialize, PartialEq)]
/// struct Item {
///     name: String,
///     source: String,
/// }
/// # fn main() {
/// let s = r##"<item name="hello" source="world.rs" />"##;
/// let item: Item = from_str(s).unwrap();
/// assert_eq!(item, Item { name: "hello".to_string(),source: "world.rs".to_string()});
/// # }
/// ```
pub fn from_str<'de, T: de::Deserialize<'de>>(s: &str) -> Result<T> {
    from_reader(s.as_bytes())
}

/// A convenience method for deserialize some object from a reader.
///
/// ```rust
/// # #[macro_use]
/// # extern crate serde_derive;
/// # extern crate serde;
/// # extern crate serde_xml_rs;
/// # use serde_xml_rs::from_reader;
/// #[derive(Debug, Deserialize, PartialEq)]
/// struct Item {
///     name: String,
///     source: String,
/// }
/// # fn main() {
/// let s = r##"<item name="hello" source="world.rs" />"##;
/// let item: Item = from_reader(s.as_bytes()).unwrap();
/// assert_eq!(item, Item { name: "hello".to_string(),source: "world.rs".to_string()});
/// # }
/// ```
pub fn from_reader<'de, R: Read, T: de::Deserialize<'de>>(reader: R) -> Result<T> {
    T::deserialize(&mut Deserializer::new_from_reader(reader))
}

type RootDeserializer<R> = Deserializer<R, RootXmlBuffer<R>>;
type ChildDeserializer<'parent, R> = Deserializer<R, ChildXmlBuffer<'parent, R>>;

pub struct Deserializer<
    R: Read, // Kept as type param to avoid type signature breaking-change
    B: BufferedXmlReader<R> = RootXmlBuffer<R>,
> {
    /// XML document nested element depth
    depth: usize,
    buffered_reader: B,
    is_map_value: bool,
    non_contiguous_seq_elements: bool,
    marker: PhantomData<R>,
}

impl<'de, R: Read> RootDeserializer<R> {
    pub fn new(reader: EventReader<R>) -> Self {
        let buffered_reader = RootXmlBuffer::new(reader);

        Deserializer {
            buffered_reader,
            depth: 0,
            is_map_value: false,
            non_contiguous_seq_elements: false,
            marker: PhantomData,
        }
    }

    pub fn new_from_reader(reader: R) -> Self {
        let config = ParserConfig::new()
            .trim_whitespace(true)
            .whitespace_to_characters(true)
            .cdata_to_characters(true)
            .ignore_comments(true)
            .coalesce_characters(true);

        Self::new(EventReader::new_with_config(reader, config))
    }

    /// Configures whether the deserializer should search all sibling elements when building a
    /// sequence. Not required if all XML elements for sequences are adjacent. Disabled by
    /// default. Enabling this option may incur additional memory usage.
    ///
    /// ```rust
    /// # #[macro_use]
    /// # extern crate serde_derive;
    /// # extern crate serde;
    /// # extern crate serde_xml_rs;
    /// # use serde_xml_rs::from_reader;
    /// # use serde::Deserialize;
    /// #[derive(Debug, Deserialize, PartialEq)]
    /// struct Foo {
    ///     bar: Vec<usize>,
    ///     baz: String,
    /// }
    /// # fn main() {
    /// let s = r##"
    ///     <foo>
    ///         <bar>1</bar>
    ///         <bar>2</bar>
    ///         <baz>Hello, world</baz>
    ///         <bar>3</bar>
    ///         <bar>4</bar>
    ///     </foo>
    /// "##;
    /// let mut de = serde_xml_rs::Deserializer::new_from_reader(s.as_bytes())
    ///     .non_contiguous_seq_elements(true);
    /// let foo = Foo::deserialize(&mut de).unwrap();
    /// assert_eq!(foo, Foo { bar: vec![1, 2, 3, 4], baz: "Hello, world".to_string()});
    /// # }
    /// ```
    pub fn non_contiguous_seq_elements(mut self, set: bool) -> Self {
        self.non_contiguous_seq_elements = set;
        self
    }
}

impl<'de, R: Read, B: BufferedXmlReader<R>> Deserializer<R, B> {
    fn child<'a>(&'a mut self) -> Deserializer<R, ChildXmlBuffer<'a, R>> {
        let Deserializer {
            buffered_reader,
            depth,
            is_map_value,
            non_contiguous_seq_elements,
            ..
        } = self;

        Deserializer {
            buffered_reader: buffered_reader.child_buffer(),
            depth: *depth,
            is_map_value: *is_map_value,
            non_contiguous_seq_elements: *non_contiguous_seq_elements,
            marker: PhantomData,
        }
    }

    /// Gets the next XML event without advancing the cursor.
    fn peek(&mut self) -> Result<&XmlEvent> {
        let peeked = self.buffered_reader.peek()?;

        debug!("Peeked {:?}", peeked);
        Ok(peeked)
    }

    /// Gets the XML event at the cursor and advances the cursor.
    fn next(&mut self) -> Result<XmlEvent> {
        let next = self.buffered_reader.next()?;

        match next {
            XmlEvent::StartElement { .. } => {
                self.depth += 1;
            }
            XmlEvent::EndElement { .. } => {
                self.depth -= 1;
            }
            _ => {}
        }
        debug!("Fetched {:?}", next);
        Ok(next)
    }

    fn set_map_value(&mut self) {
        self.is_map_value = true;
    }

    pub fn unset_map_value(&mut self) -> bool {
        ::std::mem::replace(&mut self.is_map_value, false)
    }

    /// If `self.is_map_value`: Performs the read operations specified by `f` on the inner content of an XML element.
    /// `f` is expected to consume the entire inner contents of the element. The cursor will be moved to the end of the
    /// element.
    /// If `!self.is_map_value`: `f` will be performed without additional checks/advances for an outer XML element.
    fn read_inner_value<V: de::Visitor<'de>, T, F: FnOnce(&mut Self) -> Result<T>>(
        &mut self,
        f: F,
    ) -> Result<T> {
        if self.unset_map_value() {
            debug_expect!(self.next(), Ok(XmlEvent::StartElement { name, .. }) => {
                let result = f(self)?;
                self.expect_end_element(name)?;
                Ok(result)
            })
        } else {
            f(self)
        }
    }

    fn expect_end_element(&mut self, start_name: OwnedName) -> Result<()> {
        expect!(self.next()?, XmlEvent::EndElement { name, .. } => {
            if name == start_name {
                Ok(())
            } else {
                Err(Error::Custom { field: format!(
                    "End tag </{}> didn't match the start tag <{}>",
                    name.local_name,
                    start_name.local_name
                ) })
            }
        })
    }

    fn prepare_parse_type<V: de::Visitor<'de>>(&mut self) -> Result<String> {
        if let XmlEvent::StartElement { .. } = *self.peek()? {
            self.set_map_value()
        }
        self.read_inner_value::<V, String, _>(|this| {
            if let XmlEvent::EndElement { .. } = *this.peek()? {
                return Err(Error::UnexpectedToken {
                    token: "EndElement".into(),
                    found: "Characters".into(),
                });
            }

            expect!(this.next()?, XmlEvent::Characters(s) => {
                return Ok(s)
            })
        })
    }
}

macro_rules! deserialize_type {
    ($deserialize:ident => $visit:ident) => {
        fn $deserialize<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
            let value = self.prepare_parse_type::<V>()?.parse()?;
            visitor.$visit(value)
        }
    };
}

impl<'de, 'a, R: Read, B: BufferedXmlReader<R>> de::Deserializer<'de>
    for &'a mut Deserializer<R, B>
{
    type Error = Error;

    forward_to_deserialize_any! {
        identifier
    }

    fn deserialize_struct<V: de::Visitor<'de>>(
        self,
        _name: &'static str,
        fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value> {
        self.unset_map_value();
        expect!(self.next()?, XmlEvent::StartElement { name, attributes, .. } => {
            let map_value = visitor.visit_map(MapAccess::new(
                self,
                attributes,
                fields.contains(&"$value")
            ))?;
            self.expect_end_element(name)?;
            Ok(map_value)
        })
    }

    deserialize_type!(deserialize_i8 => visit_i8);
    deserialize_type!(deserialize_i16 => visit_i16);
    deserialize_type!(deserialize_i32 => visit_i32);
    deserialize_type!(deserialize_i64 => visit_i64);
    deserialize_type!(deserialize_u8 => visit_u8);
    deserialize_type!(deserialize_u16 => visit_u16);
    deserialize_type!(deserialize_u32 => visit_u32);
    deserialize_type!(deserialize_u64 => visit_u64);
    deserialize_type!(deserialize_f32 => visit_f32);
    deserialize_type!(deserialize_f64 => visit_f64);

    fn deserialize_bool<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        if let XmlEvent::StartElement { .. } = *self.peek()? {
            self.set_map_value()
        }
        self.read_inner_value::<V, V::Value, _>(|this| {
            if let XmlEvent::EndElement { .. } = *this.peek()? {
                return visitor.visit_bool(false);
            }
            expect!(this.next()?, XmlEvent::Characters(s) => {
                match s.as_str() {
                    "true" | "1" => visitor.visit_bool(true),
                    "false" | "0" => visitor.visit_bool(false),
                    _ => Err(de::Error::invalid_value(Unexpected::Str(&s), &"a boolean")),
                }

            })
        })
    }

    fn deserialize_char<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        self.deserialize_string(visitor)
    }

    fn deserialize_str<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        self.deserialize_string(visitor)
    }

    fn deserialize_bytes<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        self.deserialize_string(visitor)
    }

    fn deserialize_byte_buf<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        self.deserialize_string(visitor)
    }

    fn deserialize_unit<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        if let XmlEvent::StartElement { .. } = *self.peek()? {
            self.set_map_value()
        }
        self.read_inner_value::<V, V::Value, _>(
            |this| expect!(this.peek()?, &XmlEvent::EndElement { .. } => visitor.visit_unit()),
        )
    }

    fn deserialize_unit_struct<V: de::Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value> {
        self.deserialize_unit(visitor)
    }

    fn deserialize_newtype_struct<V: de::Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_tuple_struct<V: de::Visitor<'de>>(
        self,
        _name: &'static str,
        len: usize,
        visitor: V,
    ) -> Result<V::Value> {
        self.deserialize_tuple(len, visitor)
    }

    fn deserialize_tuple<V: de::Visitor<'de>>(self, len: usize, visitor: V) -> Result<V::Value> {
        let child_deserializer = self.child();

        visitor.visit_seq(SeqAccess::new(child_deserializer, Some(len)))
    }

    fn deserialize_enum<V: de::Visitor<'de>>(
        self,
        _name: &'static str,
        _variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value> {
        self.read_inner_value::<V, V::Value, _>(|this| visitor.visit_enum(EnumAccess::new(this)))
    }

    fn deserialize_string<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        if let XmlEvent::StartElement { .. } = *self.peek()? {
            self.set_map_value()
        }
        self.read_inner_value::<V, V::Value, _>(|this| {
            if let XmlEvent::EndElement { .. } = *this.peek()? {
                return visitor.visit_str("");
            }
            expect!(this.next()?, XmlEvent::Characters(s) => {
                visitor.visit_string(s)
            })
        })
    }

    fn deserialize_seq<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        let child_deserializer = self.child();

        visitor.visit_seq(SeqAccess::new(child_deserializer, None))
    }

    fn deserialize_map<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        self.unset_map_value();
        expect!(self.next()?, XmlEvent::StartElement { name, attributes, .. } => {
            let map_value = visitor.visit_map(MapAccess::new(self, attributes, false))?;
            self.expect_end_element(name)?;
            Ok(map_value)
        })
    }

    fn deserialize_option<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        match *self.peek()? {
            XmlEvent::EndElement { .. } => visitor.visit_none(),
            _ => visitor.visit_some(self),
        }
    }

    fn deserialize_ignored_any<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        self.unset_map_value();
        let depth = self.depth;
        loop {
            self.next()?;
            if self.depth == depth {
                break;
            }
        }
        visitor.visit_unit()
    }

    fn deserialize_any<V: de::Visitor<'de>>(self, visitor: V) -> Result<V::Value> {
        match *self.peek()? {
            XmlEvent::StartElement { .. } => self.deserialize_map(visitor),
            XmlEvent::EndElement { .. } => self.deserialize_unit(visitor),
            _ => self.deserialize_string(visitor),
        }
    }
}
