pub trait DataSource {
    /// Length of the serialized data
    fn len(&self) -> usize;

    fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Datasource for APDU serialization
///
/// W is a type parameter of the trait and not the method to make the trait dyn-safe
pub trait DataStream<W: super::Writer>: DataSource {
    /// Serialize the data to a writer.
    ///
    /// The length of the data serialized to the writer must not exceed the value returned by `len`.
    fn to_writer(&self, writer: &mut W) -> Result<(), W::Error>;
}

impl<const N: usize> DataSource for [u8; N] {
    fn len(&self) -> usize {
        N
    }

    fn is_empty(&self) -> bool {
        N == 0
    }
}

impl<W: super::Writer, const N: usize> DataStream<W> for [u8; N] {
    fn to_writer(&self, writer: &mut W) -> Result<(), W::Error> {
        writer.write_all(self)
    }
}

impl DataSource for [u8] {
    fn len(&self) -> usize {
        <[u8]>::len(self)
    }

    fn is_empty(&self) -> bool {
        <[u8]>::is_empty(self)
    }
}

impl<W: super::Writer> DataStream<W> for [u8] {
    fn to_writer(&self, writer: &mut W) -> Result<(), W::Error> {
        writer.write_all(self)
    }
}

impl DataSource for [&dyn DataSource] {
    fn len(&self) -> usize {
        self.iter().map(|item| item.len()).sum()
    }

    fn is_empty(&self) -> bool {
        self.iter().all(|item| item.is_empty())
    }
}

impl<W: super::Writer> DataSource for [&dyn DataStream<W>] {
    fn len(&self) -> usize {
        self.iter().map(|item| item.len()).sum()
    }

    fn is_empty(&self) -> bool {
        self.iter().all(|item| item.is_empty())
    }
}

impl<W: super::Writer> DataStream<W> for [&dyn DataStream<W>] {
    fn to_writer(&self, writer: &mut W) -> Result<(), W::Error> {
        for item in self {
            item.to_writer(writer)?;
        }
        Ok(())
    }
}

impl<I: DataSource> DataSource for Option<I> {
    fn len(&self) -> usize {
        self.as_ref().map(DataSource::len).unwrap_or(0)
    }
    fn is_empty(&self) -> bool {
        self.as_ref().map(DataSource::is_empty).unwrap_or(true)
    }
}

impl<W: super::Writer, I: DataStream<W>> DataStream<W> for Option<I> {
    fn to_writer(&self, writer: &mut W) -> Result<(), <W as super::Writer>::Error> {
        if let Some(inner) = self {
            inner.to_writer(writer)
        } else {
            Ok(())
        }
    }
}

impl DataSource for () {
    fn len(&self) -> usize {
        0
    }

    fn is_empty(&self) -> bool {
        true
    }
}

impl<W: super::Writer> DataStream<W> for () {
    fn to_writer(&self, _writer: &mut W) -> Result<(), <W as super::Writer>::Error> {
        Ok(())
    }
}

impl<T: DataSource + ?Sized> DataSource for &T {
    fn len(&self) -> usize {
        T::len(&**self)
    }

    fn is_empty(&self) -> bool {
        T::is_empty(&**self)
    }
}

impl<W: super::Writer, T: DataStream<W> + ?Sized> DataStream<W> for &T {
    fn to_writer(&self, writer: &mut W) -> Result<(), <W as super::Writer>::Error> {
        T::to_writer(&**self, writer)
    }
}

mod tuple_impls {
    use super::*;

    /// implementation for tuples
    macro_rules! tuple_impl {
        ($($t:tt)+) => {
            impl<$($t: DataSource),+> DataSource for ($($t),+) {
                fn len(&self) -> usize {
                    #[allow(non_snake_case)]
                    let ($($t),+) = self;
                    0 $( + $t.len())+
                }

                fn is_empty(&self) -> bool {
                    #[allow(non_snake_case)]
                    let ($($t),+) = self;
                    true $( && $t.is_empty())+
                }
            }
            impl<W: crate::command::Writer, $($t: DataStream<W>),+> DataStream<W> for ($($t),+) {
                fn to_writer(&self, writer: &mut W) -> Result<(), <W as crate::command::Writer>::Error> {
                    #[allow(non_snake_case)]
                    let ($($t),+) = self;
                    $($t.to_writer(writer)?;)+
                    Ok(())
                }
            }
        };
    }

    tuple_impl!(A B);
    tuple_impl!(A B C);
    tuple_impl!(A B C D);
    tuple_impl!(A B C D E);
    tuple_impl!(A B C D E F);
    tuple_impl!(A B C D E F G);
    tuple_impl!(A B C D E F G H);
    tuple_impl!(A B C D E F G H I);
    tuple_impl!(A B C D E F G H I J);
    tuple_impl!(A B C D E F G H I J K);
    tuple_impl!(A B C D E F G H I J K L);
    tuple_impl!(A B C D E F G H I J K L M);
    tuple_impl!(A B C D E F G H I J K L M N);
    tuple_impl!(A B C D E F G H I J K L M N O);
    tuple_impl!(A B C D E F G H I J K L M N O P);
}
