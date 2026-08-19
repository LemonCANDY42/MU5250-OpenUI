use std::collections::HashMap;
use std::ffi::OsString;
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use flate2::read::GzDecoder;
use reqwest::blocking::Client;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use ssh_key::{Algorithm, LineEnding, PrivateKey};
use tar::Archive;
use tauri::{AppHandle, Emitter};

use crate::device::{adb_args, compatible_adb_devices};
use crate::model::{
    InstallMode, InstallOutcome, InstallRequest, InstallerError, Operation, ProgressEvent,
};
use crate::process::{find_on_path, output_text, run};
use crate::unlock;

const REPOSITORY: &str = "dklasens/MU5250-OpenUI";
const RELEASE_API: &str = "https://api.github.com/repos/dklasens/MU5250-OpenUI/releases/latest";
const DROPBEAR_URL: &str = "https://downloads.openwrt.org/releases/23.05.4/targets/armsr/armv8/packages/dropbear_2022.82-6_aarch64_generic.ipk";
const DROPBEAR_SHA256: &str = "4fadd1b8529f22fb5d64ee27159d11f4feb68224657953d298a1acf85a83a5c0";
const DASHBOARD_HTTPD_URL: &str = "https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_generic/base/uhttpd_2023-06-25-34a8a74d-2_aarch64_generic.ipk";
const DASHBOARD_HTTPD_SHA256: &str =
    "bd3f010e71a5ea2ef6405e44dbe8c9e697454ce954c197f177ff0c13b9cf5991";
const REMOTE_BIN: &str = "/data/zte-agent";
const STARTUP_SCRIPT: &str = "/data/local/tmp/start_zte_agent.sh";
const DASHBOARD_STARTUP_SCRIPT: &str = "/data/local/tmp/start_dashboard.sh";

#[derive(Clone)]
pub struct Reporter {
    app: AppHandle,
}

impl Reporter {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }

    fn emit(
        &self,
        kind: &str,
        message: impl Into<String>,
        step: Option<&str>,
        status: Option<&str>,
    ) {
        let _ = self.app.emit(
            "installer-progress",
            ProgressEvent {
                kind: kind.into(),
                message: message.into(),
                step: step.map(str::to_owned),
                status: status.map(str::to_owned),
            },
        );
    }

    pub fn log(&self, message: impl Into<String>) {
        self.emit("log", message, None, None);
    }

    pub fn active(&self, step: &str, message: &str) {
        self.emit("operation", message, Some(step), Some("running"));
    }

    pub fn step(&self, step: &str, status: &str, message: &str) {
        self.emit("step", message, Some(step), Some(status));
    }
}

enum Channel {
    Adb {
        executable: PathBuf,
        serial: String,
    },
    Ssh {
        executable: PathBuf,
        gateway: String,
        known_hosts: PathBuf,
    },
}

