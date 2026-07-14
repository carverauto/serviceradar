use crate::*;

/// Allows iterating over the options after a TCP header.
#[derive(Clone, Eq, PartialEq)]
pub struct TcpOptionsIterator<'a> {
    pub(crate) options: &'a [u8],
}

impl<'a> TcpOptionsIterator<'a> {
    /// Creates an options iterator from a slice containing encoded tcp options.
    pub fn from_slice(options: &'a [u8]) -> TcpOptionsIterator<'a> {
        TcpOptionsIterator { options }
    }

    /// Returns the non processed part of the options slice.
    pub fn rest(&self) -> &'a [u8] {
        self.options
    }
}

impl Iterator for TcpOptionsIterator<'_> {
    type Item = Result<TcpOptionElement, TcpOptionReadError>;

    fn next(&mut self) -> Option<Self::Item> {
        use crate::TcpOptionElement::*;
        use crate::TcpOptionReadError::*;

        let expect_specific_size =
            |expected_size: u8, slice: &[u8]| -> Result<(), TcpOptionReadError> {
                let id = slice[0];
                if slice.len() < expected_size as usize {
                    Err(UnexpectedEndOfSlice {
                        option_id: id,
                        expected_len: expected_size,
                        actual_len: slice.len(),
                    })
                } else if slice[1] != expected_size {
                    Err(UnexpectedSize {
                        option_id: slice[0],
                        size: slice[1],
                    })
                } else {
                    Ok(())
                }
            };

        if self.options.is_empty() {
            None
        } else {
            //first determine the result
            use tcp_option::*;
            let result = match self.options[0] {
                //end
                KIND_END => None,
                KIND_NOOP => {
                    self.options = &self.options[1..];
                    Some(Ok(Noop))
                }
                KIND_MAXIMUM_SEGMENT_SIZE => {
                    match expect_specific_size(LEN_MAXIMUM_SEGMENT_SIZE, self.options) {
                        Err(value) => Some(Err(value)),
                        _ => {
                            // SAFETY:
                            // Safe as the slice size is checked beforehand to be at
                            // least of size LEN_MAXIMUM_SEGMENT_SIZE (4).
                            let value =
                                unsafe { get_unchecked_be_u16(self.options.as_ptr().add(2)) };
                            self.options = &self.options[4..];
                            Some(Ok(MaximumSegmentSize(value)))
                        }
                    }
                }
                KIND_WINDOW_SCALE => match expect_specific_size(LEN_WINDOW_SCALE, self.options) {
                    Err(value) => Some(Err(value)),
                    _ => {
                        let value = self.options[2];
                        self.options = &self.options[3..];
                        Some(Ok(WindowScale(value)))
                    }
                },
                KIND_SELECTIVE_ACK_PERMITTED => {
                    match expect_specific_size(LEN_SELECTIVE_ACK_PERMITTED, self.options) {
                        Err(value) => Some(Err(value)),
                        _ => {
                            self.options = &self.options[2..];
                            Some(Ok(SelectiveAcknowledgementPermitted))
                        }
                    }
                }
                KIND_SELECTIVE_ACK => {
                    //check that the length field can be read
                    if self.options.len() < 2 {
                        Some(Err(UnexpectedEndOfSlice {
                            option_id: self.options[0],
                            expected_len: 2,
                            actual_len: self.options.len(),
                        }))
                    } else {
                        //check that the length is an allowed one for this option
                        let len = self.options[1];
                        if len != 10 && len != 18 && len != 26 && len != 34 {
                            Some(Err(UnexpectedSize {
                                option_id: self.options[0],
                                size: len,
                            }))
                        } else if self.options.len() < (len as usize) {
                            Some(Err(UnexpectedEndOfSlice {
                                option_id: self.options[0],
                                expected_len: len,
                                actual_len: self.options.len(),
                            }))
                        } else {
                            let mut acks: [Option<(u32, u32)>; 3] = [None; 3];
                            // SAFETY:
                            // This is safe as above the len is checked
                            // to be at least 10 and the slice len is
                            // checked to be at least len bytes.
                            let first = unsafe {
                                (
                                    get_unchecked_be_u32(self.options.as_ptr().add(2)),
                                    get_unchecked_be_u32(self.options.as_ptr().add(6)),
                                )
                            };
                            for (i, item) in acks.iter_mut().enumerate().take(3) {
                                let offset = 2 + 8 + (i * 8);
                                // SAFETY:
                                // len can only be 10, 18, 26 or 34
                                // therefore if the offset is smaller then the
                                // len, then at least 8 bytes can be read.
                                unsafe {
                                    if offset < (len as usize) {
                                        *item = Some((
                                            get_unchecked_be_u32(self.options.as_ptr().add(offset)),
                                            get_unchecked_be_u32(
                                                self.options.as_ptr().add(offset + 4),
                                            ),
                                        ));
                                    }
                                }
                            }
                            //iterate the options
                            self.options = &self.options[len as usize..];
                            Some(Ok(SelectiveAcknowledgement(first, acks)))
                        }
                    }
                }
                KIND_TIMESTAMP => {
                    match expect_specific_size(LEN_TIMESTAMP, self.options) {
                        Err(value) => Some(Err(value)),

                        _ => unsafe {
                            let t = Timestamp(
                                // SAFETY:
                                // Safe as the len first gets checked to be equal
                                // LEN_TIMESTAMP (10).
                                get_unchecked_be_u32(self.options.as_ptr().add(2)),
                                get_unchecked_be_u32(self.options.as_ptr().add(6)),
                            );
                            self.options = &self.options[10..];
                            Some(Ok(t))
                        },
                    }
                }

                //unknown id
                _ => Some(Err(UnknownId(self.options[0]))),
            };

            //in case the result was an error or the end move the slice to an end position
            match result {
                None | Some(Err(_)) => {
                    let len = self.options.len();
                    self.options = &self.options[len..len];
                }
                _ => {}
            }

            //finally return the result
            result
        }
    }
}

