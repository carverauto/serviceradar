use crate::{defrag::*, *};
use std::vec::Vec;

/// Buffer to reconstruct a single fragmented IP packet.
#[derive(Debug, Clone, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub struct IpDefragBuf {
    /// IP number identifying the type of payload.
    ip_number: IpNumber,

    /// Data buffer that should contain the SOMEIP header + reconstructed payload in the end.
    data: Vec<u8>,

    /// Contains the ranges filled with data.
    sections: Vec<IpFragRange>,

    /// End length of the defragmented packet (set if a packet with )
    end: Option<u16>,
}

impl IpDefragBuf {
    pub fn new(
        ip_number: IpNumber,
        mut data: Vec<u8>,
        mut sections: Vec<IpFragRange>,
    ) -> IpDefragBuf {
        IpDefragBuf {
            ip_number,
            data: {
                data.clear();
                data
            },
            sections: {
                sections.clear();
                sections
            },
            end: None,
        }
    }

    /// Return the ip number of the payload data that gets restored.
    #[inline]
    pub fn ip_number(&self) -> IpNumber {
        self.ip_number
    }

    /// Data buffer in which data packet is reconstructed.
    #[inline]
    pub fn data(&self) -> &Vec<u8> {
        &self.data
    }

    /// Sections completed of the packet.
    #[inline]
    pub fn sections(&self) -> &Vec<IpFragRange> {
        &self.sections
    }

    /// Sections completed of the packet.
    #[inline]
    pub fn end(&self) -> Option<u16> {
        self.end
    }

    /// Add a IPv4 slice
    #[cfg(any(target_pointer_width = "32", target_pointer_width = "64"))]
    pub fn add(
        &mut self,
        offset: IpFragOffset,
        more_fragments: bool,
        payload: &[u8],
    ) -> Result<(), IpDefragError> {
        use IpDefragError::*;

        // validate lengths
        let Ok(len_u16) = u16::try_from(payload.len()) else {
            return Err(SegmentTooBig {
                offset,
                payload_len: payload.len(),
                max: MAX_IP_DEFRAG_LEN_U16,
            });
        };

        let Some(end) = offset.byte_offset().checked_add(len_u16) else {
            return Err(SegmentTooBig {
                offset,
                payload_len: payload.len(),
                max: MAX_IP_DEFRAG_LEN_U16,
            });
        };

        // validate that the payload len is a multiple of 8 in case it is not the end
        if more_fragments && 0 != payload.len() & 0b111 {
            return Err(UnalignedFragmentPayloadLen {
                offset,
                payload_len: payload.len(),
            });
        }

        // check the section is not already ended
        if let Some(previous_end) = self.end {
            // either the end is after the current position
            if previous_end < end || ((false == more_fragments) && end != previous_end) {
                return Err(ConflictingEnd {
                    previous_end,
                    conflicting_end: end,
                });
            }
        }

        // get enough memory to store the de-fragmented
        let required_len = usize::from(end);
        if self.data.len() < required_len {
            if self.data.capacity() < required_len
                && self
                    .data
                    .try_reserve(required_len - self.data.len())
                    .is_err()
            {
                return Err(AllocationFailure { len: required_len });
            }
            unsafe {
                self.data.set_len(required_len);
            }
        }

        // insert new data
        let data_offset = usize::from(offset.byte_offset());
        self.data[data_offset..data_offset + payload.len()].copy_from_slice(payload);

        // update sections
        let mut new_section = IpFragRange {
            start: offset.byte_offset(),
            end,
        };

        // merge overlapping section into new section and remove them
        self.sections.retain(|it| -> bool {
            if let Some(merged) = new_section.merge(*it) {
                new_section = merged;
                false
            } else {
                true
            }
        });
        self.sections.push(new_section);

        // set end
        if false == more_fragments {
            self.end = Some(end);
            // restrict the length based on the length
            unsafe {
                // SAFETY: Safe as the length has previously been checked to be at least "end" long
                self.data.set_len(usize::from(end));
            }
        }

        Ok(())
    }

    /// Returns true if the fragmented data is completed.
    pub fn is_complete(&self) -> bool {
        self.end.is_some() && 1 == self.sections.len() && 0 == self.sections[0].start
    }

    /// Consume the [`IpDefragBuf`] and return the buffers.
    #[inline]
    pub fn take_bufs(self) -> (Vec<u8>, Vec<IpFragRange>) {
        (self.data, self.sections)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use std::{format, vec};

    #[test]
    fn debug_clone_eq() {
        let buf = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());
        let _ = format!("{:?}", buf);
        assert_eq!(buf, buf.clone());
        assert_eq!(buf.cmp(&buf), core::cmp::Ordering::Equal);
        assert_eq!(buf.partial_cmp(&buf), Some(core::cmp::Ordering::Equal));

        use core::hash::{Hash, Hasher};
        use std::collections::hash_map::DefaultHasher;
        let h1 = {
            let mut h = DefaultHasher::new();
            buf.hash(&mut h);
            h.finish()
        };
        let h2 = {
            let mut h = DefaultHasher::new();
            buf.clone().hash(&mut h);
            h.finish()
        };
        assert_eq!(h1, h2);
    }