impl Channel {
    fn name(&self) -> &'static str {
        match self {
            Self::Adb { .. } => "ADB",
            Self::Ssh { .. } => "SSH",
        }
    }

    fn shell(&self, command: &str, check: bool) -> Result<String, InstallerError> {
        match self {
            Self::Adb { executable, serial } => {
                let marker = "__MU5250_RC__";
                let wrapped = format!("({command}); printf '\\n{marker}%s\\n' $?");
                let args = adb_args(serial, &["shell", &wrapped]);
                let output = run(executable, &args, None, "an ADB command")?;
                let (stdout, stderr) = output_text(&output);
                let marker_index = stdout.rfind(marker);
                let (body, remote_code) = marker_index.map_or((stdout.as_str(), 1), |index| {
                    let code = stdout[index + marker.len()..]
                        .trim()
                        .parse::<i32>()
                        .unwrap_or(1);
                    (stdout[..index].trim(), code)
                });
                if check && (!output.status.success() || remote_code != 0) {
                    return Err(InstallerError::new(
                        "The modem rejected an ADB operation",
                        "Keep the modem connected. Copy the technical details before retrying.",
                        format!(
                            "Remote exit code {remote_code}\nCommand: {command}\n{body}\n{stderr}"
                        ),
                    ));
                }
                Ok(body.trim().to_owned())
            }
            Self::Ssh {
                executable,
                gateway,
                known_hosts,
            } => {
                let args = ssh_args(gateway, known_hosts, command);
                let output = run(executable, &args, None, "an SSH command")?;
                let (stdout, stderr) = output_text(&output);
                if check && !output.status.success() {
                    return Err(InstallerError::new(
                        "The modem rejected an SSH operation",
                        "Check that the modem is still reachable and retry. Existing files are left intact.",
                        format!("Exit code {:?}\nCommand: {command}\n{stdout}\n{stderr}", output.status.code()),
                    ));
                }
                Ok(stdout)
            }
        }
    }

    fn push(&self, local: &Path, remote: &str) -> Result<(), InstallerError> {
        match self {
            Self::Adb { executable, serial } => {
                let args = vec![
                    "-s".into(),
                    serial.into(),
                    "push".into(),
                    local.as_os_str().to_owned(),
                    remote.into(),
                ];
                let output = run(executable, &args, None, "an ADB file transfer")?;
                if !output.status.success() {
                    let (stdout, stderr) = output_text(&output);
                    return Err(InstallerError::new(
                        "A file could not be copied to the modem",
                        "Reconnect the USB cable and retry.",
                        format!("adb push {} {remote}\n{stdout}\n{stderr}", local.display()),
                    ));
                }
            }
            Self::Ssh {
                executable,
                gateway,
                known_hosts,
            } => {
                let bytes = fs::read(local).map_err(|error| {
                    InstallerError::internal("reading a deployment file", error)
                })?;
                let args = ssh_args(
                    gateway,
                    known_hosts,
                    &format!("cat > {}", shell_quote(remote)),
                );
                let output = run(executable, &args, Some(&bytes), "an SSH file transfer")?;
                if !output.status.success() {
                    let (stdout, stderr) = output_text(&output);
                    return Err(InstallerError::new(
                        "A file could not be copied to the modem",
                        "Keep the modem connected and retry.",
                        format!("SSH stream to {remote}\n{stdout}\n{stderr}"),
                    ));
                }
            }
        }
        Ok(())
    }

    fn reboot(&self) -> Result<(), InstallerError> {
        if let Self::Adb { executable, serial } = self {
            let output = run(
                executable,
                &adb_args(serial, &["reboot"]),
                None,
                "ADB reboot",
            )?;
            if !output.status.success() {
                let (stdout, stderr) = output_text(&output);
                return Err(InstallerError::new(
                    "Installation succeeded, but the modem did not reboot",
                    "Reboot it manually to restore normal USB tethering.",
                    format!("adb reboot\n{stdout}\n{stderr}"),
                ));
            }
        }
        Ok(())
    }
}

fn ssh_args(gateway: &str, known_hosts: &Path, command: &str) -> Vec<OsString> {
    vec![
        "-p".into(),
        "2222".into(),
        "-o".into(),
        "BatchMode=yes".into(),
        "-o".into(),
        "StrictHostKeyChecking=accept-new".into(),
        "-o".into(),
        format!("UserKnownHostsFile={}", known_hosts.display()).into(),
        "-o".into(),
        "ConnectTimeout=10".into(),
        format!("root@{gateway}").into(),
        command.into(),
    ]
}

fn ssh_channel(gateway: &str) -> Result<Channel, InstallerError> {
    let executable = find_on_path("ssh").ok_or_else(|| {
        InstallerError::new(
            "The SSH client is not available",
            "On Windows, enable the OpenSSH Client optional feature, then detect again.",
            "Could not find ssh or ssh.exe on PATH.",
        )
    })?;
    let home = dirs::home_dir().ok_or_else(|| {
        InstallerError::internal("locating the SSH directory", "home directory unavailable")
    })?;
    let known_hosts = home.join(".ssh/known_hosts.d/zte");
    if let Some(parent) = known_hosts.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            InstallerError::internal("creating the SSH known-hosts directory", error)
        })?;
    }
    Ok(Channel::Ssh {
        executable,
        gateway: gateway.into(),
        known_hosts,
    })
}

