use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, Sender, TryRecvError},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use anyhow::Result;
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
    MouseEventKind,
};
use ratatui::layout::{Position, Rect};
use ratatui_image::protocol::Protocol;

use crate::{
    backend::Backend,
    model::{Disk, InstallerState, STEPS, StepKind},
    terminal::Tui,
    ui,
};

type BackendResult<T> = std::result::Result<T, String>;
type BackendJob = Box<dyn FnOnce(&Backend) -> AsyncResult + Send>;

enum ReviewResult {
    Plan(String),
    Incomplete(String),
    Rejected {
        state: Option<InstallerState>,
        message: String,
    },
}

enum AsyncResult {
    Saved {
        result: BackendResult<InstallerState>,
        success: &'static str,
    },
    Network {
        id: u64,
        result: BackendResult<String>,
    },
    Disks {
        id: u64,
        result: BackendResult<Vec<Disk>>,
    },
    Review {
        id: u64,
        result: ReviewResult,
    },
}

#[derive(Clone, Debug)]
pub enum Hit {
    Step(usize),
    Detail(usize),
    OverlayItem(usize),
    AccountField(usize),
    AccountSave,
    OverlayConfirm,
    OverlayCancel,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FocusPane {
    Navigation,
    Details,
}

#[derive(Clone, Debug)]
pub struct HitRegion {
    pub rect: Rect,
    pub hit: Hit,
}

#[derive(Clone, Debug)]
pub struct ChoiceItem {
    pub value: String,
    pub label: String,
    pub detail: String,
}

impl ChoiceItem {
    fn new(value: &str, label: &str, detail: &str) -> Self {
        Self {
            value: value.into(),
            label: label.into(),
            detail: detail.into(),
        }
    }
}

#[derive(Clone, Debug)]
pub enum ChoiceAction {
    Set(&'static str),
    SetTimezone,
    SetSwap,
}

#[derive(Clone, Copy, Debug)]
pub enum InputAction {
    Hostname,
    SwapSize,
}

#[derive(Clone, Debug)]
pub struct AccountForm {
    pub display: String,
    pub username: String,
    pub admin: bool,
    pub field: usize,
}

#[derive(Clone, Debug)]
pub enum Overlay {
    Choice {
        title: String,
        eyebrow: String,
        items: Vec<ChoiceItem>,
        selected: usize,
        scroll: usize,
        action: ChoiceAction,
    },
    Input {
        title: String,
        label: String,
        hint: String,
        value: String,
        action: InputAction,
    },
    Account(AccountForm),
    Disks {
        items: Vec<Disk>,
        selected: usize,
        scroll: usize,
    },
    ConfirmTarget {
        disk: Disk,
        confirm_selected: bool,
    },
    Document {
        title: String,
        eyebrow: String,
        lines: Vec<String>,
        scroll: usize,
        success: bool,
    },
    Message {
        title: String,
        eyebrow: String,
        body: Vec<String>,
    },
    ConfirmExit {
        confirm_selected: bool,
    },
}

pub struct App {
    pub state: InstallerState,
    pub selected: usize,
    pub detail_selected: usize,
    pub focus: FocusPane,
    pub nav_scroll: usize,
    pub overlay: Option<Overlay>,
    pub notice: String,
    pub notice_error: bool,
    pub running: bool,
    pub hits: Vec<HitRegion>,
    pub hover: Option<Hit>,
    pub logo: Option<Protocol>,
    terminate: Arc<AtomicBool>,
    jobs: Option<Sender<BackendJob>>,
    results: Receiver<AsyncResult>,
    worker: Option<JoinHandle<()>>,
    worker_cancel: Arc<AtomicBool>,
    next_task_id: u64,
    foreground_task: Option<u64>,
}

impl App {
    pub fn new(backend: Backend, terminate: Arc<AtomicBool>) -> Result<Self> {
        let state = backend.state()?;
        let worker_cancel = backend.cancel_handle();
        let worker_stop = Arc::clone(&worker_cancel);
        let (job_tx, job_rx) = mpsc::channel::<BackendJob>();
        let (result_tx, result_rx) = mpsc::channel();
        let worker = thread::Builder::new()
            .name("triton-installer-model".into())
            .spawn(move || {
                while let Ok(job) = job_rx.recv() {
                    if worker_stop.load(Ordering::Relaxed) {
                        break;
                    }
                    if result_tx.send(job(&backend)).is_err() {
                        break;
                    }
                }
            })?;
        Ok(Self {
            state,
            selected: 0,
            detail_selected: 0,
            focus: FocusPane::Navigation,
            nav_scroll: 0,
            overlay: None,
            notice: "Preview mode · no disk-writing backend is present".into(),
            notice_error: false,
            running: true,
            hits: Vec::new(),
            hover: None,
            logo: ui::load_logo(),
            terminate,
            jobs: Some(job_tx),
            results: result_rx,
            worker: Some(worker),
            worker_cancel,
            next_task_id: 1,
            foreground_task: None,
        })
    }

