use std::{
    env, fs,
    io::Read,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};

use crate::model::{Disk, InstallerState};

pub struct Backend {
    bridge: PathBuf,
    runtime: PathBuf,
    state: PathBuf,
    inventory: PathBuf,
    snapshot: PathBuf,
    cancel: Arc<AtomicBool>,
}

impl Backend {
    pub fn new() -> Result<Self> {
        let bridge = if let Some(path) = env::var_os("TRITON_BRIDGE") {
            PathBuf::from(path)
        } else {
            env::current_exe()
                .context("cannot locate installer executable")?
                .parent()
                .context("installer executable has no parent")?
                .join("triton-model-bridge")
        };
        if !bridge.is_file() {
            bail!("model bridge not found: {}", bridge.display());
        }

        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temp = fs::canonicalize(env::temp_dir())
            .context("cannot resolve the installer temporary directory")?;
        let runtime = temp.join(format!("triton-installer.{}.{}", std::process::id(), nonce));
        fs::create_dir(&runtime).context("cannot create private installer runtime")?;
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700))
            .context("cannot secure private installer runtime")?;

        let backend = Self {
            bridge,
            state: runtime.join("installer.state"),
            inventory: runtime.join("inventory.tsv"),
            snapshot: runtime.join("selected-target.tsv"),
            cancel: Arc::new(AtomicBool::new(false)),
            runtime,
        };
        backend.run(&["state-init"])?;
        Ok(backend)
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.bridge);
        command
            .process_group(0)
            .env("TRITON_RUNTIME_DIR", &self.runtime)
            .env("TRITON_STATE_FILE", &self.state)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(fixture) = env::var_os("TRITON_DISCOVERY_FIXTURE") {
            command.env("TRITON_DISCOVERY_FIXTURE", fixture);
        }
        command
    }

    pub fn run(&self, args: &[&str]) -> Result<String> {
        let operation = args.first().copied().unwrap_or("");
        let mut child = self
            .command()
            .args(args)
            .spawn()
            .with_context(|| format!("cannot run model bridge operation {operation}"))?;
        let stdout = child
            .stdout
            .take()
            .context("cannot capture model bridge output")?;
        let stderr = child
            .stderr
            .take()
            .context("cannot capture model bridge diagnostics")?;
        let stdout_reader = read_pipe(stdout);
        let stderr_reader = read_pipe(stderr);
        let started = Instant::now();
        let status = loop {
            if self.cancel.load(Ordering::Relaxed) {
                terminate_process_group(&mut child);
                let _ = finish_reader(stdout_reader, "output");
                let _ = finish_reader(stderr_reader, "diagnostics");
                bail!("operation {operation} was cancelled");
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if started.elapsed() >= Duration::from_secs(30) {
                terminate_process_group(&mut child);
                let _ = finish_reader(stdout_reader, "output");
                let _ = finish_reader(stderr_reader, "diagnostics");
                bail!("operation {operation} timed out");
            }
            thread::sleep(Duration::from_millis(10));
        };
        let stdout = finish_reader(stdout_reader, "output")?;
        let stderr = finish_reader(stderr_reader, "diagnostics")?;
        if status.success() {
            return Ok(String::from_utf8_lossy(&stdout).trim().to_owned());
        }
        let diagnostic = String::from_utf8_lossy(&stderr).trim().to_owned();
        if diagnostic.is_empty() {
            bail!("operation {operation} was rejected");
        }
        bail!("{diagnostic}")
    }

    pub fn cancel_handle(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.cancel)
    }

    pub fn state(&self) -> Result<InstallerState> {
        Ok(InstallerState::parse(&self.run(&["state-dump"])?))
    }

    pub fn set(&self, key: &str, value: &str) -> Result<InstallerState> {
        self.run_state(&["set", key, value])
    }

    pub fn set_user(&self, display: &str, username: &str, admin: bool) -> Result<InstallerState> {
        self.run_state(&[
            "set-user",
            display,
            username,
            if admin { "yes" } else { "no" },
        ])
    }

    pub fn set_swap(&self, mode: &str, size: &str) -> Result<InstallerState> {
        self.run_state(&["set-swap", mode, size])
    }

    pub fn network(&self) -> Result<String> {
        self.run(&["network"])
    }

    pub fn discover(&self) -> Result<Vec<Disk>> {
        self.run(&["discover", path_arg(&self.inventory)?])?;
        let inventory =
            fs::read_to_string(&self.inventory).context("cannot read disk inventory")?;
        Ok(Disk::parse_inventory(&inventory))
    }

    pub fn select_target(&self, path: &str) -> Result<InstallerState> {
        self.run_state(&[
            "select-target",
            path_arg(&self.inventory)?,
            path,
            path_arg(&self.snapshot)?,
        ])
    }

    pub fn revalidate(&self) -> Result<()> {
        self.run(&[
            "revalidate",
            path_arg(&self.inventory)?,
            path_arg(&self.snapshot)?,
        ])
        .map(|_| ())
    }

    pub fn report(&self) -> Result<String> {
        self.run(&["plan-report"])
    }

    pub fn plan(&self) -> Result<String> {
        self.run(&["plan-render"])
    }

    fn run_state(&self, args: &[&str]) -> Result<InstallerState> {
        Ok(InstallerState::parse(&self.run(args)?))
    }
}