    #[test]
    fn new() {
        let actual = IpDefragBuf::new(
            IpNumber::UDP,
            vec![1],
            vec![IpFragRange { start: 0, end: 1 }],
        );
        assert_eq!(actual.ip_number(), IpNumber::UDP);
        assert!(actual.data().is_empty());
        assert!(actual.sections().is_empty());
        assert!(actual.end().is_none());
    }

    /// Returns a u8 vec counting up from "start" until len is reached (truncating bits greater then u8).
    fn sequence(start: usize, len: usize) -> Vec<u8> {
        let mut result = Vec::with_capacity(len);
        for i in start..start + len {
            result.push((i & 0xff) as u8);
        }
        result
    }

    #[rustfmt::skip]
    #[test]
    fn add() {
        use IpDefragError::*;

        // normal reconstruction
        {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());

            let actions = [
                (false, (0, true, &sequence(0,16))),
                (false, (16, true, &sequence(16,32))),
                (true, (48, false, &sequence(48,16))),
            ];
            for a in actions {
                assert!(0 == (a.1.0 % 8));
                buffer.add(
                    IpFragOffset::try_new(a.1.0 / 8).unwrap(),
                    a.1.1,
                    a.1.2
                ).unwrap();
                assert_eq!(a.0, buffer.is_complete());
            }
            let (payload, _) = buffer.take_bufs();
            assert_eq!(&payload, &sequence(0,16*4));
        }

        // overlapping reconstruction
        {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());

            let actions = [
                (false, (0, true, sequence(0,16))),
                // will be overwritten
                (false, (32, true, sequence(0,16))),
                // overwrites
                (false, (32, false, sequence(32,16))),
                // completes
                (true, (16, true, sequence(16,16))),
            ];
            for a in actions {
                assert!(0 == (a.1.0 % 8));
                buffer.add(
                    IpFragOffset::try_new(a.1.0 / 8).unwrap(),
                    a.1.1,
                    &a.1.2
                ).unwrap();
                assert_eq!(a.0, buffer.is_complete());
            }
            let (payload, _) = buffer.take_bufs();
            assert_eq!(&payload, &sequence(0,16*3));
        }

        // reverse order
        {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());

            let actions = [
                (false, (48, false, &sequence(48,16))),
                (false, (16, true, &sequence(16,32))),
                (true, (0, true, &sequence(0,16))),
            ];
            for a in actions {
                assert!(0 == (a.1.0 % 8));
                buffer.add(
                    IpFragOffset::try_new(a.1.0 / 8).unwrap(),
                    a.1.1,
                    &a.1.2
                ).unwrap();
                assert_eq!(a.0, buffer.is_complete());
            }
            let (payload, _) = buffer.take_bufs();
            assert_eq!(&payload, &sequence(0,16*4));
        }

        // error packet bigger then max (payload len only)
        {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());
            let payload_len = usize::from(u16::MAX) + 1;
            assert_eq!(
                SegmentTooBig { offset: IpFragOffset::try_new(0).unwrap(), payload_len, max: u16::MAX },
                buffer.add(
                    IpFragOffset::try_new(0).unwrap(),
                    true,
                    &sequence(0, payload_len)
                ).unwrap_err()
            );
        }

        // error packet bigger then max (offset + payload len)
        {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());
            let payload_len = usize::from(u16::MAX) - 32 - 16 + 1;
            assert_eq!(
                SegmentTooBig { offset: IpFragOffset::try_new((32 + 16)/8).unwrap(), payload_len, max: u16::MAX },
                buffer.add(
                    IpFragOffset::try_new((32 + 16)/8).unwrap(),
                    true,
                    &sequence(0,payload_len)
                ).unwrap_err()
            );
        }

        // check packets that fill exactly to the max work
        {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());

            let payload_len = usize::from(u16::MAX - 16);
            assert_eq!(
                Ok(()),
                buffer.add(
                    IpFragOffset::try_new(16/8).unwrap(),
                    false,
                    &sequence(0, payload_len)
                )
            );
        }

        // packets conflicting with previously seen end
        for bad_offset in 1..8 {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());
            assert_eq!(
                UnalignedFragmentPayloadLen {
                    offset: IpFragOffset::try_new(48/8).unwrap(),
                    payload_len: bad_offset
                },
                buffer.add(
                    IpFragOffset::try_new(48/8).unwrap(),
                    true,
                    &sequence(0, bad_offset)
                ).unwrap_err()
            );
        }

        // test that conflicting ends trigger errors (received a different end)
        {
            let mut buffer = IpDefragBuf::new(IpNumber::UDP, Vec::new(), Vec::new());

            // setup an end (aka no more segements)
            buffer.add(
                IpFragOffset::try_new(32/8).unwrap(),
                false,
                &sequence(32,16)
            ).unwrap();

            // test that a "non end" going over the end package triggers an error
            assert_eq!(
                ConflictingEnd { previous_end: 32 + 16, conflicting_end: 48 + 16 },
                buffer.add(
                    IpFragOffset::try_new(48/8).unwrap(),
                    true,
                    &sequence(48,16)
                ).unwrap_err()
            );

            // test that a new end at an earlier position triggers an error
            assert_eq!(
                ConflictingEnd { previous_end: 32 + 16, conflicting_end: 16 + 16 },
                buffer.add(
                    IpFragOffset::try_new(16/8).unwrap(),
                    false,
                    &sequence(16,16)
                ).unwrap_err()
            );
        }
    }
}
