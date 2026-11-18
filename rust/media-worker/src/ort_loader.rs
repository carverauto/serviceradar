//! Dynamic ONNX Runtime C-ABI loader (`ORT_DYLIB_PATH`, `OrtGetApiBase`).
//!
//! Avoids compile-time `curl` downloads inside hermetic Bazel sandboxes on
//! `linux/amd64` and `linux/arm64` by probing the runtime shared library at
//! startup via `dlopen` / `dlsym`.

use crate::errors::CapabilityError;
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString};
use std::path::Path;

#[repr(C)]
struct OrtApiBase {
    get_api: Option<unsafe extern "C" fn(version: u32) -> *const core::ffi::c_void>,
    get_version_string: Option<unsafe extern "C" fn() -> *const core::ffi::c_char>,
}

type OrtGetApiBaseFn = unsafe extern "C" fn() -> *const OrtApiBase;

/// Observed ONNX Runtime C-ABI capability probe result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrtRuntimeProbeResult {
    loaded: bool,
    dylib_path: Option<String>,
    version: Option<String>,
    cuda_ep_available: bool,
    tensorrt_ep_available: bool,
}

impl OrtRuntimeProbeResult {
    pub fn unavailable() -> Self {
        Self {
            loaded: false,
            dylib_path: None,
            version: None,
            cuda_ep_available: false,
            tensorrt_ep_available: false,
        }
    }

    pub fn synthetic(
        version: impl Into<String>,
        cuda_ep_available: bool,
        tensorrt_ep_available: bool,
    ) -> Self {
        Self {
            loaded: true,
            dylib_path: Some("synthetic://libonnxruntime.so".to_string()),
            version: Some(version.into()),
            cuda_ep_available,
            tensorrt_ep_available,
        }
    }

    pub fn loaded(&self) -> bool {
        self.loaded
    }

    pub fn dylib_path(&self) -> Option<&str> {
        self.dylib_path.as_deref()
    }

    pub fn version(&self) -> Option<&str> {
        self.version.as_deref()
    }

    pub fn cuda_ep_available(&self) -> bool {
        self.cuda_ep_available
    }

    pub fn tensorrt_ep_available(&self) -> bool {
        self.tensorrt_ep_available
    }
}

#[cfg(unix)]
struct DlHandle(*mut core::ffi::c_void);

#[cfg(unix)]
impl DlHandle {
    fn open(path: &Path) -> Result<Self, CapabilityError> {
        let path_str = path.to_str().ok_or_else(|| {
            CapabilityError::ort_runtime_unavailable("ORT_DYLIB_PATH is not valid UTF-8")
        })?;
        let c_path = CString::new(path_str).map_err(|_| {
            CapabilityError::ort_runtime_unavailable("ORT_DYLIB_PATH contains interior NUL byte")
        })?;

        // SAFETY: `c_path` is a valid NUL-terminated C string that outlives the
        // `dlopen` call. `RTLD_NOW | RTLD_LOCAL` resolves relocations immediately
        // without polluting the global symbol table; null return is checked below.
        let raw = unsafe { libc::dlopen(c_path.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL) };
        if raw.is_null() {
            let detail = last_dlerror_message();
            return Err(CapabilityError::ort_runtime_unavailable(format!(
                "dlopen('{path_str}') failed: {detail}"
            )));
        }
        Ok(Self(raw))
    }

    fn has_symbol(&self, symbol: &CStr) -> bool {
        // SAFETY: `self.0` is a non-null handle returned by `dlopen` and owned
        // exclusively by `self`; `symbol` is a valid NUL-terminated `CStr`.
        let ptr = unsafe { libc::dlsym(self.0, symbol.as_ptr()) };
        !ptr.is_null()
    }

