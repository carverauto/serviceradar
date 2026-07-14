// Copyright (c) 2022, Yuri6037
//
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
// * Neither the name of time-tz nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

use crate::timezone_impl::FixedTimespan;
use crate::timezone_impl::FixedTimespanSet;
use crate::timezone_impl::internal_tz_new;

use phf::Map;
use crate::Tz;

include!(concat!(env!("OUT_DIR"), "/timezones.rs"));

pub fn find_by_name(name: &str) -> Vec<&'static Tz> {
    if let Some(list) = WIN_TIMEZONES.get(name) {
        list.iter().map(|v| *v).collect()
    } else {
        TIMEZONES.entries().filter(|(k, _)| k.contains(name)).map(|(_, v)| *v).collect()
    }
}

pub fn iter() -> impl Iterator<Item = &'static Tz> {
    TIMEZONES.values().map(|v| *v)
}

pub fn get_by_name(name: &str) -> Option<&'static Tz> {
    if let Some(list) = WIN_TIMEZONES.get(name) {
        list.iter().nth(0).map(|v| *v)
    } else {
        TIMEZONES.get(name).map(|v| *v)
    }
}