fn ssh_up(gateway: &str) -> bool {
    let channel = match ssh_channel(gateway) {
        Ok(channel) => channel,
        Err(_) => return false,
    };
    channel.shell("true", true).is_ok()
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn wait_for_modem_adb(adb: &Path, reporter: &Reporter) -> Result<String, InstallerError> {
    let deadline = Instant::now() + Duration::from_secs(240);
    while Instant::now() < deadline {
        if let Ok(devices) = compatible_adb_devices(adb) {
            if devices.len() == 1 {
                return Ok(devices[0].serial.clone());
            }
            if devices.len() > 1 {
                return Err(InstallerError::new(
                    "More than one compatible modem appeared after reboot",
                    "Disconnect the modem you do not want to change, then detect again.",
                    format!(
                        "Compatible serials: {}",
                        devices
                            .iter()
                            .map(|device| device.serial.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                ));
            }
        }
        reporter.log("[*] Waiting for the ZTE modem to appear over ADB…");
        std::thread::sleep(Duration::from_secs(3));
    }
    Err(InstallerError::new(
        "The modem did not appear in ADB after reboot",
        "Check the USB cable. On Windows, install or select an ADB-compatible USB driver, then detect again.",
        "No compatible ZTE MU5250 transport appeared within 240 seconds.",
    ))
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    assets: Vec<GitHubAsset>,
}

#[derive(Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
}

struct ReleaseAssets {
    tag: String,
    urls: HashMap<String, String>,
}

fn latest_release() -> Result<ReleaseAssets, InstallerError> {
    let client = Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(60))
        .user_agent("open-u60-pro-installer")
        .build()
        .map_err(|error| InstallerError::internal("creating the download client", error))?;
    let release: GitHubRelease = client
        .get(RELEASE_API)
        .send()
        .and_then(reqwest::blocking::Response::error_for_status)
        .and_then(reqwest::blocking::Response::json)
        .map_err(|error| {
            InstallerError::new(
                "The latest installer files could not be found",
                "Check the internet connection and try again.",
                format!("GET {RELEASE_API}: {error}"),
            )
        })?;
    let urls = release
        .assets
        .into_iter()
        .map(|asset| (asset.name, asset.browser_download_url))
        .collect::<HashMap<_, _>>();
    for required in ["zte-agent", "dashboard-dist.tar.gz", "sha256sums.txt"] {
        if !urls.contains_key(required) {
            return Err(InstallerError::new(
                "The latest release is incomplete",
                "Try again later or report the release packaging problem.",
                format!(
                    "Release {} in {REPOSITORY} is missing {required}",
                    release.tag_name
                ),
            ));
        }
    }
    Ok(ReleaseAssets {
        tag: release.tag_name,
        urls,
    })
}

fn download(url: &str, destination: &Path) -> Result<Vec<u8>, InstallerError> {
    let client = Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(180))
        .user_agent("open-u60-pro-installer")
        .build()
        .map_err(|error| InstallerError::internal("creating the download client", error))?;
    let bytes = client
        .get(url)
        .send()
        .and_then(reqwest::blocking::Response::error_for_status)
        .and_then(reqwest::blocking::Response::bytes)
        .map_err(|error| {
            InstallerError::new(
                "An installation file could not be downloaded",
                "Check the internet connection and try again.",
                format!("GET {url}: {error}"),
            )
        })?
        .to_vec();
    fs::write(destination, &bytes)
        .map_err(|error| InstallerError::internal("saving a download", error))?;
    Ok(bytes)
}

fn fetch_release_assets(
    release: &ReleaseAssets,
    work: &Path,
    reporter: &Reporter,
) -> Result<HashMap<String, PathBuf>, InstallerError> {
    reporter.log(format!("[*] Using release {}", release.tag));
    reporter.log("[*] Downloading release checksums…");
    let sums_bytes = download(
        &release.urls["sha256sums.txt"],
        &work.join("sha256sums.txt"),
    )?;
    let sums_text = String::from_utf8_lossy(&sums_bytes);
    let sums = sums_text
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let sum = fields.next()?.to_owned();
            let name = fields.next()?.trim_start_matches('*').to_owned();
            Some((name, sum))
        })
        .collect::<HashMap<_, _>>();
    let mut files = HashMap::new();
    for name in ["zte-agent", "dashboard-dist.tar.gz"] {
        let expected = sums.get(name).ok_or_else(|| {
            InstallerError::new(
                "A release checksum is missing",
                "No downloaded files were installed. Report the release packaging problem.",
                format!("sha256sums.txt has no entry for {name}"),
            )
        })?;
        reporter.log(format!("[*] Downloading {name}…"));
        let path = work.join(name);
        let bytes = download(&release.urls[name], &path)?;
        let actual = hex::encode(Sha256::digest(&bytes));
        if &actual != expected {
            return Err(InstallerError::new(
                "A downloaded file failed integrity verification",
                "Nothing from the failed download was installed. Retry on a trusted network.",
                format!("{name}: expected {expected}, received {actual}"),
            ));
        }
        reporter.log(format!("[+] {name} verified (SHA-256 {}…)", &actual[..16]));
        files.insert(name.into(), path);
    }
    Ok(files)
}

fn startup_script(password: &str, pin: &str) -> String {
    let mut lines = vec![
        "#!/bin/sh".to_owned(),
        format!("export ZTE_AGENT_PASSWORD={}", shell_quote(password)),
    ];
    if !pin.is_empty() {
        lines.push(format!("export ZTE_AGENT_PIN={}", shell_quote(pin)));
    }
    lines.extend([
        "# Log via syslog (logd's fixed-size ring buffer) rather than a file on /tmp:".into(),
        "# Read it back with: logread -e zte-agent".into(),
        "nohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &"
            .into(),
    ]);
    format!("{}\n", lines.join("\n"))
}

fn adb_agent_login_command(gateway: &str, password: &str) -> String {
    let payload = json!({ "password": password }).to_string();
    format!(
        "/usr/bin/curl --fail --silent --show-error --connect-timeout 5 --max-time 10 -H 'Content-Type: application/json' --data-binary {} {}",
        shell_quote(&payload),
        shell_quote(&format!("http://{gateway}:9090/api/auth/login")),
    )
}