    fn resolve_api_version(&self) -> Result<String, CapabilityError> {
        // SAFETY: `self.0` is a valid `dlopen` handle and `c"OrtGetApiBase"` is a
        // NUL-terminated static C string matching the ONNX Runtime C ABI symbol.
        let sym = unsafe { libc::dlsym(self.0, c"OrtGetApiBase".as_ptr()) };
        if sym.is_null() {
            return Err(CapabilityError::ort_runtime_unavailable(
                "symbol 'OrtGetApiBase' missing from ONNX Runtime shared library",
            ));
        }

        // SAFETY: `OrtGetApiBase` is defined by ONNX Runtime's stable C ABI as
        // `const OrtApiBase* OrtGetApiBase(void)` taking zero arguments and
        // returning a static struct pointer valid for the lifetime of `self`.
        let get_api_base: OrtGetApiBaseFn = unsafe { core::mem::transmute(sym) };
        // SAFETY: Invoking `OrtGetApiBase()` has no preconditions once loaded;
        // returned pointer is checked for null before dereferencing.
        let base_ptr = unsafe { get_api_base() };
        if base_ptr.is_null() {
            return Err(CapabilityError::ort_runtime_unavailable(
                "OrtGetApiBase() returned null pointer",
            ));
        }

        // SAFETY: `base_ptr` is non-null and points to ONNX Runtime's static
        // `OrtApiBase` vtable while `self` keeps the shared library mapped.
        let version_fn = unsafe { (*base_ptr).get_version_string }.ok_or_else(|| {
            CapabilityError::ort_runtime_unavailable(
                "OrtApiBase.GetVersionString function pointer is null",
            )
        })?;

        // SAFETY: `GetVersionString` takes no arguments and returns a static
        // NUL-terminated version string owned by `libonnxruntime`.
        let ver_ptr = unsafe { version_fn() };
        if ver_ptr.is_null() {
            return Err(CapabilityError::ort_runtime_unavailable(
                "OrtApiBase.GetVersionString() returned null",
            ));
        }

        // SAFETY: `ver_ptr` is a valid static NUL-terminated C string for the
        // lifetime of `self`; we immediately clone it into an owned `String`.
        let ver = unsafe { CStr::from_ptr(ver_ptr) }
            .to_string_lossy()
            .into_owned();
        Ok(ver)
    }
}

#[cfg(unix)]
impl Drop for DlHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: `self.0` was obtained from a successful `libc::dlopen` and
            // no borrowed pointers into the library escape `probe_ort_dylib`.
            unsafe {
                let _ = libc::dlclose(self.0);
            }
        }
    }
}

#[cfg(unix)]
fn last_dlerror_message() -> String {
    // SAFETY: `dlerror` takes no arguments and returns either null or a thread-local
    // NUL-terminated error string valid until the next `dl*` call on this thread.
    let err_ptr = unsafe { libc::dlerror() };
    if err_ptr.is_null() {
        "unknown dlopen error".to_string()
    } else {
        // SAFETY: `err_ptr` was checked non-null immediately above.
        unsafe { CStr::from_ptr(err_ptr) }
            .to_string_lossy()
            .into_owned()
    }
}

/// Probes an ONNX Runtime shared library via `OrtGetApiBase` and checks CUDA /
/// TensorRT execution-provider C-ABI symbols.
#[cfg(unix)]
pub fn probe_ort_dylib(path: &Path) -> Result<OrtRuntimeProbeResult, CapabilityError> {
    if !path.exists() {
        return Err(CapabilityError::ort_runtime_unavailable(format!(
            "ONNX Runtime library does not exist at {}",
            path.display()
        )));
    }
    let handle = DlHandle::open(path)?;
    let version = handle.resolve_api_version()?;
    let cuda_ep = handle.has_symbol(c"OrtSessionOptionsAppendExecutionProvider_CUDA")
        || handle.has_symbol(c"OrtSessionOptionsAppendExecutionProvider_CUDA_V2");
    let trt_ep = handle.has_symbol(c"OrtSessionOptionsAppendExecutionProvider_TensorRT")
        || handle.has_symbol(c"OrtSessionOptionsAppendExecutionProvider_TensorRT_V2");

    Ok(OrtRuntimeProbeResult {
        loaded: true,
        dylib_path: Some(path.display().to_string()),
        version: Some(version),
        cuda_ep_available: cuda_ep,
        tensorrt_ep_available: trt_ep,
    })
}

#[cfg(not(unix))]
pub fn probe_ort_dylib(path: &Path) -> Result<OrtRuntimeProbeResult, CapabilityError> {
    Err(CapabilityError::ort_runtime_unavailable(format!(
        "dynamic ONNX Runtime loading is only supported on Unix targets ({})",
        path.display()
    )))
}

/// Searches standard Linux container library locations when `ORT_DYLIB_PATH` is
/// not explicitly set.
pub fn discover_default_ort_dylib() -> Option<std::path::PathBuf> {
    let candidates = [
        "/usr/local/lib/libonnxruntime.so",
        "/usr/lib/libonnxruntime.so",
        "/usr/lib/x86_64-linux-gnu/libonnxruntime.so",
        "/usr/lib/aarch64-linux-gnu/libonnxruntime.so",
    ];
    candidates
        .into_iter()
        .map(std::path::PathBuf::from)
        .find(|p| p.exists())
}