    pub fn run(&mut self, terminal: &mut Tui) -> Result<()> {
        while self.running && !self.terminate.load(Ordering::Relaxed) {
            self.drain_results();
            terminal.draw(|frame| ui::render(frame, self))?;
            if !event::poll(Duration::from_millis(16))? {
                continue;
            }
            match event::read()? {
                Event::Key(key)
                    if matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) =>
                {
                    self.key(key)
                }
                Event::Mouse(mouse) => self.mouse(mouse),
                Event::Resize(_, _) => {}
                _ => {}
            }
        }
        Ok(())
    }

    fn key(&mut self, key: KeyEvent) {
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('l') {
            return;
        }
        let close = closes_overlay(&key);
        if close {
            if self.overlay.is_some() {
                self.overlay = None;
            } else if self.focus == FocusPane::Details {
                self.focus = FocusPane::Navigation;
            } else {
                self.foreground_task = None;
                self.overlay = Some(Overlay::ConfirmExit {
                    confirm_selected: false,
                });
            }
            return;
        }
        if self.overlay.is_some() {
            self.overlay_key(key);
            return;
        }
        match self.focus {
            FocusPane::Navigation => match key.code {
                KeyCode::Up | KeyCode::Char('k') => {
                    self.foreground_task = None;
                    self.selected = self.selected.saturating_sub(1);
                    self.detail_selected = 0;
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    self.foreground_task = None;
                    self.selected = (self.selected + 1).min(STEPS.len() - 1);
                    self.detail_selected = 0;
                }
                KeyCode::Home => {
                    self.foreground_task = None;
                    self.selected = 0;
                    self.detail_selected = 0;
                }
                KeyCode::End => {
                    self.foreground_task = None;
                    self.selected = STEPS.len() - 1;
                    self.detail_selected = 0;
                }
                KeyCode::Enter | KeyCode::Char(' ') | KeyCode::Right => {
                    self.focus = FocusPane::Details;
                    self.detail_selected = self
                        .detail_selected
                        .min(self.detail_count().saturating_sub(1));
                }
                KeyCode::Char('q') => {
                    self.foreground_task = None;
                    self.overlay = Some(Overlay::ConfirmExit {
                        confirm_selected: false,
                    })
                }
                KeyCode::F(1) | KeyCode::Char('?') => self.open_help(),
                _ => {}
            },
            FocusPane::Details => match key.code {
                KeyCode::Up | KeyCode::Char('k') => {
                    self.detail_selected = self.detail_selected.saturating_sub(1)
                }
                KeyCode::Down | KeyCode::Char('j') => {
                    self.detail_selected =
                        (self.detail_selected + 1).min(self.detail_count().saturating_sub(1))
                }
                KeyCode::Home => self.detail_selected = 0,
                KeyCode::End => self.detail_selected = self.detail_count().saturating_sub(1),
                KeyCode::Left | KeyCode::BackTab => self.focus = FocusPane::Navigation,
                KeyCode::Enter | KeyCode::Char(' ') => self.activate_selected(),
                KeyCode::Char('q') => {
                    self.foreground_task = None;
                    self.overlay = Some(Overlay::ConfirmExit {
                        confirm_selected: false,
                    })
                }
                KeyCode::F(1) | KeyCode::Char('?') => self.open_help(),
                _ => {}
            },
        }
    }