fn agent_login(channel: &Channel, gateway: &str, password: &str) -> bool {
    let result = match channel {
        Channel::Adb { .. } => channel.shell(&adb_agent_login_command(gateway, password), true),
        Channel::Ssh { .. } => Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(10))
            .build()
            .and_then(|client| {
                client
                    .post(format!("http://{gateway}:9090/api/auth/login"))
                    .json(&json!({ "password": password }))
                    .send()
            })
            .and_then(reqwest::blocking::Response::error_for_status)
            .and_then(reqwest::blocking::Response::text)
            .map_err(|error| InstallerError::internal("verifying the agent", error)),
    };
    result
        .ok()
        .and_then(|body| serde_json::from_str::<Value>(&body).ok())
        .and_then(|value| {
            value
                .pointer("/data/token")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .is_some()
}

fn deploy_agent(
    channel: &Channel,
    gateway: &str,
    password: &str,
    pin: &str,
    files: &HashMap<String, PathBuf>,
    work: &Path,
    reporter: &Reporter,
) -> Result<(), InstallerError> {
    let local = &files["zte-agent"];
    let local_bytes =
        fs::read(local).map_err(|error| InstallerError::internal("reading zte-agent", error))?;
    let local_sha = hex::encode(Sha256::digest(&local_bytes));
    let remote_sha = channel.shell(
        &format!("sha256sum {REMOTE_BIN} 2>/dev/null | awk '{{print $1}}'"),
        false,
    )?;
    let changed = remote_sha != local_sha;
    if changed {
        reporter.log("[*] Stopping the existing agent and copying the verified binary…");
        channel.shell("killall zte-agent 2>/dev/null; sleep 1", false)?;
        channel.push(local, REMOTE_BIN)?;
        channel.shell(&format!("chmod +x {REMOTE_BIN}"), true)?;
        reporter.log("[+] Agent binary installed");
    } else {
        reporter.log("[+] Agent binary is already current");
    }

    let marker = shell_quote(&format!("ZTE_AGENT_PASSWORD={}", shell_quote(password)));
    let current = channel.shell(
        &format!("grep -qF {marker} {STARTUP_SCRIPT} 2>/dev/null && grep -qF 'logger -t zte-agent' {STARTUP_SCRIPT} 2>/dev/null && echo OK"),
        false,
    )?;
    if current.trim() != "OK" {
        let script_path = work.join("start_zte_agent.sh");
        fs::write(&script_path, startup_script(password, pin)).map_err(|error| {
            InstallerError::internal("creating the agent startup script", error)
        })?;
        channel.shell("mkdir -p /data/local/tmp", true)?;
        channel.push(&script_path, STARTUP_SCRIPT)?;
        channel.shell(&format!("chmod 700 {STARTUP_SCRIPT}"), true)?;
        reporter.log("[+] Agent credentials and startup script updated");
    } else {
        reporter.log("[+] Agent startup script is already current");
    }

    let rc_line = format!("sh {STARTUP_SCRIPT}");
    if channel
        .shell(
            &format!(
                "grep -qF '{}' /etc/rc.local 2>/dev/null && echo OK",
                rc_line
            ),
            false,
        )?
        .trim()
        != "OK"
    {
        channel.shell(&format!("grep -q '^exit 0' /etc/rc.local && sed -i '/^exit 0/i {rc_line}' /etc/rc.local || echo {rc_line} >> /etc/rc.local"), true)?;
        reporter.log("[+] Agent auto-start added to rc.local");
    }

    if changed || !agent_login(channel, gateway, password) {
        reporter.log("[*] Starting the agent…");
        channel.shell("killall zte-agent 2>/dev/null; true", false)?;
        std::thread::sleep(Duration::from_secs(1));
        channel.shell(&format!("sh {STARTUP_SCRIPT}"), true)?;
        std::thread::sleep(Duration::from_secs(2));
    }
    if !agent_login(channel, gateway, password) {
        return Err(InstallerError::new(
            "The agent was installed but login verification failed",
            "Copy the log and retry. On an already provisioned modem, check logread -e zte-agent over SSH.",
            format!("Agent login at http://{gateway}:9090/api/auth/login returned no token via {}.", channel.name()),
        ));
    }
    reporter.log("[+] Agent is running and authenticated");
    Ok(())
}

fn ensure_local_ssh_key(reporter: &Reporter) -> Result<String, InstallerError> {
    let home = dirs::home_dir().ok_or_else(|| {
        InstallerError::internal(
            "locating the SSH key directory",
            "home directory unavailable",
        )
    })?;
    let directory = home.join(".ssh");
    let private_path = directory.join("id_ed25519");
    let public_path = directory.join("id_ed25519.pub");
    if private_path.is_file() && public_path.is_file() {
        return fs::read_to_string(public_path)
            .map(|value| value.trim().to_owned())
            .map_err(|error| InstallerError::internal("reading the SSH public key", error));
    }
    if private_path.exists() != public_path.exists() {
        return Err(InstallerError::new(
            "The default SSH key pair is incomplete",
            "Repair ~/.ssh/id_ed25519 and id_ed25519.pub, or move the incomplete file aside, then retry.",
            format!("Private key exists: {}; public key exists: {}", private_path.exists(), public_path.exists()),
        ));
    }
    fs::create_dir_all(&directory)
        .map_err(|error| InstallerError::internal("creating the SSH key directory", error))?;
    let key = PrivateKey::random(&mut rand::rngs::OsRng, Algorithm::Ed25519)
        .map_err(|error| InstallerError::internal("generating an Ed25519 SSH key", error))?;
    let private = key
        .to_openssh(LineEnding::LF)
        .map_err(|error| InstallerError::internal("encoding the SSH private key", error))?;
    let public = key
        .public_key()
        .to_openssh()
        .map_err(|error| InstallerError::internal("encoding the SSH public key", error))?;
    fs::write(&private_path, private.as_bytes())
        .map_err(|error| InstallerError::internal("saving the SSH private key", error))?;
    fs::write(&public_path, format!("{public}\n"))
        .map_err(|error| InstallerError::internal("saving the SSH public key", error))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&private_path, fs::Permissions::from_mode(0o600))
            .map_err(|error| InstallerError::internal("setting SSH key permissions", error))?;
    }
    reporter.log(format!(
        "[+] Generated a new Ed25519 key at {}",
        private_path.display()
    ));
    Ok(public)
}

