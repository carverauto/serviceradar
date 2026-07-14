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

use std::cmp::Ordering;

pub fn binary_search<F: Fn(usize) -> Ordering>(start: usize, end: usize, cmp: F) -> Option<usize>
{
    if start >= end {
        return None;
    }
    let half = (end - start) / 2;
    let mid = start + half;
    match cmp(mid) {
        Ordering::Greater => binary_search(start, mid, cmp),
        Ordering::Equal => Some(mid),
        Ordering::Less => binary_search(mid + 1, end, cmp)
    }
}

#[test]
fn test_binary_search() {
    assert_eq!(binary_search(0, 8, |x| x.cmp(&6)), Some(6));
    assert_eq!(binary_search(0, 5000, |x| x.cmp(&1337)), Some(1337));
    assert_eq!(binary_search(0, 5000, |x| x.cmp(&9000)), None);
    assert_eq!(binary_search(30, 50, |x| x.cmp(&42)), Some(42));
    assert_eq!(binary_search(300, 500, |x| x.cmp(&42)), None);
    assert_eq!(
        binary_search(0, 500, |x| if x < 42 { Ordering::Less } else { Ordering::Greater }),
        None
    );
}