    fn overlay_key(&mut self, key: KeyEvent) {
        match self.overlay.as_mut().expect("overlay exists") {
            Overlay::Choice {
                selected, items, ..
            } => match key.code {
                KeyCode::Up | KeyCode::Char('k') => *selected = selected.saturating_sub(1),
                KeyCode::Down | KeyCode::Char('j') => {
                    *selected = (*selected + 1).min(items.len().saturating_sub(1))
                }
                KeyCode::Home => *selected = 0,
                KeyCode::End => *selected = items.len().saturating_sub(1),
                KeyCode::Enter | KeyCode::Char(' ') => self.commit_choice(),
                KeyCode::Esc | KeyCode::Char('q') => self.overlay = None,
                _ => {}
            },
            Overlay::Input { value, .. } => match key.code {
                KeyCode::Char(character) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    value.push(character)
                }
                KeyCode::Backspace => {
                    value.pop();
                }
                KeyCode::Enter => self.commit_input(),
                KeyCode::Esc => self.overlay = None,
                _ => {}
            },
            Overlay::Account(form) => match key.code {
                KeyCode::Tab | KeyCode::Down => form.field = (form.field + 1).min(3),
                KeyCode::BackTab | KeyCode::Up => form.field = form.field.saturating_sub(1),
                KeyCode::Char(' ') if form.field == 2 => form.admin = !form.admin,
                KeyCode::Char(character)
                    if form.field < 2 && !key.modifiers.contains(KeyModifiers::CONTROL) =>
                {
                    account_value(form).push(character)
                }
                KeyCode::Backspace if form.field < 2 => {
                    account_value(form).pop();
                }
                KeyCode::Enter if form.field == 2 => form.admin = !form.admin,
                KeyCode::Enter if form.field == 3 => self.commit_account(),
                KeyCode::Enter => form.field = (form.field + 1).min(3),
                KeyCode::Esc => self.overlay = None,
                _ => {}
            },
            Overlay::Disks {
                items, selected, ..
            } => match key.code {
                KeyCode::Up | KeyCode::Char('k') => *selected = selected.saturating_sub(1),
                KeyCode::Down | KeyCode::Char('j') => {
                    *selected = (*selected + 1).min(items.len().saturating_sub(1))
                }
                KeyCode::Char('r') => self.open_disks(),
                KeyCode::Enter | KeyCode::Char(' ') => self.inspect_disk(),
                KeyCode::Esc | KeyCode::Char('q') => self.overlay = None,
                _ => {}
            },
            Overlay::ConfirmTarget {
                confirm_selected, ..
            } => match key.code {
                KeyCode::Left | KeyCode::Up => *confirm_selected = true,
                KeyCode::Right | KeyCode::Down => *confirm_selected = false,
                KeyCode::Tab | KeyCode::BackTab => *confirm_selected = !*confirm_selected,
                KeyCode::Enter | KeyCode::Char(' ') if *confirm_selected => self.commit_target(),
                KeyCode::Enter | KeyCode::Char(' ') => self.open_disks(),
                KeyCode::Char('y') => self.commit_target(),
                KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('q') => self.open_disks(),
                _ => {}
            },
            Overlay::Document { scroll, lines, .. } => match key.code {
                KeyCode::Up | KeyCode::Char('k') => *scroll = scroll.saturating_sub(1),
                KeyCode::Down | KeyCode::Char('j') => {
                    *scroll = (*scroll + 1).min(lines.len().saturating_sub(1))
                }
                KeyCode::PageUp => *scroll = scroll.saturating_sub(8),
                KeyCode::PageDown => *scroll = (*scroll + 8).min(lines.len().saturating_sub(1)),
                KeyCode::Home => *scroll = 0,
                KeyCode::End => *scroll = lines.len().saturating_sub(1),
                KeyCode::Esc | KeyCode::Enter | KeyCode::Char('q') => self.overlay = None,
                _ => {}
            },
            Overlay::Message { .. } => match key.code {
                KeyCode::Esc | KeyCode::Enter | KeyCode::Char('q') => self.overlay = None,
                _ => {}
            },
            Overlay::ConfirmExit { confirm_selected } => match key.code {
                KeyCode::Left | KeyCode::Up => *confirm_selected = true,
                KeyCode::Right | KeyCode::Down => *confirm_selected = false,
                KeyCode::Tab | KeyCode::BackTab => *confirm_selected = !*confirm_selected,
                KeyCode::Enter | KeyCode::Char(' ') if *confirm_selected => self.running = false,
                KeyCode::Enter | KeyCode::Char(' ') => self.overlay = None,
                KeyCode::Char('y') => self.running = false,
                KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('q') => self.overlay = None,
                _ => {}
            },
        }
    }