fn verify_pinned_download(
    bytes: &[u8],
    expected: &str,
    package: &str,
) -> Result<(), InstallerError> {
    let actual = hex::encode(Sha256::digest(bytes));
    if actual == expected {
        return Ok(());
    }
    Err(InstallerError::new(
        format!("The {package} package failed integrity verification"),
        "Nothing from the package was installed. Retry on a trusted network.",
        format!("Expected SHA-256 {expected}, received {actual}"),
    ))
}

fn extract_ipk_data(ipk: &[u8], package: &str) -> Result<Vec<u8>, InstallerError> {
    let decoder = GzDecoder::new(Cursor::new(ipk));
    let mut archive = Archive::new(decoder);
    for item in archive
        .entries()
        .map_err(|error| InstallerError::internal("reading the Dropbear package", error))?
    {
        let mut entry = item
            .map_err(|error| InstallerError::internal("reading a Dropbear package entry", error))?;
        let path = entry
            .path()
            .map_err(|error| InstallerError::internal("reading a Dropbear package path", error))?;
        if path.file_name().and_then(|value| value.to_str()) == Some("data.tar.gz") {
            let mut bytes = Vec::new();
            entry.read_to_end(&mut bytes).map_err(|error| {
                InstallerError::internal("extracting package data.tar.gz", error)
            })?;
            return Ok(bytes);
        }
    }
    Err(InstallerError::new(
        format!("The downloaded {package} package has an unexpected layout"),
        "Nothing from the package was installed. Retry or report the packaging change.",
        "data.tar.gz was not found in the IPK.",
    ))
}

fn install_dashboard_httpd(
    channel: &Channel,
    work: &Path,
    reporter: &Reporter,
) -> Result<(), InstallerError> {
    let present = channel.shell(
        "if [ -f /data/bin/dashboard-uhttpd ] && [ -x /data/bin/dashboard-uhttpd ]; then printf '%s' PRESENT; else printf '%s' MISSING; fi",
        false,
    )?;
    if present.trim() == "PRESENT" {
        reporter.log("[+] Isolated dashboard web server is already installed");
        return Ok(());
    }

    reporter.log("[*] Downloading the isolated dashboard web server…");
    let ipk_path = work.join("uhttpd.ipk");
    let ipk = download(DASHBOARD_HTTPD_URL, &ipk_path)?;
    verify_pinned_download(&ipk, DASHBOARD_HTTPD_SHA256, "dashboard web server")?;
    let data = extract_ipk_data(&ipk, "dashboard web server")?;
    let data_path = work.join("uhttpd-data.tar.gz");
    fs::write(&data_path, data)
        .map_err(|error| InstallerError::internal("saving uhttpd data.tar.gz", error))?;
    channel.push(&data_path, "/tmp/uhttpd-data.tar.gz")?;
    channel.shell(
        "set -e\ncd /tmp\ntar xzf uhttpd-data.tar.gz ./usr/sbin/uhttpd\nmkdir -p /data/bin\ncp usr/sbin/uhttpd /data/bin/dashboard-uhttpd\nchmod +x /data/bin/dashboard-uhttpd\nrm -rf /tmp/usr /tmp/uhttpd-data.tar.gz",
        true,
    )?;
    let verify = channel.shell(
        "if [ -f /data/bin/dashboard-uhttpd ] && [ -x /data/bin/dashboard-uhttpd ]; then printf '%s' PRESENT; else printf '%s' MISSING; fi",
        false,
    )?;
    if verify.trim() != "PRESENT" {
        return Err(InstallerError::new(
            "The dashboard web server did not appear after installation",
            "Keep the modem connected and copy the diagnostic log before retrying.",
            format!("Explicit file/executable check returned {verify:?}"),
        ));
    }
    reporter.log("[+] Isolated dashboard web server installed and verified");
    Ok(())
}

