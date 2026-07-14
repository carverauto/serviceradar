use {
    super::regex,
    std::borrow::Cow,
};

/// Remove the first match of the regex from the text.
///
/// If the removed match is at the start or end of the input,
/// no new String is allocated and a borrowed slice is returned.
#[must_use]
pub fn remove_match<'s>(
    rex: &regex::Regex,
    text: &'s str,
) -> Cow<'s, str> {
    let Some(m) = rex.find(text) else {
        return Cow::Borrowed(text);
    };
    if m.start() == 0 {
        return Cow::Borrowed(&text[m.end()..]);
    }
    if m.end() == text.len() {
        return Cow::Borrowed(&text[..m.start()]);
    }
    let mut s = String::with_capacity(text.len() - m.len());
    s.push_str(&text[..m.start()]);
    s.push_str(&text[m.end()..]);
    Cow::Owned(s)
}

/// Remove the first match of the regex from the given `&[u8]` slice.
///
/// If the removed match is at the start or end of the input,
/// a borrowed slice is returned.
#[must_use]
#[cfg(not(feature = "lite"))]
pub fn bytes_remove_match<'s>(
    rex: &regex::bytes::Regex,
    text: &'s [u8],
) -> Cow<'s, [u8]> {
    let Some(m) = rex.find(text) else {
        return Cow::Borrowed(text);
    };
    if m.start() == 0 {
        return Cow::Borrowed(&text[m.end()..]);
    }
    if m.end() == text.len() {
        return Cow::Borrowed(&text[..m.start()]);
    }
    let mut s = Vec::with_capacity(text.len() - m.len());
    s.extend_from_slice(&text[..m.start()]);
    s.extend_from_slice(&text[m.end()..]);
    Cow::Owned(s)
}

/// Remove all matches of the regex from the text.
///
/// When all matches are at the start or end of the input, no new
/// String is allocated and a borrowed slice is returned.
#[must_use]
pub fn remove_all_matches<'s>(
    rex: &regex::Regex,
    text: &'s str,
) -> Cow<'s, str> {
    let mut trim_start_end = 0;
    let mut it = rex.find_iter(text);
    loop {
        let Some(mut m) = it.next() else {
            break;
        };
        if m.start() == trim_start_end {
            // Match at the start of the remaining text
            // (all matches so far are at the start of the input),
            // we can just move the start of the slice forward
            trim_start_end = m.end();
            continue;
        }
        let rem_start = m.start();
        // Match isn't at the start of the text, so either we have a hole, or all other
        // matches are at the end of the input.
        let mut hole_end = m.end();
        loop {
            if hole_end == text.len() {
                // All matches are either at the start or end of the input, we
                // can just return a borrowed slice
                return Cow::Borrowed(&text[trim_start_end..rem_start]);
            }
            if let Some(nm) = it.next() {
                if nm.start() != m.end() {
                    // We have at least 2 slices to keep, so we need to create a new string
                    let mut string = String::with_capacity(text.len() - trim_start_end);
                    string.push_str(&text[trim_start_end..rem_start]);
                    string.push_str(&text[m.end()..nm.start()]);
                    // now we'll go till the end, adding the slices we keep
                    let mut last_end = nm.end();
                    loop {
                        let Some(m) = it.next() else {
                            string.push_str(&text[last_end..]);
                            return Cow::Owned(string);
                        };
                        string.push_str(&text[last_end..m.start()]);
                        last_end = m.end();
                    }
                }
                // Next match is immediately after the current match, so we can skip it
                hole_end = nm.end();
                m = nm;
            } else {
                // There's no more matches, and we're not at the end of the input, so we need to
                // create a new string because there's a hole in the middle of the input
                dbg!(trim_start_end, rem_start, m.end(), text.len());
                let len = (rem_start - trim_start_end) + (text.len() - m.end());
                let mut string = String::with_capacity(len);
                string.push_str(&text[trim_start_end..rem_start]);
                string.push_str(&text[m.end()..]);
                return Cow::Owned(string);
            }
        }
    }
    Cow::Borrowed(&text[trim_start_end..])
}


/// Remove all matches of the regex from the text.
///
/// When all matches are at the start or end of the input, no new
/// String is allocated and a borrowed slice is returned.
#[must_use]
#[cfg(not(feature = "lite"))]
pub fn bytes_remove_all_matches<'s>(
    rex: &regex::bytes::Regex,
    text: &'s [u8],
) -> Cow<'s, [u8]> {
    let mut trim_start_end = 0;
    let mut it = rex.find_iter(text);
    loop {
        let Some(mut m) = it.next() else {
            break;
        };
        if m.start() == trim_start_end {
            // Match at the start of the remaining text
            // (all matches so far are at the start of the input),
            // we can just move the start of the slice forward
            trim_start_end = m.end();
            continue;
        }
        let rem_start = m.start();
        // Match isn't at the start of the text, so either we have a hole, or all other
        // matches are at the end of the input.
        let mut hole_end = m.end();
        loop {
            if hole_end == text.len() {
                // All matches are either at the start or end of the input, we
                // can just return a borrowed slice
                return Cow::Borrowed(&text[trim_start_end..rem_start]);
            }
            if let Some(nm) = it.next() {
                if nm.start() != m.end() {
                    // We have at least 2 slices to keep, so we need to create a new string
                    let mut string = Vec::with_capacity(text.len() - trim_start_end);
                    string.extend_from_slice(&text[trim_start_end..rem_start]);
                    string.extend_from_slice(&text[m.end()..nm.start()]);
                    // now we'll go till the end, adding the slices we keep
                    let mut last_end = nm.end();
                    loop {
                        let Some(m) = it.next() else {
                            string.extend_from_slice(&text[last_end..]);
                            return Cow::Owned(string);
                        };
                        string.extend_from_slice(&text[last_end..m.start()]);
                        last_end = m.end();
                    }
                }
                // Next match is immediately after the current match, so we can skip it
                hole_end = nm.end();
                m = nm;
            } else {
                // There's no more matches, and we're not at the end of the input, so we need to
                // create a new string because there's a hole in the middle of the input
                dbg!(trim_start_end, rem_start, m.end(), text.len());
                let len = (rem_start - trim_start_end) + (text.len() - m.end());
                let mut string = Vec::with_capacity(len);
                string.extend_from_slice(&text[trim_start_end..rem_start]);
                string.extend_from_slice(&text[m.end()..]);
                return Cow::Owned(string);
            }
        }
    }
    Cow::Borrowed(&text[trim_start_end..])
}