    fn mouse(&mut self, mouse: MouseEvent) {
        let position = Position::new(mouse.column, mouse.row);
        match mouse.kind {
            MouseEventKind::Moved => {
                self.hover = self
                    .hits
                    .iter()
                    .find(|hit| hit.rect.contains(position))
                    .map(|hit| hit.hit.clone());
            }
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(hit) = self
                    .hits
                    .iter()
                    .rev()
                    .find(|hit| hit.rect.contains(position))
                    .map(|hit| hit.hit.clone())
                {
                    self.apply_hit(hit);
                }
            }
            MouseEventKind::ScrollUp => self.scroll_mouse(false),
            MouseEventKind::ScrollDown => self.scroll_mouse(true),
            _ => {}
        }
    }

    fn scroll_mouse(&mut self, down: bool) {
        match self.overlay.as_mut() {
            Some(Overlay::Choice {
                selected, items, ..
            }) => {
                if down {
                    *selected = (*selected + 1).min(items.len().saturating_sub(1));
                } else {
                    *selected = selected.saturating_sub(1);
                }
            }
            Some(Overlay::Disks {
                selected, items, ..
            }) => {
                if down {
                    *selected = (*selected + 1).min(items.len().saturating_sub(1));
                } else {
                    *selected = selected.saturating_sub(1);
                }
            }
            Some(Overlay::Document { scroll, lines, .. }) => {
                if down {
                    *scroll = (*scroll + 3).min(lines.len().saturating_sub(1));
                } else {
                    *scroll = scroll.saturating_sub(3);
                }
            }
            None => {
                self.foreground_task = None;
                if self.focus == FocusPane::Details {
                    if down {
                        self.detail_selected =
                            (self.detail_selected + 1).min(self.detail_count().saturating_sub(1));
                    } else {
                        self.detail_selected = self.detail_selected.saturating_sub(1);
                    }
                } else if down {
                    self.selected = (self.selected + 1).min(STEPS.len() - 1);
                    self.detail_selected = 0;
                } else {
                    self.selected = self.selected.saturating_sub(1);
                    self.detail_selected = 0;
                }
            }
            _ => {}
        }
    }

    fn apply_hit(&mut self, hit: Hit) {
        match hit {
            Hit::Step(index) => {
                self.selected = index;
                self.detail_selected = 0;
                self.focus = FocusPane::Navigation;
            }
            Hit::Detail(index) => {
                self.detail_selected = index.min(self.detail_count().saturating_sub(1));
                self.focus = FocusPane::Details;
                self.activate_selected();
            }
            Hit::OverlayItem(index) => {
                match self.overlay.as_mut() {
                    Some(Overlay::Choice { selected, .. })
                    | Some(Overlay::Disks { selected, .. }) => *selected = index,
                    _ => {}
                }
                match self.overlay {
                    Some(Overlay::Choice { .. }) => self.commit_choice(),
                    Some(Overlay::Disks { .. }) => self.inspect_disk(),
                    _ => {}
                }
            }
            Hit::AccountField(index) => {
                if let Some(Overlay::Account(form)) = self.overlay.as_mut() {
                    form.field = index;
                }
            }
            Hit::AccountSave => self.commit_account(),
            Hit::OverlayConfirm => match self.overlay {
                Some(Overlay::ConfirmTarget { .. }) => self.commit_target(),
                Some(Overlay::ConfirmExit { .. }) => self.running = false,
                _ => {}
            },
            Hit::OverlayCancel => {
                if matches!(self.overlay, Some(Overlay::ConfirmTarget { .. })) {
                    self.open_disks();
                } else {
                    self.overlay = None;
                }
            }
        }
    }

    fn detail_count(&self) -> usize {
        detail_count_for(STEPS[self.selected].kind)
    }

    fn activate_selected(&mut self) {
        self.foreground_task = None;
        match STEPS[self.selected].kind {
            StepKind::Keyboard => self.choice(
                "Keyboard",
                "INPUT",
                vec![
                    ChoiceItem::new("us", "English (US)", "Standard US layout"),
                    ChoiceItem::new("es", "Spanish", "Spanish ISO layout"),
                    ChoiceItem::new("uk", "English (UK)", "British layout"),
                    ChoiceItem::new("de", "German", "German QWERTZ layout"),
                    ChoiceItem::new("fr", "French", "French AZERTY layout"),
                ],
                ChoiceAction::Set("KEYBOARD_KEYMAP"),
                self.state.get("KEYBOARD_KEYMAP").to_owned(),
            ),
            StepKind::Region if self.detail_selected == 0 => self.choice(
                "Language",
                "REGION",
                vec![
                    ChoiceItem::new("en_US.UTF-8", "English — United States", "en_US.UTF-8"),
                    ChoiceItem::new("en_GB.UTF-8", "English — United Kingdom", "en_GB.UTF-8"),
                    ChoiceItem::new("es_ES.UTF-8", "Español — España", "es_ES.UTF-8"),
                    ChoiceItem::new("de_DE.UTF-8", "Deutsch — Deutschland", "de_DE.UTF-8"),
                    ChoiceItem::new("fr_FR.UTF-8", "Français — France", "fr_FR.UTF-8"),
                ],
                ChoiceAction::Set("LOCALE"),
                self.state.get("LOCALE").to_owned(),
            ),
            StepKind::Region => self.choice(
                "Timezone",
                "REGION",
                timezone_choices(),
                ChoiceAction::SetTimezone,
                self.state.get("TIMEZONE").to_owned(),
            ),
            StepKind::Network => {
                let id = self.begin_foreground();
                self.enqueue("Inspecting network…", move |backend| {
                    AsyncResult::Network {
                        id,
                        result: backend.network().map_err(|error| error.to_string()),
                    }
                });
            }
            StepKind::Hostname => {
                self.overlay = Some(Overlay::Input {
                    title: "Computer name".into(),
                    label: "HOSTNAME".into(),
                    hint: "Lowercase letters, numbers and hyphens".into(),
                    value: self.state.get("HOSTNAME").to_owned(),
                    action: InputAction::Hostname,
                })
            }
            StepKind::Account => {
                self.overlay = Some(Overlay::Account(AccountForm {
                    display: self.state.get("DISPLAY_NAME").to_owned(),
                    username: self.state.get("USERNAME").to_owned(),
                    admin: self.state.get("ADMIN_ACCESS") != "no",
                    field: self.detail_selected.min(2),
                }))
            }
            StepKind::Target => self.open_disks(),
            StepKind::Layout => self.choice(
                "Storage layout",
                "GUIDED LAYOUT",
                vec![
                    ChoiceItem::new(
                        "auto",
                        "UFS + automatic swap",
                        "Recommended for most systems",
                    ),
                    ChoiceItem::new(
                        "none",
                        "UFS without swap",
                        "No swap partition will be planned",
                    ),
                    ChoiceItem::new(
                        "custom",
                        "UFS + custom swap",
                        "Set an explicit swap size later",
                    ),
                ],
                ChoiceAction::SetSwap,
                self.state.get("SWAP_MODE").to_owned(),
            ),
            StepKind::Profile => self.choice(
                "Package source",
                "INSTALL MEDIA",
                vec![
                    ChoiceItem::new(
                        "network",
                        "Network repository",
                        "Fetch packages using the live connection",
                    ),
                    ChoiceItem::new(
                        "local",
                        "Live media",
                        "Use packages bundled with the installer image",
                    ),
                ],
                ChoiceAction::Set("PACKAGE_SOURCE"),
                self.state.get("PACKAGE_SOURCE").to_owned(),
            ),
            StepKind::Boot => self.choice(
                "Boot mode",
                "FIRMWARE",
                vec![ChoiceItem::new(
                    "uefi",
                    "UEFI · GPT",
                    "Recommended modern firmware path",
                )],
                ChoiceAction::Set("BOOT_MODE"),
                self.state.get("BOOT_MODE").to_owned(),
            ),
            StepKind::Review => self.review(),

            StepKind::Help => self.open_help(),
            StepKind::Exit => {
                self.overlay = Some(Overlay::ConfirmExit {
                    confirm_selected: false,
                })
            }
        }
    }

    fn choice(
        &mut self,
        title: &str,
        eyebrow: &str,
        items: Vec<ChoiceItem>,
        action: ChoiceAction,
        current: String,
    ) {
        let selected = items
            .iter()
            .position(|item| item.value == current)
            .unwrap_or(0);
        self.overlay = Some(Overlay::Choice {
            title: title.into(),
            eyebrow: eyebrow.into(),
            items,
            selected,
            scroll: 0,
            action,
        });
    }

    fn commit_choice(&mut self) {
        let Some(Overlay::Choice {
            items,
            selected,
            action,
            ..
        }) = self.overlay.take()
        else {
            return;
        };
        let value = items
            .get(selected)
            .map(|item| item.value.clone())
            .unwrap_or_default();
        if matches!(action, ChoiceAction::SetSwap) && value == "custom" {
            let current = self.state.get("SWAP_SIZE_MIB");
            self.overlay = Some(Overlay::Input {
                title: "Custom swap".into(),
                label: "SIZE IN MIB".into(),
                hint: "Enter a positive size in MiB".into(),
                value: if current.is_empty() {
                    "4096".into()
                } else {
                    current.into()
                },
                action: InputAction::SwapSize,
            });
            return;
        }
        self.enqueue("Saving setting…", move |backend| {
            let result = match action {
                ChoiceAction::Set(key) => backend.set(key, &value),
                ChoiceAction::SetTimezone => backend.set("TIMEZONE", &value),
                ChoiceAction::SetSwap => backend.set_swap(&value, ""),
            };
            AsyncResult::Saved {
                result: result.map_err(|error| error.to_string()),
                success: "Setting saved",
            }
        });
    }

    fn commit_input(&mut self) {
        let Some(Overlay::Input { value, action, .. }) = self.overlay.take() else {
            return;
        };
        if matches!(action, InputAction::SwapSize) && !valid_swap_size(&value) {
            self.fail("Swap size must be a positive whole number of MiB".into());
            self.overlay = Some(Overlay::Input {
                title: "Custom swap".into(),
                label: "SIZE IN MIB".into(),
                hint: "Enter a positive size in MiB".into(),
                value,
                action,
            });
            return;
        }
        self.enqueue("Saving setting…", move |backend| {
            let (result, success) = match action {
                InputAction::Hostname => (backend.set("HOSTNAME", &value), "Computer name saved"),
                InputAction::SwapSize => (
                    backend.set_swap("custom", value.trim()),
                    "Custom swap size saved",
                ),
            };
            AsyncResult::Saved {
                result: result.map_err(|error| error.to_string()),
                success,
            }
        });
    }

    fn commit_account(&mut self) {
        let Some(Overlay::Account(form)) = self.overlay.take() else {
            return;
        };
        if form.display.trim().is_empty() || form.username.trim().is_empty() {
            self.fail("Full name and username are required".into());
            self.overlay = Some(Overlay::Account(form));
            return;
        }
        let display = form.display.trim().to_owned();
        let username = form.username.trim().to_owned();
        let admin = form.admin;
        self.enqueue("Saving account…", move |backend| AsyncResult::Saved {
            result: backend
                .set_user(&display, &username, admin)
                .map_err(|error| error.to_string()),
            success: "Account plan saved · passphrase deferred until a secure backend exists",
        });
    }

    fn open_disks(&mut self) {
        self.overlay = None;
        let id = self.begin_foreground();
        self.enqueue("Scanning disks…", move |backend| AsyncResult::Disks {
            id,
            result: backend.discover().map_err(|error| error.to_string()),
        });
    }

    fn inspect_disk(&mut self) {
        let Some(Overlay::Disks {
            items, selected, ..
        }) = self.overlay.take()
        else {
            return;
        };
        let Some(disk) = items.get(selected).cloned() else {
            return;
        };
        if disk.available {
            self.overlay = Some(Overlay::ConfirmTarget {
                disk,
                confirm_selected: false,
            });
        } else {
            self.overlay = Some(Overlay::Message {
                title: "Disk blocked".into(),
                eyebrow: "FAIL-CLOSED SAFETY".into(),
                body: vec![
                    disk.path,
                    disk.model,
                    String::new(),
                    format!("Reason: {}", disk.reason),
                    "Triton will not allow this device to be selected.".into(),
                ],
            });
        }
    }

    fn commit_target(&mut self) {
        let Some(Overlay::ConfirmTarget { disk, .. }) = self.overlay.take() else {
            return;
        };
        let path = disk.path;
        self.enqueue("Recording target…", move |backend| AsyncResult::Saved {
            result: backend
                .select_target(&path)
                .map_err(|error| error.to_string()),
            success: "Target identity recorded · no disk writes performed",
        });
    }

    fn review(&mut self) {
        self.overlay = None;
        let id = self.begin_foreground();
        self.enqueue("Preparing review…", move |backend| {
            let state = match backend.state() {
                Ok(state) => state,
                Err(error) => {
                    return AsyncResult::Review {
                        id,
                        result: ReviewResult::Rejected {
                            state: None,
                            message: error.to_string(),
                        },
                    };
                }
            };
            if state.target_ready()
                && let Err(error) = backend.revalidate()
            {
                return AsyncResult::Review {
                    id,
                    result: ReviewResult::Rejected {
                        state: backend.state().ok(),
                        message: error.to_string(),
                    },
                };
            }
            AsyncResult::Review {
                id,
                result: match backend.plan() {
                    Ok(plan) => ReviewResult::Plan(plan),
                    Err(error) => match backend.report() {
                        Ok(report) => ReviewResult::Incomplete(report),
                        Err(_) => ReviewResult::Rejected {
                            state: None,
                            message: error.to_string(),
                        },
                    },
                },
            }
        });
    }

    fn begin_foreground(&mut self) -> u64 {
        let id = self.next_task_id;
        self.next_task_id = self.next_task_id.wrapping_add(1).max(1);
        self.foreground_task = Some(id);
        id
    }

    fn enqueue<F>(&mut self, notice: &str, job: F)
    where
        F: FnOnce(&Backend) -> AsyncResult + Send + 'static,
    {
        self.notice = notice.into();
        self.notice_error = false;
        let Some(jobs) = self.jobs.as_ref() else {
            self.fail("Installer model worker is unavailable".into());
            return;
        };
        if jobs.send(Box::new(job)).is_err() {
            self.fail("Installer model worker stopped unexpectedly".into());
        }
    }

    fn drain_results(&mut self) {
        loop {
            let result = match self.results.try_recv() {
                Ok(result) => result,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    if self.jobs.take().is_some() {
                        self.fail("Installer model worker stopped unexpectedly".into());
                    }
                    break;
                }
            };
            match result {
                AsyncResult::Saved { result, success } => match result {
                    Ok(state) => {
                        self.state = state;
                        self.notice = success.into();
                        self.notice_error = false;
                    }
                    Err(error) => self.fail(error),
                },
                AsyncResult::Network { id, result } => {
                    if self.foreground_task != Some(id) || self.overlay.is_some() {
                        continue;
                    }
                    self.foreground_task = None;
                    match result {
                        Ok(body) => {
                            self.overlay = Some(Overlay::Message {
                                title: "Network".into(),
                                eyebrow: "READ-ONLY INSPECTION".into(),
                                body: body.lines().map(str::to_owned).collect(),
                            });
                        }
                        Err(error) => self.fail(error),
                    }
                }
                AsyncResult::Disks { id, result } => {
                    if self.foreground_task != Some(id) || self.overlay.is_some() {
                        continue;
                    }
                    self.foreground_task = None;
                    match result {
                        Ok(items) => {
                            let selected = items
                                .iter()
                                .position(|disk| disk.path == self.state.get("DISK_DEVICE"))
                                .unwrap_or(0);
                            self.overlay = Some(Overlay::Disks {
                                items,
                                selected,
                                scroll: 0,
                            });
                        }
                        Err(error) => self.fail(error),
                    }
                }
                AsyncResult::Review { id, result } => {
                    if self.foreground_task != Some(id) || self.overlay.is_some() {
                        if let ReviewResult::Rejected {
                            state: Some(state), ..
                        } = result
                        {
                            self.state = state;
                        }
                        continue;
                    }
                    self.foreground_task = None;
                    match result {
                        ReviewResult::Plan(plan) => {
                            self.overlay = Some(Overlay::Document {
                                title: "Installation plan".into(),
                                eyebrow: "READ-ONLY PREVIEW".into(),
                                lines: plan.lines().map(str::to_owned).collect(),
                                scroll: 0,
                                success: false,
                            });
                        }
                        ReviewResult::Incomplete(report) => {
                            self.overlay = Some(Overlay::Message {
                                title: "Plan incomplete".into(),
                                eyebrow: "REQUIRES ATTENTION".into(),
                                body: report.lines().map(str::to_owned).collect(),
                            });
                        }
                        ReviewResult::Rejected { state, message } => {
                            if let Some(state) = state {
                                self.state = state;
                            }
                            self.fail(message);
                        }
                    }
                }
            }
        }
    }

    fn open_help(&mut self) {
        self.foreground_task = None;
        self.overlay = Some(Overlay::Message {
            title: "Controls".into(),
            eyebrow: "TRITON INSTALLER".into(),
            body: vec![
                "↑ / ↓ or j / k    Move within the focused pane".into(),
                "Enter or →         Move into the settings pane".into(),
                "Enter or click     Open the focused setting".into(),
                "← or Esc           Return to section navigation".into(),
                "Mouse wheel        Scroll the focused list".into(),
                "Esc or Ctrl+C      Close the current dialog".into(),
                "q                  Request exit from the overview".into(),
                String::new(),
                "This installer prototype can inspect hardware and build a plan.".into(),
                "It cannot partition, format, mount or write a disk.".into(),
            ],
        });
    }

    fn fail(&mut self, message: String) {
        self.notice = message;
        self.notice_error = true;
    }
}