fn harden(
    channel: &Channel,
    gateway: &str,
    work: &Path,
    reporter: &Reporter,
) -> Result<(), InstallerError> {
    let dropbear = channel.shell("if [ -f /data/bin/dropbear ] && [ -x /data/bin/dropbear ]; then printf '%s' PRESENT; else printf '%s' MISSING; fi", false)?;
    if dropbear.trim() == "PRESENT" {
        reporter.log("[+] Dropbear is already installed");
    } else {
        reporter.log("[*] Downloading and installing Dropbear…");
        let ipk_path = work.join("dropbear.ipk");
        let ipk = download(DROPBEAR_URL, &ipk_path)?;
        verify_pinned_download(&ipk, DROPBEAR_SHA256, "Dropbear")?;
        let data = extract_ipk_data(&ipk, "Dropbear")?;
        let data_path = work.join("data.tar.gz");
        fs::write(&data_path, data)
            .map_err(|error| InstallerError::internal("saving Dropbear data.tar.gz", error))?;
        channel.push(&data_path, "/tmp/data.tar.gz")?;
        channel.shell("cd /tmp && tar xzf data.tar.gz ./usr/sbin/dropbear ./usr/bin/dbclient ./usr/bin/dropbearkey && mkdir -p /data/bin && cp usr/sbin/dropbear usr/bin/dbclient usr/bin/dropbearkey /data/bin/ && chmod +x /data/bin/* && rm -rf /tmp/usr /tmp/data.tar.gz", true)?;
        let verify = channel.shell("if [ -f /data/bin/dropbear ] && [ -x /data/bin/dropbear ]; then printf '%s' PRESENT; else printf '%s' MISSING; fi", false)?;
        if verify.trim() != "PRESENT" {
            return Err(InstallerError::new(
                "Dropbear did not appear after installation",
                "Keep the modem connected and copy the diagnostic log before retrying.",
                format!("Explicit file/executable check returned {verify:?}"),
            ));
        }
        reporter.log("[+] Dropbear installed and explicitly verified");
    }

    reporter.log("[*] Configuring SSH keys and persistent host keys…");
    let public_key = ensure_local_ssh_key(reporter)?;
    let quoted_key = shell_quote(&public_key);
    channel.shell(
        "mkdir -p /etc/dropbear /data/dropbear && chmod 700 /etc/dropbear",
        true,
    )?;
    channel.shell(&format!("grep -qF {quoted_key} /etc/dropbear/authorized_keys 2>/dev/null || echo {quoted_key} >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys"), true)?;
    channel.shell("for k in ed25519 rsa; do f=/etc/dropbear/dropbear_${k}_host_key; [ -s \"$f\" ] || /data/bin/dropbearkey -t $k -f $f >/dev/null 2>&1; done", true)?;
    channel.shell("cp /etc/dropbear/authorized_keys /etc/dropbear/dropbear_*_host_key /data/dropbear/ 2>/dev/null; chmod 600 /data/dropbear/*", true)?;
    channel.shell("printf '#!/bin/sh\\n/data/bin/dropbear -p 2222 -r /etc/dropbear/dropbear_ed25519_host_key -r /etc/dropbear/dropbear_rsa_host_key\\n' > /data/local/tmp/start_dropbear.sh && chmod +x /data/local/tmp/start_dropbear.sh", true)?;

    install_dashboard_httpd(channel, work, reporter)?;

    reporter.log("[*] Configuring the isolated dashboard listener…");
    channel.shell(
        "set -e\nmkdir -p /data/www /data/local/tmp\nprintf '#!/bin/sh\nif [ -s /var/run/dashboard-uhttpd.pid ]; then\n  pid=$(cat /var/run/dashboard-uhttpd.pid)\n  kill \"$pid\" 2>/dev/null || true\nfi\nnohup /data/bin/dashboard-uhttpd -f -h /data/www -p 0.0.0.0:8080 -D >/tmp/dashboard-uhttpd.log 2>&1 </dev/null &\necho $! > /var/run/dashboard-uhttpd.pid\n' > /data/local/tmp/start_dashboard.sh\nchmod 700 /data/local/tmp/start_dashboard.sh\nuci -q delete uhttpd.dashboard || true\nuci commit uhttpd\n/etc/init.d/uhttpd restart",
        true,
    )?;

    reporter.log("[*] Validating the safe rc.local startup entries…");
    channel.shell(
        "grep -qF 'start_zte_agent.sh' /etc/rc.local || sed -i '/^exit 0/i sh /data/local/tmp/start_zte_agent.sh' /etc/rc.local\ngrep -qF 'start_dropbear.sh' /etc/rc.local || sed -i '/^exit 0/i sh /data/local/tmp/start_dropbear.sh' /etc/rc.local\ngrep -qF 'start_dashboard.sh' /etc/rc.local || sed -i '/^exit 0/i sh /data/local/tmp/start_dashboard.sh' /etc/rc.local\nsed -i '/^echo [0-9] > .*usb_op/d' /etc/rc.local\nsh -n /etc/rc.local",
        true,
    )?;
    reporter.log("[+] rc.local is configured and passes its syntax check");

    reporter.log("[*] Starting and checking the dashboard web service…");
    channel.shell(
        &format!("set -e\necho DASHBOARD_READY > /data/www/.installer-health\nsh {DASHBOARD_STARTUP_SCRIPT}"),
        true,
    )?;
    std::thread::sleep(Duration::from_secs(1));
    channel.shell("test \"$(/usr/bin/curl --fail --silent --show-error --connect-timeout 5 --max-time 10 http://127.0.0.1:8080/.installer-health)\" = DASHBOARD_READY && rm -f /data/www/.installer-health", true)?;
    reporter.log("[+] Dashboard listener is running on port 8080");

    reporter.log("[*] Disabling unattended firmware updates…");
    let fota = channel.shell("ubus call zwrt_zte_dm set_update_mode '{\"dm_update_mode\":\"0\"}' >/dev/null 2>&1; uci get zwrt_zte_dm.dm_update.dm_update_mode", false)?;
    if fota.lines().any(|line| line.trim() == "0") {
        reporter.log("[+] Unattended firmware updates are disabled");
    } else {
        reporter
            .log("[!] Firmware update mode could not be confirmed; check it after installation");
    }

    channel.shell(
        "pidof dropbear >/dev/null 2>&1 || sh /data/local/tmp/start_dropbear.sh",
        false,
    )?;
    std::thread::sleep(Duration::from_secs(2));
    if ssh_up(gateway) {
        reporter.log(format!("[+] SSH verified at root@{gateway}:2222"));
    } else {
        reporter.log(
            "[!] SSH is configured but may require the final reboot before it becomes reachable",
        );
    }
    Ok(())
}

