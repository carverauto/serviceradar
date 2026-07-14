use std::ptr::NonNull;

use crate::{
    capture::{Capture, Dead},
    linktype::Linktype,
    raw, Error,
};

#[cfg(libpcap_1_5_0)]
use crate::capture::Precision;

impl Capture<Dead> {
    /// Creates a "fake" capture handle for the given link type.
    pub fn dead(linktype: Linktype) -> Result<Capture<Dead>, Error> {
        let handle = unsafe { raw::pcap_open_dead(linktype.0, 65535) };
        Ok(Capture::from(
            NonNull::<raw::pcap_t>::new(handle).ok_or(Error::InsufficientMemory)?,
        ))
    }

    /// Creates a "fake" capture handle for the given link type and timestamp precision.
    #[cfg(libpcap_1_5_0)]
    pub fn dead_with_precision(
        linktype: Linktype,
        precision: Precision,
    ) -> Result<Capture<Dead>, Error> {
        let handle = unsafe {
            raw::pcap_open_dead_with_tstamp_precision(linktype.0, 65535, precision as u32)
        };
        Ok(Capture::from(
            NonNull::<raw::pcap_t>::new(handle).ok_or(Error::InsufficientMemory)?,
        ))
    }
}

#[cfg(test)]
mod tests {
    #[cfg(libpcap_1_5_0)]
    use mockall::predicate;

    use crate::raw::testmod::{as_pcap_t, RAWMTX};

    use super::*;

    #[test]
    fn test_dead() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let ctx = raw::pcap_open_dead_context();
        ctx.expect().return_once_st(move |_, _| pcap);

        let ctx = raw::pcap_close_context();
        ctx.expect()
            .withf_st(move |ptr| *ptr == pcap)
            .return_once(|_| {});

        let result = Capture::dead(Linktype::ETHERNET);
        assert!(result.is_ok());
    }

    #[test]
    #[cfg(libpcap_1_5_0)]
    fn test_dead_with_precision() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let ctx = raw::pcap_open_dead_with_tstamp_precision_context();
        ctx.expect()
            .with(predicate::always(), predicate::always(), predicate::eq(1))
            .return_once_st(move |_, _, _| pcap);

        let ctx = raw::pcap_close_context();
        ctx.expect()
            .withf_st(move |ptr| *ptr == pcap)
            .return_once(|_| {});

        let result = Capture::dead_with_precision(Linktype::ETHERNET, Precision::Nano);
        assert!(result.is_ok());
    }
}
