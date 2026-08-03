use crate::{
    error::{ResolveError, ResolveErrorKind},
    internal::Meta,
    ri::Ref,
};
use alloc::string::String;
use core::num::NonZeroUsize;

pub(crate) fn resolve(
    base: Ref<'_, '_>,
    /* reference */ r: Ref<'_, '_>,
) -> Result<(String, Meta), ResolveError> {
    if !base.has_scheme() || base.has_fragment() {
        return Err(ResolveError(ResolveErrorKind::InvalidBase));
    }
    if !base.has_authority()
        && base.path().is_rootless()
        && !r.has_scheme()
        && !matches!(r.as_str().bytes().next(), None | Some(b'#'))
    {
        return Err(ResolveError(ResolveErrorKind::OpaqueBase));
    }

    let (t_scheme, t_authority, t_path, t_query, t_fragment);
    let mut buf = String::new();

    let r_scheme = r.scheme_opt();
    let r_authority = r.authority();
    let r_path = r.path();
    let r_query = r.query();
    let r_fragment = r.fragment();

    if let Some(r_scheme) = r_scheme {
        t_scheme = r_scheme;
        t_authority = r_authority;
        t_path = if r_path.is_absolute() {
            buf.reserve_exact(r_path.len());
            remove_dot_segments(&mut buf, r_path.as_str())
        } else {
            r_path.as_str()
        };
        t_query = r_query;
    } else {
        if r_authority.is_some() {
            t_authority = r_authority;
            buf.reserve_exact(r_path.len());
            t_path = remove_dot_segments(&mut buf, r_path.as_str());
            t_query = r_query;
        } else {
            if r_path.is_empty() {
                t_path = base.path().as_str();
                if r_query.is_some() {
                    t_query = r_query;
                } else {
                    t_query = base.query();
                }
            } else {
                if r_path.is_absolute() {
                    buf.reserve_exact(r_path.len());
                    t_path = remove_dot_segments(&mut buf, r_path.as_str());
                } else {
                    // Instead of merging the paths, remove dot segments incrementally.
                    let base_path = base.path().as_str();
                    if base_path.is_empty() {
                        buf.reserve_exact(r_path.len() + 1);
                        buf.push('/');
                    } else {
                        // Make sure that swapping the order of resolution and normalization
                        // does not change the result.
                        let last_slash_i = base_path.rfind('/').unwrap();
                        let last_seg = &base_path[last_slash_i + 1..];
                        let base_path_stripped = match classify_segment(last_seg) {
                            SegKind::DoubleDot => base_path,
                            _ => &base_path[..=last_slash_i],
                        };

                        buf.reserve_exact(base_path_stripped.len() + r_path.len());
                        remove_dot_segments(&mut buf, base_path_stripped);
                    }
                    t_path = remove_dot_segments(&mut buf, r_path.as_str());
                }
                t_query = r_query;
            }
            t_authority = base.authority();
        }
        t_scheme = base.scheme();
    }
    t_fragment = r_fragment;

    // Calculate the output length.
    let mut len = t_scheme.as_str().len() + 1;
    if let Some(authority) = t_authority {
        len += authority.as_str().len() + 2;
    }
    if t_authority.is_none() && t_path.starts_with("//") {
        len += 2;
    }
    len += t_path.len();
    if let Some(query) = t_query {
        len += query.len() + 1;
    }
    if let Some(fragment) = t_fragment {
        len += fragment.len() + 1;
    }

    let mut buf = String::with_capacity(len);
    let mut meta = Meta::default();

    buf.push_str(t_scheme.as_str());
    meta.scheme_end = NonZeroUsize::new(buf.len());
    buf.push(':');

    if let Some(authority) = t_authority {
        let mut auth_meta = authority.meta();
        buf.push_str("//");

        auth_meta.host_bounds.0 += buf.len();
        auth_meta.host_bounds.1 += buf.len();

        buf.push_str(authority.as_str());
        meta.auth_meta = Some(auth_meta);
    }

    meta.path_bounds.0 = buf.len();
    // Close the loophole in the original algorithm.
    if t_authority.is_none() && t_path.starts_with("//") {
        buf.push_str("/.");
    }
    buf.push_str(t_path);
    meta.path_bounds.1 = buf.len();

    if let Some(query) = t_query {
        buf.push('?');
        buf.push_str(query.as_str());
        meta.query_end = NonZeroUsize::new(buf.len());
    }

    if let Some(fragment) = t_fragment {
        buf.push('#');
        buf.push_str(fragment.as_str());
    }

    debug_assert_eq!(buf.len(), len);

    Ok((buf, meta))
}

pub(crate) fn remove_dot_segments<'a>(buf: &'a mut String, path: &str) -> &'a str {
    for seg in path.split_inclusive('/') {
        let seg_stripped = seg.strip_suffix('/').unwrap_or(seg);
        match classify_segment(seg_stripped) {
            SegKind::Dot => buf.truncate(buf.rfind('/').unwrap() + 1),
            SegKind::DoubleDot => {
                if buf.len() != 1 {
                    buf.truncate(buf.rfind('/').unwrap());
                    buf.truncate(buf.rfind('/').unwrap() + 1);
                }
            }
            SegKind::Normal => buf.push_str(seg),
        }
    }
    buf
}

enum SegKind {
    Dot,
    DoubleDot,
    Normal,
}

fn classify_segment(mut seg: &str) -> SegKind {
    if seg.is_empty() {
        return SegKind::Normal;
    }
    if let Some(rem) = seg.strip_prefix('.') {
        seg = rem;
    } else if let Some(rem) = seg.strip_prefix("%2E") {
        seg = rem;
    } else if let Some(rem) = seg.strip_prefix("%2e") {
        seg = rem;
    }
    if seg.is_empty() {
        SegKind::Dot
    } else if seg == "." || seg == "%2E" || seg == "%2e" {
        SegKind::DoubleDot
    } else {
        SegKind::Normal
    }
}