fn deploy_dashboard(
    channel: &Channel,
    gateway: &str,
    files: &HashMap<String, PathBuf>,
    reporter: &Reporter,
) -> Result<(), InstallerError> {
    reporter.log("[*] Copying the dashboard to /data/www…");
    channel.push(
        &files["dashboard-dist.tar.gz"],
        "/tmp/dashboard-dist.tar.gz",
    )?;
    channel.shell("mkdir -p /data/www && tar xzf /tmp/dashboard-dist.tar.gz -C /data/www && cp /data/www/index.html /data/www/mobile.html && rm -f /tmp/dashboard-dist.tar.gz", true)?;
    channel.shell(&format!("sh {DASHBOARD_STARTUP_SCRIPT}"), true)?;
    std::thread::sleep(Duration::from_secs(1));
    let page = channel.shell("/usr/bin/curl --fail --silent --show-error --connect-timeout 5 --max-time 10 http://127.0.0.1:8080/", true)?;
    if !page.contains("<div id=\"root\"></div>") {
        return Err(InstallerError::new(
            "The dashboard was copied but its verification page was unexpected",
            "The previous dashboard files remain on the modem. Copy the log before retrying.",
            format!(
                "First response bytes: {}",
                page.chars().take(500).collect::<String>()
            ),
        ));
    }
    reporter.log(format!("[+] Dashboard verified at http://{gateway}:8080"));
    Ok(())
}