fn read_pipe<R>(mut pipe: R) -> thread::JoinHandle<std::io::Result<Vec<u8>>>
where
    R: Read + Send + 'static,
{
    thread::spawn(move || {
        let mut bytes = Vec::new();
        pipe.read_to_end(&mut bytes)?;
        Ok(bytes)
    })
}

fn finish_reader(
    reader: thread::JoinHandle<std::io::Result<Vec<u8>>>,
    stream: &str,
) -> Result<Vec<u8>> {
    reader
        .join()
        .map_err(|_| anyhow::anyhow!("model bridge {stream} reader panicked"))?
        .with_context(|| format!("cannot read model bridge {stream}"))
}

fn terminate_process_group(child: &mut std::process::Child) {
    let process_group = -(child.id() as libc::pid_t);
    // The bridge is started in its own process group, so this cannot signal Triton itself.
    unsafe {
        libc::kill(process_group, libc::SIGKILL);
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn path_arg(path: &Path) -> Result<&str> {
    path.to_str().context("installer runtime path is not UTF-8")
}

impl Drop for Backend {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.runtime);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellation_stops_a_blocked_bridge_promptly() {
        let runtime = env::temp_dir().join(format!(
            "triton-backend-cancel.{}.{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        fs::create_dir(&runtime).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let bridge = runtime.join("slow-bridge");
        let leaked =
            env::temp_dir().join(format!("triton-backend-leak.{}.marker", std::process::id()));
        let _ = fs::remove_file(&leaked);
        fs::write(
            &bridge,
            format!(
                "#!/bin/sh\nsleep 1\nprintf leaked > '{}'\n",
                leaked.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&bridge, fs::Permissions::from_mode(0o700)).unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let backend = Backend {
            bridge,
            state: runtime.join("installer.state"),
            inventory: runtime.join("inventory.tsv"),
            snapshot: runtime.join("selected-target.tsv"),
            runtime,
            cancel: Arc::clone(&cancel),
        };
        let worker = thread::spawn(move || backend.run(&["slow"]));
        thread::sleep(Duration::from_millis(50));
        let started = Instant::now();
        cancel.store(true, Ordering::Relaxed);
        let error = worker.join().unwrap().unwrap_err().to_string();

        assert!(error.contains("cancelled"));
        assert!(started.elapsed() < Duration::from_secs(1));
        thread::sleep(Duration::from_millis(1100));
        assert!(!leaked.exists(), "cancelled bridge left a live descendant");
    }

    #[test]
    fn bridge_output_larger_than_a_pipe_is_drained_while_running() {
        let runtime = env::temp_dir().join(format!(
            "triton-backend-output.{}.{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        fs::create_dir(&runtime).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let bridge = runtime.join("large-output-bridge");
        fs::write(&bridge, "#!/bin/sh\nhead -c 131072 /dev/zero\n").unwrap();
        fs::set_permissions(&bridge, fs::Permissions::from_mode(0o700)).unwrap();
        let backend = Backend {
            bridge,
            state: runtime.join("installer.state"),
            inventory: runtime.join("inventory.tsv"),
            snapshot: runtime.join("selected-target.tsv"),
            runtime,
            cancel: Arc::new(AtomicBool::new(false)),
        };

        assert_eq!(backend.run(&["large-output"]).unwrap().len(), 131_072);
    }
}
