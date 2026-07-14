use crate::{
    err::{io::LimitedReadError, Layer, LenError},
    *,
};

/// Encapsulated reader with an maximum allowed read length.
///
/// This struct is used to limit data reads by lower protocol layers
/// (e.g. the payload_len in an IPv6Header limits how much data should
/// be read by the following layers).
///
/// An [`crate::err::LenError`] is returned as soon as more than the
/// maximum read len is read.
#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
pub struct LimitedReader<T> {
    /// Reader from which data will be read.
    reader: T,
    /// Maximum len that still can be read (on the current layer).
    max_len: usize,
    /// Source of the maximum length.
    len_source: LenSource,
    /// Layer that is currently read (used for len error).
    layer: Layer,
    /// Offset of the layer that is currently read (used for len error).
    layer_offset: usize,
    /// Len that was read on the current layer.
    read_len: usize,
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl<T: std::io::Read + Sized> LimitedReader<T> {
    /// Setup a new limited reader.
    pub fn new(
        reader: T,
        max_len: usize,
        len_source: LenSource,
        layer_offset: usize,
        layer: Layer,
    ) -> LimitedReader<T> {
        LimitedReader {
            reader,
            max_len,
            len_source,
            layer,
            layer_offset,
            read_len: 0,
        }
    }

    /// Maximum len that still can be read (on the current layer).
    pub fn max_len(&self) -> usize {
        self.max_len
    }

    /// Source of the maximum length (used for len error).
    pub fn len_source(&self) -> LenSource {
        self.len_source
    }

    /// Layer that is currently read (used for len error).
    pub fn layer(&self) -> Layer {
        self.layer
    }

    /// Offset of the layer that is currently read (used for len error).
    pub fn layer_offset(&self) -> usize {
        self.layer_offset
    }

    /// Len that was read on the current layer.
    pub fn read_len(&self) -> usize {
        self.read_len
    }

    /// Set current position as starting position for a layer.
    pub fn start_layer(&mut self, layer: Layer) {
        self.layer_offset += self.read_len;
        self.max_len -= self.read_len;
        self.read_len = 0;
        self.layer = layer;
    }

    /// Try read the given buf length from the reader.
    ///
    /// Triggers an len error if the
    pub fn read_exact(&mut self, buf: &mut [u8]) -> Result<(), LimitedReadError> {
        use LimitedReadError::*;
        if self.max_len - self.read_len < buf.len() {
            Err(Len(LenError {
                required_len: self.read_len + buf.len(),
                len: self.max_len,
                len_source: self.len_source,
                layer: self.layer,
                layer_start_offset: self.layer_offset,
            }))
        } else {
            self.reader.read_exact(buf).map_err(Io)?;
            self.read_len += buf.len();
            Ok(())
        }
    }

    /// Consumes LimitedReader and returns the reader.
    pub fn take_reader(self) -> T {
        self.reader
    }
}

#[cfg(feature = "std")]
#[cfg_attr(docsrs, doc(cfg(feature = "std")))]
impl<T: core::fmt::Debug> core::fmt::Debug for LimitedReader<T> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("LimitedReader")
            .field("reader", &self.reader)
            .field("max_len", &self.max_len)
            .field("len_source", &self.len_source)
            .field("layer", &self.layer)
            .field("layer_offset", &self.layer_offset)
            .field("read_len", &self.read_len)
            .finish()
    }
}

#[cfg(all(test, feature = "std"))]
mod tests {
    use std::format;
    use std::io::Cursor;

    use super::*;

    #[test]
    fn new() {
        let data = [1, 2, 3, 4];
        let actual = LimitedReader::new(
            Cursor::new(&data),
            data.len(),
            LenSource::Slice,
            5,
            Layer::Ipv4Header,
        );
        assert_eq!(actual.max_len, data.len());
        assert_eq!(actual.max_len(), data.len());
        assert_eq!(actual.len_source, LenSource::Slice);
        assert_eq!(actual.len_source(), LenSource::Slice);
        assert_eq!(actual.layer, Layer::Ipv4Header);
        assert_eq!(actual.layer(), Layer::Ipv4Header);
        assert_eq!(actual.layer_offset, 5);
        assert_eq!(actual.layer_offset(), 5);
        assert_eq!(actual.read_len, 0);
        assert_eq!(actual.read_len(), 0);
    }

    #[test]
    fn start_layer() {
        let data = [1, 2, 3, 4, 5];
        let mut r = LimitedReader::new(
            Cursor::new(&data),
            data.len(),
            LenSource::Slice,
            6,
            Layer::Ipv4Header,
        );
        {
            let mut read_result = [0u8; 2];
            r.read_exact(&mut read_result).unwrap();
            assert_eq!(read_result, [1, 2]);
        }
        r.start_layer(Layer::IpAuthHeader);

        assert_eq!(r.max_len, 3);
        assert_eq!(r.len_source, LenSource::Slice);
        assert_eq!(r.layer, Layer::IpAuthHeader);
        assert_eq!(r.layer_offset, 2 + 6);
        assert_eq!(r.read_len, 0);

        {
            let mut read_result = [0u8; 4];
            assert_eq!(
                r.read_exact(&mut read_result).unwrap_err().len().unwrap(),
                LenError {
                    required_len: 4,
                    len: 3,
                    len_source: LenSource::Slice,
                    layer: Layer::IpAuthHeader,
                    layer_start_offset: 2 + 6
                }
            );
        }
    }

    #[test]
    fn read_exact() {
        let data = [1, 2, 3, 4, 5];
        let mut r = LimitedReader::new(
            Cursor::new(&data),
            data.len() + 1,
            LenSource::Ipv4HeaderTotalLen,
            10,
            Layer::Ipv4Header,
        );

        // normal read
        {
            let mut read_result = [0u8; 2];
            r.read_exact(&mut read_result).unwrap();
            assert_eq!(read_result, [1, 2]);
        }

        // len error
        {
            let mut read_result = [0u8; 5];
            assert_eq!(
                r.read_exact(&mut read_result).unwrap_err().len().unwrap(),
                LenError {
                    required_len: 7,
                    len: 6,
                    len_source: LenSource::Ipv4HeaderTotalLen,
                    layer: Layer::Ipv4Header,
                    layer_start_offset: 10
                }
            );
        }

        // io error
        {
            let mut read_result = [0u8; 4];
            assert!(r.read_exact(&mut read_result).unwrap_err().io().is_some());
        }
    }

    #[test]
    fn take_reader() {
        let data = [1, 2, 3, 4, 5];
        let mut r = LimitedReader::new(
            Cursor::new(&data),
            data.len(),
            LenSource::Slice,
            6,
            Layer::Ipv4Header,
        );
        {
            let mut read_result = [0u8; 2];
            r.read_exact(&mut read_result).unwrap();
            assert_eq!(read_result, [1, 2]);
        }
        let result = r.take_reader();
        assert_eq!(2, result.position());
    }

    #[test]
    fn debug() {
        let data = [1, 2, 3, 4];
        let actual = LimitedReader::new(
            Cursor::new(&data),
            data.len(),
            LenSource::Slice,
            5,
            Layer::Ipv4Header,
        );
        assert_eq!(
            format!("{:?}", actual),
            format!(
                "LimitedReader {{ reader: {:?}, max_len: {:?}, len_source: {:?}, layer: {:?}, layer_offset: {:?}, read_len: {:?} }}",
                &actual.reader,
                &actual.max_len,
                &actual.len_source,
                &actual.layer,
                &actual.layer_offset,
                &actual.read_len
            )
        );
    }
}
