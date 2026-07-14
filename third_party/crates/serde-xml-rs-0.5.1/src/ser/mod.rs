use std::fmt::Display;
use std::io::Write;

use serde::ser::{self, Impossible, Serialize};

use self::var::{Map, Struct};
use crate::error::{Error, Result};

mod var;

/// A convenience method for serializing some object to a buffer.
///
/// # Examples
///
/// ```rust
/// # #[macro_use]
/// # extern crate serde_derive;
/// # extern crate serde;
/// # extern crate serde_xml_rs;
/// # use serde_xml_rs::to_writer;
/// #[derive(Serialize)]
/// struct Person {
///   name: String,
///   age: u32,
/// }
///
/// # fn main() {
/// let mut buffer = Vec::new();
/// let joe = Person {name: "Joe".to_string(), age: 42};
///
/// to_writer(&mut buffer, &joe).unwrap();
///
/// let serialized = String::from_utf8(buffer).unwrap();
/// println!("{}", serialized);
/// # }
/// ```
pub fn to_writer<W: Write, S: Serialize>(writer: W, value: &S) -> Result<()> {
    let mut ser = Serializer::new(writer);
    value.serialize(&mut ser)
}

/// A convenience method for serializing some object to a string.
///
/// # Examples
///
/// ```rust
/// # #[macro_use]
/// # extern crate serde_derive;
/// # extern crate serde;
/// # extern crate serde_xml_rs;
/// # use serde_xml_rs::to_string;
/// #[derive(Serialize)]
/// struct Person {
///   name: String,
///   age: u32,
/// }
///
/// # fn main() {
///
/// let joe = Person {name: "Joe".to_string(), age: 42};
/// let serialized = to_string(&joe).unwrap();
/// println!("{}", serialized);
/// # }
/// ```
pub fn to_string<S: Serialize>(value: &S) -> Result<String> {
    // Create a buffer and serialize our nodes into it
    let mut writer = Vec::with_capacity(128);
    to_writer(&mut writer, value)?;

    // We then check that the serialized string is the same as what we expect
    let string = String::from_utf8(writer)?;
    Ok(string)
}

/// An XML `Serializer`.
pub struct Serializer<W>
where
    W: Write,
{
    writer: W,
}

impl<W> Serializer<W>
where
    W: Write,
{
    pub fn new(writer: W) -> Self {
        Self { writer: writer }
    }

    fn write_primitive<P: Display>(&mut self, primitive: P) -> Result<()> {
        write!(self.writer, "{}", primitive)?;
        Ok(())
    }

    fn write_wrapped<S: Serialize>(&mut self, tag: &str, value: S) -> Result<()> {
        write!(self.writer, "<{}>", tag)?;
        value.serialize(&mut *self)?;
        write!(self.writer, "</{}>", tag)?;
        Ok(())
    }
}