impl core::fmt::Debug for TcpOptionsIterator<'_> {
    fn fmt(&self, fmt: &mut core::fmt::Formatter) -> Result<(), core::fmt::Error> {
        let mut list = fmt.debug_list();

        // create a copy and iterate over all elements
        for it in self.clone() {
            match it {
                Ok(e) => {
                    list.entry(&e);
                }
                Err(e) => {
                    list.entry(&Result::<(), TcpOptionReadError>::Err(e.clone()));
                }
            }
        }

        list.finish()
    }
}

#[cfg(test)]
mod test {
    use crate::{tcp_option::*, *};
    use alloc::format;

    #[test]
    fn debug() {
        use tcp_option::*;
        #[rustfmt::skip]
        assert_eq!(
            "[MaximumSegmentSize(0), WindowScale(0)]",
            format!(
                "{:?}",
                TcpOptionsIterator::from_slice(&[
                    KIND_MAXIMUM_SEGMENT_SIZE, 4, 0, 0,
                    KIND_WINDOW_SCALE, 3, 0,
                    KIND_END,
                ])
            )
        );
        #[rustfmt::skip]
        assert_eq!(
            "[MaximumSegmentSize(0), Err(UnexpectedSize { option_id: 3, size: 0 })]",
            format!(
                "{:?}",
                TcpOptionsIterator::from_slice(&[
                    KIND_MAXIMUM_SEGMENT_SIZE, 4, 0, 0,
                    KIND_WINDOW_SCALE, 0, 0, 0,
                ])
            )
        );
    }

    #[test]
    fn clone_eq() {
        use tcp_option::*;
        let it = TcpOptionsIterator::from_slice(&[KIND_END]);
        assert_eq!(it, it.clone());
    }

    #[test]
    fn from_slice_and_rest() {
        let buffer = [KIND_NOOP, KIND_NOOP, KIND_MAXIMUM_SEGMENT_SIZE, 4];
        let it = TcpOptionsIterator::from_slice(&buffer);
        assert_eq!(it.rest(), &buffer[..]);
    }

