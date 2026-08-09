use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StepKind {
    Keyboard,
    Region,
    Network,
    Hostname,
    Account,
    Target,
    Layout,
    Profile,
    Boot,
    Review,
    Help,
    Exit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Step {
    pub group: &'static str,
    pub label: &'static str,
    pub kind: StepKind,
}

pub const STEPS: &[Step] = &[
    Step {
        group: "PREPARE",
        label: "Keyboard",
        kind: StepKind::Keyboard,
    },
    Step {
        group: "PREPARE",
        label: "Language & region",
        kind: StepKind::Region,
    },
    Step {
        group: "PREPARE",
        label: "Network",
        kind: StepKind::Network,
    },
    Step {
        group: "SYSTEM",
        label: "Computer name",
        kind: StepKind::Hostname,
    },
    Step {
        group: "SYSTEM",
        label: "User account",
        kind: StepKind::Account,
    },
    Step {
        group: "STORAGE",
        label: "Target disk",
        kind: StepKind::Target,
    },
    Step {
        group: "STORAGE",
        label: "Storage layout",
        kind: StepKind::Layout,
    },
    Step {
        group: "INSTALL",
        label: "Package source",
        kind: StepKind::Profile,
    },
    Step {
        group: "INSTALL",
        label: "Boot",
        kind: StepKind::Boot,
    },
    Step {
        group: "FINISH",
        label: "Review plan",
        kind: StepKind::Review,
    },
    Step {
        group: "MORE",
        label: "Help",
        kind: StepKind::Help,
    },
    Step {
        group: "MORE",
        label: "Exit",
        kind: StepKind::Exit,
    },
];

#[derive(Clone, Debug, Default)]
pub struct InstallerState {
    values: BTreeMap<String, String>,
}

impl InstallerState {
    pub fn parse(tsv: &str) -> Self {
        let values = tsv
            .lines()
            .filter_map(|line| line.split_once('\t'))
            .map(|(key, value)| (key.to_owned(), value.to_owned()))
            .collect();
        Self { values }
    }

    pub fn get(&self, key: &str) -> &str {
        self.values.get(key).map(String::as_str).unwrap_or("")
    }

    pub fn account_ready(&self) -> bool {
        !self.get("DISPLAY_NAME").is_empty() && !self.get("USERNAME").is_empty()
    }

    pub fn target_ready(&self) -> bool {
        !self.get("DISK_DEVICE").is_empty() && self.get("DISK_AVAILABLE") == "yes"
    }

    pub fn status_for(&self, kind: StepKind) -> (&'static str, StatusTone) {
        match kind {
            StepKind::Keyboard
            | StepKind::Region
            | StepKind::Hostname
            | StepKind::Layout
            | StepKind::Profile
            | StepKind::Boot => ("ready", StatusTone::Ready),
            StepKind::Network => ("inspect", StatusTone::Neutral),
            StepKind::Account if self.account_ready() => ("ready", StatusTone::Ready),
            StepKind::Account => ("needed", StatusTone::Attention),
            StepKind::Target if self.target_ready() => ("selected", StatusTone::Ready),
            StepKind::Target => ("required", StatusTone::Attention),
            StepKind::Review if self.account_ready() && self.target_ready() => {
                ("ready", StatusTone::Ready)
            }
            StepKind::Review => ("locked", StatusTone::Muted),
            StepKind::Help | StepKind::Exit => ("", StatusTone::Neutral),
        }
    }

    pub fn summary(&self, kind: StepKind) -> String {
        match kind {
            StepKind::Keyboard => self.get("KEYBOARD_KEYMAP").to_owned(),
            StepKind::Region => format!("{} · {}", self.get("LOCALE"), self.get("TIMEZONE")),
            StepKind::Network => "Read-only interface status".into(),
            StepKind::Hostname => self.get("HOSTNAME").to_owned(),
            StepKind::Account if self.account_ready() => {
                format!("{} · {}", self.get("DISPLAY_NAME"), self.get("USERNAME"))
            }
            StepKind::Account => "Create the installed user".into(),
            StepKind::Target if self.target_ready() => {
                format!("{} · {}", self.get("DISK_DEVICE"), self.get("DISK_MODEL"))
            }
            StepKind::Target => "No disk selected".into(),
            StepKind::Layout => format!(
                "{} · swap {}",
                self.get("FILESYSTEM"),
                self.get("SWAP_MODE")
            ),
            StepKind::Profile => self.get("PACKAGE_SOURCE").to_owned(),
            StepKind::Boot => format!(
                "{} · {}",
                self.get("BOOT_MODE"),
                self.get("PARTITION_SCHEME")
            ),
            StepKind::Review => "Inspect every planned action".into(),

            StepKind::Help => "Controls and safety model".into(),
            StepKind::Exit => "Return to the live desktop".into(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StatusTone {
    Ready,
    Attention,
    Muted,
    Neutral,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Disk {
    pub path: String,
    pub model: String,
    pub size: String,
    pub serial: String,
    pub sector: String,
    pub available: bool,
    pub reason: String,
}

impl Disk {
    pub fn parse_inventory(tsv: &str) -> Vec<Self> {
        let mut lines = tsv.lines();
        let Some(header) = lines.next() else {
            return Vec::new();
        };
        let keys: Vec<_> = header.split('\t').collect();
        lines
            .filter_map(|line| {
                let values: Vec<_> = line.split('\t').collect();
                let field = |name: &str| {
                    keys.iter()
                        .position(|key| *key == name)
                        .and_then(|index| values.get(index))
                        .copied()
                        .unwrap_or("")
                        .to_owned()
                };
                let path = field("path");
                (!path.is_empty()).then(|| Self {
                    path,
                    model: field("descr"),
                    size: human_bytes(&field("bytes")),
                    serial: field("ident"),
                    sector: field("sector_size"),
                    available: field("available") == "yes",
                    reason: field("reason"),
                })
            })
            .collect()
    }
}

fn human_bytes(value: &str) -> String {
    let Ok(bytes) = value.parse::<u64>() else {
        return "unknown".into();
    };
    const UNITS: &[&str] = &["B", "KiB", "MiB", "GiB", "TiB"];
    let mut amount = bytes as f64;
    let mut unit = 0;
    while amount >= 1024.0 && unit + 1 < UNITS.len() {
        amount /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{amount:.1} {}", UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::{Disk, InstallerState, StepKind};

    #[test]
    fn account_and_target_are_independent_requirements() {
        let state = InstallerState::parse(
            "DISPLAY_NAME\tAda Lovelace\nUSERNAME\tada\nDISK_DEVICE\t\nDISK_AVAILABLE\tno\n",
        );
        assert!(state.account_ready());
        assert!(!state.target_ready());
        assert_eq!(state.status_for(StepKind::Target).0, "required");
        assert_eq!(state.status_for(StepKind::Review).0, "locked");
    }

    #[test]
    fn disk_inventory_preserves_block_reasons() {
        let rows = "path\tdescr\tbytes\tident\tsector_size\tavailable\treason\n/dev/da0\tUSB\t17179869184\tA1\t512\tno\tlive-media\n/dev/nda0\tNVMe\t500000000000\tN1\t512\tyes\t\n";
        let disks = Disk::parse_inventory(rows);
        assert_eq!(disks.len(), 2);
        assert!(!disks[0].available);
        assert_eq!(disks[0].reason, "live-media");
        assert!(disks[1].available);
    }
}