#[allow(unused_variables)]
impl<'w, W> ser::Serializer for &'w mut Serializer<W>
where
    W: Write,
{
    type Ok = ();
    type Error = Error;

    type SerializeSeq = Impossible<Self::Ok, Self::Error>;
    type SerializeTuple = Impossible<Self::Ok, Self::Error>;
    type SerializeTupleStruct = Impossible<Self::Ok, Self::Error>;
    type SerializeTupleVariant = Impossible<Self::Ok, Self::Error>;
    type SerializeMap = Map<'w, W>;
    type SerializeStruct = Struct<'w, W>;
    type SerializeStructVariant = Impossible<Self::Ok, Self::Error>;

    fn serialize_bool(self, v: bool) -> Result<Self::Ok> {
        if v {
            write!(self.writer, "true")?;
        } else {
            write!(self.writer, "false")?;
        }

        Ok(())
    }

    fn serialize_i8(self, v: i8) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_i16(self, v: i16) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_i32(self, v: i32) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_i64(self, v: i64) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_u8(self, v: u8) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_u16(self, v: u16) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_u32(self, v: u32) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_u64(self, v: u64) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_f32(self, v: f32) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_f64(self, v: f64) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_char(self, v: char) -> Result<Self::Ok> {
        self.write_primitive(v)
    }

    fn serialize_str(self, value: &str) -> Result<Self::Ok> {
        self.write_primitive(value)
    }

    fn serialize_bytes(self, value: &[u8]) -> Result<Self::Ok> {
        // TODO: I imagine you'd want to use base64 here.
        // Not sure how to roundtrip effectively though...
        Err(Error::UnsupportedOperation {
            operation: "serialize_bytes".to_string(),
        })
    }

    fn serialize_none(self) -> Result<Self::Ok> {
        Ok(())
    }

    fn serialize_some<T: ?Sized + Serialize>(self, value: &T) -> Result<Self::Ok> {
        value.serialize(self)
    }

    fn serialize_unit(self) -> Result<Self::Ok> {
        self.serialize_none()
    }

    fn serialize_unit_struct(self, name: &'static str) -> Result<Self::Ok> {
        self.write_wrapped(name, ())
    }

    fn serialize_unit_variant(
        self,
        name: &'static str,
        variant_index: u32,
        variant: &'static str,
    ) -> Result<Self::Ok> {
        Err(Error::UnsupportedOperation {
            operation: "serialize_unit_variant".to_string(),
        })
    }

    fn serialize_newtype_struct<T: ?Sized + Serialize>(
        self,
        name: &'static str,
        value: &T,
    ) -> Result<Self::Ok> {
        Err(Error::UnsupportedOperation {
            operation: "serialize_newtype_struct".to_string(),
        })
    }

    fn serialize_newtype_variant<T: ?Sized + Serialize>(
        self,
        name: &'static str,
        variant_index: u32,
        variant: &'static str,
        value: &T,
    ) -> Result<Self::Ok> {
        self.write_wrapped(variant, value)
    }

    fn serialize_seq(self, len: Option<usize>) -> Result<Self::SerializeSeq> {
        // TODO: Figure out how to constrain the things written to only be composites
        Err(Error::UnsupportedOperation {
            operation: "serialize_seq".to_string(),
        })
    }

    fn serialize_tuple(self, len: usize) -> Result<Self::SerializeTuple> {
        Err(Error::UnsupportedOperation {
            operation: "serialize_tuple".to_string(),
        })
    }

    fn serialize_tuple_struct(
        self,
        name: &'static str,
        len: usize,
    ) -> Result<Self::SerializeTupleStruct> {
        Err(Error::UnsupportedOperation {
            operation: "serialize_tuple_struct".to_string(),
        })
    }

    fn serialize_tuple_variant(
        self,
        name: &'static str,
        variant_index: u32,
        variant: &'static str,
        len: usize,
    ) -> Result<Self::SerializeTupleVariant> {
        Err(Error::UnsupportedOperation {
            operation: "serialize_tuple_variant".to_string(),
        })
    }

    fn serialize_map(self, len: Option<usize>) -> Result<Self::SerializeMap> {
        Ok(Map::new(self))
    }

    fn serialize_struct(self, name: &'static str, len: usize) -> Result<Self::SerializeStruct> {
        write!(self.writer, "<{}>", name)?;
        Ok(Struct::new(self, name))
    }

    fn serialize_struct_variant(
        self,
        name: &'static str,
        variant_index: u32,
        variant: &'static str,
        len: usize,
    ) -> Result<Self::SerializeStructVariant> {
        Err(Error::UnsupportedOperation {
            operation: "Result".to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::ser::{SerializeMap, SerializeStruct};
    use serde::Serializer as SerSerializer;
    use serde_derive::Serialize;

    #[test]
    fn test_serialize_bool() {
        let inputs = vec![(true, "true"), (false, "false")];

        for (src, should_be) in inputs {
            let mut buffer = Vec::new();

            {
                let mut ser = Serializer::new(&mut buffer);
                ser.serialize_bool(src).unwrap();
            }

            let got = String::from_utf8(buffer).unwrap();
            assert_eq!(got, should_be);
        }
    }

    #[test]
    fn test_start_serialize_struct() {
        let mut buffer = Vec::new();

        {
            let mut ser = Serializer::new(&mut buffer);
            let _ = ser.serialize_struct("foo", 0).unwrap();
        }

        let got = String::from_utf8(buffer).unwrap();
        assert_eq!(got, "<foo>");
    }

    #[test]
    fn test_serialize_struct_field() {
        let mut buffer = Vec::new();

        {
            let mut ser = Serializer::new(&mut buffer);
            let mut struct_ser = Struct::new(&mut ser, "baz");
            struct_ser.serialize_field("foo", "bar").unwrap();
        }

        let got = String::from_utf8(buffer).unwrap();
        assert_eq!(got, "<foo>bar</foo>");
    }

    #[test]
    fn test_serialize_struct() {
        #[derive(Serialize)]
        struct Person {
            name: String,
            age: u32,
        }

        let bob = Person {
            name: "Bob".to_string(),
            age: 42,
        };
        let should_be = "<Person><name>Bob</name><age>42</age></Person>";
        let mut buffer = Vec::new();

        {
            let mut ser = Serializer::new(&mut buffer);
            bob.serialize(&mut ser).unwrap();
        }

        let got = String::from_utf8(buffer).unwrap();
        assert_eq!(got, should_be);
    }

    #[test]
    fn test_serialize_map_entries() {
        let should_be = "<name>Bob</name><age>5</age>";
        let mut buffer = Vec::new();

        {
            let mut ser = Serializer::new(&mut buffer);
            let mut map = Map::new(&mut ser);
            map.serialize_entry("name", "Bob").unwrap();
            map.serialize_entry("age", "5").unwrap();
        }

        let got = String::from_utf8(buffer).unwrap();
        assert_eq!(got, should_be);
    }

    #[test]
    fn test_serialize_enum() {
        #[derive(Serialize)]
        #[allow(dead_code)]
        enum Node {
            Boolean(bool),
            Number(f64),
            String(String),
        }

        let mut buffer = Vec::new();
        let should_be = "<Boolean>true</Boolean>";

        {
            let mut ser = Serializer::new(&mut buffer);
            let node = Node::Boolean(true);
            node.serialize(&mut ser).unwrap();
        }

        let got = String::from_utf8(buffer).unwrap();
        assert_eq!(got, should_be);
    }

    #[test]
    #[ignore]
    fn serialize_a_list() {
        let inputs = vec![1, 2, 3, 4];

        let mut buffer = Vec::new();

        {
            let mut ser = Serializer::new(&mut buffer);
            inputs.serialize(&mut ser).unwrap();
        }

        let got = String::from_utf8(buffer).unwrap();
        println!("{}", got);
        panic!();
    }
}
