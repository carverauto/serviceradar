use std::io::Write;

use serde::ser::{self, Serialize};

use crate::error::{Error, Result};
use crate::ser::Serializer;

/// An implementation of `SerializeMap` for serializing to XML.
pub struct Map<'w, W>
where
    W: Write,
{
    parent: &'w mut Serializer<W>,
}

impl<'w, W> Map<'w, W>
where
    W: 'w + Write,
{
    pub fn new(parent: &'w mut Serializer<W>) -> Map<'w, W> {
        Map { parent }
    }
}

impl<'w, W> ser::SerializeMap for Map<'w, W>
where
    W: 'w + Write,
{
    type Ok = ();
    type Error = Error;

    fn serialize_key<T: ?Sized + Serialize>(&mut self, _: &T) -> Result<()> {
        panic!("impossible to serialize the key on its own, please use serialize_entry()")
    }

    fn serialize_value<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<()> {
        value.serialize(&mut *self.parent)
    }

    fn end(self) -> Result<Self::Ok> {
        Ok(())
    }

    fn serialize_entry<K: ?Sized + Serialize, V: ?Sized + Serialize>(
        &mut self,
        key: &K,
        value: &V,
    ) -> Result<()> {
        // TODO: Is it possible to ensure our key is never a composite type?
        // Anything which isn't a "primitive" would lead to malformed XML here...
        write!(self.parent.writer, "<")?;
        key.serialize(&mut *self.parent)?;
        write!(self.parent.writer, ">")?;

        value.serialize(&mut *self.parent)?;

        write!(self.parent.writer, "</")?;
        key.serialize(&mut *self.parent)?;
        write!(self.parent.writer, ">")?;
        Ok(())
    }
}

/// An implementation of `SerializeStruct` for serializing to XML.
pub struct Struct<'w, W>
where
    W: Write,
{
    parent: &'w mut Serializer<W>,
    name: &'w str,
}

impl<'w, W> Struct<'w, W>
where
    W: 'w + Write,
{
    pub fn new(parent: &'w mut Serializer<W>, name: &'w str) -> Struct<'w, W> {
        Struct { parent, name }
    }
}

impl<'w, W> ser::SerializeStruct for Struct<'w, W>
where
    W: 'w + Write,
{
    type Ok = ();
    type Error = Error;

    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> Result<()> {
        write!(self.parent.writer, "<{}>", key)?;
        value.serialize(&mut *self.parent)?;
        write!(self.parent.writer, "</{}>", key)?;
        Ok(())
    }

    fn end(self) -> Result<Self::Ok> {
        write!(self.parent.writer, "</{}>", self.name).map_err(|e| e.into())
    }
}