pub fn perform_install(
    request: InstallRequest,
    mode: InstallMode,
    operation: Operation,
    adb_path: Option<PathBuf>,
    selected_serial: Option<String>,
    work: &Path,
    reporter: Reporter,
) -> Result<InstallOutcome, InstallerError> {
    reporter.log(format!(
        "[*] {} started for {}",
        operation.label(),
        request.gateway
    ));
    reporter.log(format!("[*] Temporary workspace: {}", work.display()));

    let channel = match mode {
        InstallMode::Unlock => {
            reporter.active("unlock", "Preparing and validating the modem backup…");
            let unlock_work = work.join("unlock");
            unlock::run_unlock(
                &request.gateway,
                &request.router_password,
                &request.backup_suffix,
                request.dry_run,
                &unlock_work,
                &|message| reporter.log(message),
            )?;
            reporter.step("unlock", "complete", "Backup preparation complete");
            if request.dry_run {
                for step in ["wait", "agent", "ssh", "dashboard"] {
                    reporter.step(step, "skipped", "Not run during a dry run");
                }
                return Ok(InstallOutcome {
                    result: "dryRun".into(),
                    title: "Dry run completed safely".into(),
                    message: "The modem backup was downloaded, decrypted, checked, and patched in memory. Nothing was uploaded and the modem was not changed.".into(),
                    operation,
                    dashboard_url: None,
                    api_url: None,
                    ssh_address: None,
                    diagnostic_path: None,
                });
            }
            reporter.active("wait", "Waiting for the modem to restart in ADB mode…");
            let adb = adb_path.ok_or_else(|| {
                InstallerError::new(
                "ADB is unavailable after the restore",
                "Use the packaged installer or install Android platform-tools, then detect again.",
                "The detection snapshot had no ADB executable.",
            )
            })?;
            let serial = wait_for_modem_adb(&adb, &reporter)?;
            reporter.step("wait", "complete", "Modem reconnected over ADB");
            Channel::Adb {
                executable: adb,
                serial,
            }
        }
        InstallMode::Adb => {
            reporter.step("unlock", "skipped", "Already unlocked");
            reporter.step("wait", "skipped", "ADB is already connected");
            Channel::Adb {
                executable: adb_path.ok_or_else(|| {
                    InstallerError::internal("starting the ADB install", "ADB path missing")
                })?,
                serial: selected_serial.ok_or_else(|| {
                    InstallerError::internal("starting the ADB install", "ADB serial missing")
                })?,
            }
        }
        InstallMode::Ssh => {
            reporter.step("unlock", "skipped", "Already provisioned");
            reporter.step("wait", "skipped", "Using SSH");
            ssh_channel(&request.gateway)?
        }
    };
    reporter.log(format!("[+] Management channel: {}", channel.name()));

    reporter.active("agent", "Downloading and installing the latest agent…");
    let release = latest_release()?;
    let files = fetch_release_assets(&release, work, &reporter)?;
    deploy_agent(
        &channel,
        &request.gateway,
        &request.agent_password,
        &request.agent_pin,
        &files,
        work,
        &reporter,
    )?;
    reporter.step("agent", "complete", "Agent installed and authenticated");

    reporter.active("ssh", "Configuring secure SSH access…");
    harden(&channel, &request.gateway, work, &reporter)?;
    reporter.step("ssh", "complete", "SSH and startup configuration complete");

    reporter.active("dashboard", "Deploying and verifying the dashboard…");
    deploy_dashboard(&channel, &request.gateway, &files, &reporter)?;
    reporter.step("dashboard", "complete", "Dashboard deployed and verified");

    if matches!(&channel, Channel::Adb { .. }) && request.reboot_after {
        reporter.active("reboot", "Rebooting to restore normal USB tethering…");
        channel.reboot()?;
        reporter.step("reboot", "complete", "Reboot requested");
    }

    reporter.log("[+] Installation completed successfully");
    Ok(InstallOutcome {
        result: "success".into(),
        title: format!("{} completed", operation.label()),
        message: if request.reboot_after && matches!(&channel, Channel::Adb { .. }) {
            "The modem is rebooting. Allow about 90 seconds before opening the dashboard.".into()
        } else {
            "The agent, secure SSH access, and dashboard are ready.".into()
        },
        operation,
        dashboard_url: Some(format!("http://{}:8080", request.gateway)),
        api_url: Some(format!("http://{}:9090", request.gateway)),
        ssh_address: Some(format!("ssh -p 2222 root@{}", request.gateway)),
        diagnostic_path: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adb_login_uses_device_lan_address_without_forwarding() {
        let command = adb_agent_login_command("192.168.0.1", "quote'password");
        assert!(command.contains("/usr/bin/curl"));
        assert!(command.contains("192.168.0.1:9090/api/auth/login"));
        assert!(!command.contains("adb forward"));
        assert!(command.contains("quote'\\''password"));
    }

    #[test]
    fn source_keeps_explicit_dropbear_and_dashboard_checks() {
        let source = include_str!("deploy.rs");
        assert!(source.contains("[ -f /data/bin/dropbear ] && [ -x /data/bin/dropbear ]"));
        assert!(source.contains("/data/bin/dashboard-uhttpd"));
        assert!(source.contains("start_dashboard.sh"));
        assert!(source.contains("uci -q delete uhttpd.dashboard"));
        assert!(source.contains("http://127.0.0.1:8080/"));
        assert!(source.contains("<div id=\\\"root\\\"></div>"));
    }

    #[test]
    fn shell_quote_handles_credentials_with_quotes() {
        assert_eq!(shell_quote("can't"), "'can'\\''t'");
    }
}
