use std::ffi::{OsStr, OsString};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use crate::model::InstallerError;
use wait_timeout::ChildExt;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub fn command(program: impl AsRef<OsStr>) -> Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let mut command = Command::new(program);
        command.creation_flags(CREATE_NO_WINDOW);
        command
    }
    #[cfg(not(windows))]
    {
        Command::new(program)
    }
}

pub fn run(
    program: &Path,
    args: &[OsString],
    input: Option<&[u8]>,
    context: &str,
) -> Result<Output, InstallerError> {
    run_timeout(program, args, input, context, Duration::from_secs(600))
}

pub fn run_timeout(
    program: &Path,
    args: &[OsString],
    input: Option<&[u8]>,
    context: &str,
    timeout: Duration,
) -> Result<Output, InstallerError> {
    let mut command = command(program.as_os_str());
    command
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if input.is_some() {
        command.stdin(Stdio::piped());
    } else {
        command.stdin(Stdio::null());
    }

    let mut child = command.spawn().map_err(|error| {
        InstallerError::new(
            format!("Couldn’t start {context}"),
            "Check that the required helper is available, then detect the device again.",
            format!("{}: {error}", program.display()),
        )
    })?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| InstallerError::internal(context, "stdout was unavailable"))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| InstallerError::internal(context, "stderr was unavailable"))?;
    let stdout_reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.read_to_end(&mut bytes);
        (result, bytes)
    });
    let stderr_reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stderr.read_to_end(&mut bytes);
        (result, bytes)
    });

    if let Some(bytes) = input {
        child
            .stdin
            .take()
            .ok_or_else(|| InstallerError::internal(context, "stdin was unavailable"))?
            .write_all(bytes)
            .map_err(|error| InstallerError::internal(context, error))?;
    }
    let status = match child
        .wait_timeout(timeout)
        .map_err(|error| InstallerError::internal(context, error))?
    {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(InstallerError::new(
                format!("{context} stopped responding"),
                "Check the modem connection and try detection again.",
                format!(
                    "{} exceeded the {} second timeout",
                    program.display(),
                    timeout.as_secs()
                ),
            ));
        }
    };
    let (stdout_result, stdout) = stdout_reader
        .join()
        .map_err(|_| InstallerError::internal(context, "stdout reader panicked"))?;
    stdout_result.map_err(|error| InstallerError::internal(context, error))?;
    let (stderr_result, stderr) = stderr_reader
        .join()
        .map_err(|_| InstallerError::internal(context, "stderr reader panicked"))?;
    stderr_result.map_err(|error| InstallerError::internal(context, error))?;
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

pub fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let names: Vec<OsString> = if cfg!(windows) && !name.to_ascii_lowercase().ends_with(".exe") {
        vec![format!("{name}.exe").into(), name.into()]
    } else {
        vec![name.into()]
    };
    std::env::split_paths(&path)
        .flat_map(|directory| names.iter().map(move |name| directory.join(name)))
        .find(|candidate| candidate.is_file())
}

pub fn output_text(output: &Output) -> (String, String) {
    (
        String::from_utf8_lossy(&output.stdout).trim().to_owned(),
        String::from_utf8_lossy(&output.stderr).trim().to_owned(),
    )
}