    #[test]
    #[rustfmt::skip]
    fn next() {
        use crate::TcpOptionElement::*;

        // ok test
        {
            fn expect_elements(buffer: &[u8], expected: &[TcpOptionElement]) {
                // options iterator via from_slice()
                let mut it = TcpOptionsIterator::from_slice(buffer);
                for element in expected.iter() {
                    assert_eq!(element, &it.next().unwrap().unwrap());
                }
        
                //expect no more elements
                assert_eq!(None, it.next());
                assert_eq!(0, it.rest().len());
            }

            // nop & max segment size
            #[rustfmt::skip]
            expect_elements(&[
                    KIND_NOOP, 
                    KIND_NOOP,
                    KIND_MAXIMUM_SEGMENT_SIZE, 4, 
                    0, 1,
                    KIND_WINDOW_SCALE, 3, 2,
                    KIND_SELECTIVE_ACK_PERMITTED, 2,
                    KIND_SELECTIVE_ACK, 10,
                    0, 0, 0, 10,
                    0, 0, 0, 11,
                    KIND_SELECTIVE_ACK, 18, 
                    0, 0, 0, 12,
                    0, 0, 0, 13,
                    0, 0, 0, 14,
                    0, 0, 0, 15,
                    KIND_SELECTIVE_ACK, 26, 
                    0, 0, 0, 16,
                    0, 0, 0, 17,
                    0, 0, 0, 18,
                    0, 0, 0, 19,
                    0, 0, 0, 20,
                    0, 0, 0, 21,
                    KIND_SELECTIVE_ACK, 34, 
                    0, 0, 0, 22,
                    0, 0, 0, 23,
                    0, 0, 0, 24,
                    0, 0, 0, 25,
                    0, 0, 0, 26,
                    0, 0, 0, 27,
                    0, 0, 0, 28,
                    0, 0, 0, 29,
                    KIND_TIMESTAMP, 10, 
                    0, 0, 0, 30, 
                    0, 0, 0, 31,
                    KIND_END, 0, 0, 0, 0
                ],
                &[
                    Noop,
                    Noop,
                    MaximumSegmentSize(1),
                    WindowScale(2),
                    SelectiveAcknowledgementPermitted,
                    SelectiveAcknowledgement((10,11), [None, None, None]),
                    SelectiveAcknowledgement((12,13), [Some((14,15)), None, None]),
                    SelectiveAcknowledgement((16,17), [Some((18,19)), Some((20,21)), None]),
                    SelectiveAcknowledgement((22,23), [Some((24,25)), Some((26,27)), Some((28,29))]),
                    Timestamp(30,31)
                ]
            );
        }

        // unknown id
        {
            let data = [255, 2, 0, 0, 0,
                0, 0, 0, 0, 0, //10
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, //20
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, //30
                0, 0, 0, 0];
            let mut it = TcpOptionsIterator::from_slice(&data);
            assert_eq!(Some(Err(TcpOptionReadError::UnknownId(255))), it.next());
            
            //expect the iterator slice to be moved to the end
            assert_eq!(0, it.rest().len());
            assert_eq!(None, it.next());
            assert_eq!(0, it.rest().len());
        }

        // unexpected end of slice
        {
            fn expect_unexpected_eos(slice: &[u8]) {
                for i in 1..slice.len()-1 {
                    let mut it = TcpOptionsIterator::from_slice(&slice[..i]);
                    assert_eq!(
                        Some(
                            Err(
                                TcpOptionReadError::UnexpectedEndOfSlice{
                                    option_id: slice[0],
                                    expected_len: match slice[0] {
                                        KIND_MAXIMUM_SEGMENT_SIZE => 4,
                                        KIND_WINDOW_SCALE => 3,
                                        KIND_SELECTIVE_ACK_PERMITTED => 2,
                                        KIND_SELECTIVE_ACK => if i < 2 {
                                            // the inial check only checks if there
                                            // is enough data to read the length field
                                            2
                                        } else {
                                            slice[1]
                                        },
                                        KIND_TIMESTAMP => 10,
                                        _ => panic!("not part of the tests"),
                                    },
                                    actual_len: i
                                }
                            )
                        ),
                        it.next()
                    );
                    //expect the iterator slice to be moved to the end
                    assert_eq!(0, it.rest().len());
                    assert_eq!(None, it.next());
                }
            }

            expect_unexpected_eos(&[KIND_MAXIMUM_SEGMENT_SIZE, 4, 0, 0]);
            expect_unexpected_eos(&[KIND_WINDOW_SCALE, 3, 0]);
            expect_unexpected_eos(&[KIND_MAXIMUM_SEGMENT_SIZE, 4, 0, 0]);
            expect_unexpected_eos(&[KIND_SELECTIVE_ACK_PERMITTED, 2]);
            expect_unexpected_eos(&[KIND_SELECTIVE_ACK, 10, 0, 0, 0,
                                    0, 0, 0, 0, 0]);
            expect_unexpected_eos(&[KIND_SELECTIVE_ACK, 18, 0, 0, 0,
                                    0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0,
                                    0, 0, 0]);
            expect_unexpected_eos(&[KIND_SELECTIVE_ACK, 26, 0, 0, 0,
                                    0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0,
                                    0]);
            expect_unexpected_eos(&[KIND_SELECTIVE_ACK, 34, 0, 0, 0,
                                    0, 0, 0, 0, 0, //10
                                    0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, //20
                                    0, 0, 0, 0, 0,
                                    0, 0, 0, 0, 0, //30
                                    0, 0, 0, 0]);
            expect_unexpected_eos(&[KIND_TIMESTAMP, 10, 0, 0, 0,
                                    0, 0, 0, 0, 0]);
        }

        // unexpected option size error 
        {
            fn expect_unexpected_size(id: u8, size: u8) {
                let data = [
                    id, size, 0, 0, 0, 0, 0, 0, 0, 0, //10
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //20
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //30
                    0, 0, 0, 0,
                ];
                let mut it = TcpOptionsIterator::from_slice(&data);
                assert_eq!(
                    Some(Err(TcpOptionReadError::UnexpectedSize {
                        option_id: data[0],
                        size: data[1]
                    })),
                    it.next()
                );
                //expect the iterator slice to be moved to the end
                assert_eq!(0, it.rest().len());
                assert_eq!(None, it.next());
                assert_eq!(0, it.rest().len());
            }
            expect_unexpected_size(KIND_MAXIMUM_SEGMENT_SIZE, 3);
            expect_unexpected_size(KIND_MAXIMUM_SEGMENT_SIZE, 5);
        
            expect_unexpected_size(KIND_WINDOW_SCALE, 2);
            expect_unexpected_size(KIND_WINDOW_SCALE, 4);
        
            expect_unexpected_size(KIND_MAXIMUM_SEGMENT_SIZE, 3);
            expect_unexpected_size(KIND_MAXIMUM_SEGMENT_SIZE, 5);
        
            expect_unexpected_size(KIND_SELECTIVE_ACK_PERMITTED, 1);
            expect_unexpected_size(KIND_SELECTIVE_ACK_PERMITTED, 3);
        
            expect_unexpected_size(KIND_SELECTIVE_ACK, 9);
            expect_unexpected_size(KIND_SELECTIVE_ACK, 11);
        
            expect_unexpected_size(KIND_SELECTIVE_ACK, 17);
            expect_unexpected_size(KIND_SELECTIVE_ACK, 19);
        
            expect_unexpected_size(KIND_SELECTIVE_ACK, 25);
            expect_unexpected_size(KIND_SELECTIVE_ACK, 27);
        
            expect_unexpected_size(KIND_SELECTIVE_ACK, 33);
            expect_unexpected_size(KIND_SELECTIVE_ACK, 35);
        
            expect_unexpected_size(KIND_TIMESTAMP, 9);
            expect_unexpected_size(KIND_TIMESTAMP, 11);
        }
    }
}
