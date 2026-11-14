#![deny(unsafe_op_in_unsafe_fn)]

use std::error::Error as StdError;
use std::ffi::{CStr, CString};
use std::fmt;
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::thread;
use std::time::Duration;

#[repr(C)]
struct Job {
    _private: [u8; 0],
}

type JobPtr = *mut Job;

unsafe extern "C" {
    fn rill_abi_version() -> c_int;
    fn rill_init(workers: usize) -> c_int;
    fn rill_shutdown() -> c_int;
    fn rill_extract_json(
        url: *const c_char,
        options: *const c_char,
        json_out: *mut *mut c_char,
        error_out: *mut *mut c_char,
        error_code_out: *mut *mut c_char,
    ) -> c_int;
    fn rill_free_string(value: *mut c_char);

    fn rill_download_start(
        url: *const c_char,
        output: *const c_char,
        options: *const c_char,
        error_out: *mut *mut c_char,
    ) -> JobPtr;
    fn rill_download_poll(
        job: JobPtr,
        state: *mut c_int,
        downloaded: *mut i64,
        total: *mut i64,
    ) -> c_int;
    fn rill_download_error(job: JobPtr) -> *mut c_char;
    fn rill_download_error_code(job: JobPtr) -> *mut c_char;
    fn rill_download_cancel(job: JobPtr) -> c_int;
    fn rill_download_free(job: JobPtr);
}

#[derive(Debug, Clone)]
pub struct Error {
    code: i32,
    kind: Option<String>,
    message: String,
}

impl Error {
    pub fn code(&self) -> i32 {
        self.code
    }

    pub fn kind(&self) -> Option<&str> {
        self.kind.as_deref()
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    fn invalid_argument(message: impl Into<String>) -> Self {
        Self {
            code: 3,
            kind: Some("invalid_argument".to_string()),
            message: message.into(),
        }
    }

    unsafe fn from_c(code: i32, message: *mut c_char, kind: *mut c_char) -> Self {
        let kind = unsafe { take_string(kind) };
        Self {
            code,
            kind: if kind.is_empty() { None } else { Some(kind) },
            message: unsafe { take_string(message) },
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)
    }
}

impl StdError for Error {}

pub fn abi_version() -> i32 {
    unsafe { rill_abi_version() }
}

pub fn init(workers: usize) -> Result<(), Error> {
    let status = unsafe { rill_init(workers) };
    if status == 0 {
        Ok(())
    } else {
        Err(Error {
            code: status,
            kind: None,
            message: "rill_init failed".to_string(),
        })
    }
}

pub fn shutdown() -> Result<(), Error> {
    let status = unsafe { rill_shutdown() };
    if status == 0 {
        Ok(())
    } else {
        Err(Error {
            code: status,
            kind: None,
            message: "rill_shutdown failed".to_string(),
        })
    }
}

#[cfg(feature = "tokio")]
pub async fn extract_json_async(url: String, options: Option<String>) -> Result<String, Error> {
    tokio::task::spawn_blocking(move || extract_json(&url, options.as_deref()))
        .await
        .map_err(|error| Error {
            code: 2,
            kind: Some("internal".to_string()),
            message: error.to_string(),
        })?
}

pub fn extract_json(url: &str, options: Option<&str>) -> Result<String, Error> {
    let url = CString::new(url).map_err(|_| Error::invalid_argument("URL contains a NUL byte"))?;
    let options = options
        .map(CString::new)
        .transpose()
        .map_err(|_| Error::invalid_argument("options contain a NUL byte"))?;

    let mut json = ptr::null_mut();
    let mut error = ptr::null_mut();
    let mut kind = ptr::null_mut();

    let status = unsafe {
        rill_extract_json(
            url.as_ptr(),
            options.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
            &mut json,
            &mut error,
            &mut kind,
        )
    };

    if status != 0 {
        return Err(unsafe { Error::from_c(status, error, kind) });
    }

    Ok(unsafe { take_string(json) })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DownloadState {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

impl DownloadState {
    fn from_raw(value: c_int) -> Self {
        match value {
            0 => Self::Queued,
            1 => Self::Running,
            2 => Self::Completed,
            3 => Self::Failed,
            4 => Self::Cancelled,
            _ => Self::Failed,
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct DownloadProgress {
    pub state: DownloadState,
    pub downloaded: i64,
    pub total: i64,
}

pub struct Download {
    handle: JobPtr,
}

impl Download {
    pub fn start(url: &str, output: &str, options: Option<&str>) -> Result<Self, Error> {
        let url =
            CString::new(url).map_err(|_| Error::invalid_argument("URL contains a NUL byte"))?;
        let output = CString::new(output)
            .map_err(|_| Error::invalid_argument("output path contains a NUL byte"))?;
        let options = options
            .map(CString::new)
            .transpose()
            .map_err(|_| Error::invalid_argument("options contain a NUL byte"))?;

        let mut error = ptr::null_mut();
        let handle = unsafe {
            rill_download_start(
                url.as_ptr(),
                output.as_ptr(),
                options.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
                &mut error,
            )
        };

        if handle.is_null() {
            let message = unsafe { take_string(error) };
            return Err(Error {
                code: 2,
                kind: Some("internal".to_string()),
                message: if message.is_empty() {
                    "download start failed".to_string()
                } else {
                    message
                },
            });
        }

        Ok(Self { handle })
    }

    pub fn poll(&self) -> Result<DownloadProgress, Error> {
        let mut state = 0;
        let mut downloaded = 0;
        let mut total = 0;

        let status =
            unsafe { rill_download_poll(self.handle, &mut state, &mut downloaded, &mut total) };
        if status != 0 {
            return Err(Error {
                code: status,
                kind: None,
                message: "rill_download_poll failed".to_string(),
            });
        }

        Ok(DownloadProgress {
            state: DownloadState::from_raw(state),
            downloaded,
            total,
        })
    }

    pub fn cancel(&self) -> Result<(), Error> {
        let status = unsafe { rill_download_cancel(self.handle) };
        if status == 0 {
            Ok(())
        } else {
            Err(Error {
                code: status,
                kind: None,
                message: "rill_download_cancel failed".to_string(),
            })
        }
    }

    pub fn error(&self) -> String {
        unsafe { take_string(rill_download_error(self.handle)) }
    }

    pub fn error_code(&self) -> String {
        unsafe { take_string(rill_download_error_code(self.handle)) }
    }

    pub fn wait(&self, interval: Duration) -> Result<DownloadProgress, Error> {
        loop {
            let progress = self.poll()?;
            if progress.state.is_terminal() {
                return Ok(progress);
            }
            thread::sleep(interval);
        }
    }

    #[cfg(feature = "tokio")]
    pub async fn wait_async(&self, interval: Duration) -> Result<DownloadProgress, Error> {
        loop {
            let progress = self.poll()?;
            if progress.state.is_terminal() {
                return Ok(progress);
            }
            tokio::time::sleep(interval).await;
        }
    }
}

unsafe impl Send for Download {}
unsafe impl Sync for Download {}

impl Drop for Download {
    fn drop(&mut self) {
        unsafe { rill_download_free(self.handle) };
    }
}

unsafe fn take_string(value: *mut c_char) -> String {
    if value.is_null() {
        return String::new();
    }

    let text = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    unsafe {
        rill_free_string(value);
    }
    text
}