impl Drop for App {
    fn drop(&mut self) {
        self.worker_cancel.store(true, Ordering::Relaxed);
        self.jobs.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn closes_overlay(key: &KeyEvent) -> bool {
    key.code == KeyCode::Esc
        || (key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c'))
}

fn valid_swap_size(value: &str) -> bool {
    !value.is_empty() && value != "0" && value.chars().all(|character| character.is_ascii_digit())
}

fn detail_count_for(kind: StepKind) -> usize {
    match kind {
        StepKind::Region => 2,
        StepKind::Account => 3,
        _ => 1,
    }
}

fn account_value(form: &mut AccountForm) -> &mut String {
    match form.field {
        0 => &mut form.display,
        _ => &mut form.username,
    }
}

fn timezone_choices() -> Vec<ChoiceItem> {
    [
        ("UTC", "UTC", "Universal time"),
        ("Europe/Madrid", "Europe / Madrid", "Central European time"),
        ("Europe/London", "Europe / London", "United Kingdom"),
        ("Europe/Berlin", "Europe / Berlin", "Central European time"),
        ("America/New_York", "America / New York", "Eastern time"),
        (
            "America/Los_Angeles",
            "America / Los Angeles",
            "Pacific time",
        ),
        ("Asia/Tokyo", "Asia / Tokyo", "Japan standard time"),
    ]
    .into_iter()
    .map(|(value, label, detail)| ChoiceItem::new(value, label, detail))
    .collect()
}

#[cfg(test)]
mod tests {
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    use super::{closes_overlay, detail_count_for, valid_swap_size};
    use crate::model::StepKind;

    #[test]
    fn escape_and_control_c_close_the_active_overlay() {
        assert!(closes_overlay(&KeyEvent::new(
            KeyCode::Esc,
            KeyModifiers::NONE,
        )));
        assert!(closes_overlay(&KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::CONTROL,
        )));
        assert!(!closes_overlay(&KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::NONE,
        )));
    }

    #[test]
    fn custom_swap_requires_positive_mebibytes() {
        assert!(valid_swap_size("4096"));
        assert!(!valid_swap_size(""));
        assert!(!valid_swap_size("0"));
        assert!(!valid_swap_size("4GiB"));
    }

    #[test]
    fn detail_focus_matches_each_sections_selectable_rows() {
        assert_eq!(detail_count_for(StepKind::Keyboard), 1);
        assert_eq!(detail_count_for(StepKind::Region), 2);
        assert_eq!(detail_count_for(StepKind::Account), 3);
    }
}
