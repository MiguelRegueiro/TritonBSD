use std::io::{self, Stdout, Write};

use anyhow::{Context, Result};
use crossterm::{
    cursor::{Hide, Show},
    event::{DisableBracketedPaste, EnableBracketedPaste},
    execute,
    terminal::{
        Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode,
        enable_raw_mode,
    },
};
use ratatui::{Terminal, backend::CrosstermBackend};

const ENABLE_MOUSE: &[u8] = b"\x1b[?1015l\x1b[?1016l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h";
const DISABLE_MOUSE: &[u8] = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1015l\x1b[?1016l";

pub type Tui = Terminal<CrosstermBackend<Stdout>>;

pub struct TerminalSession {
    pub terminal: Tui,
}

struct SetupGuard(bool);

impl Drop for SetupGuard {
    fn drop(&mut self) {
        if self.0 {
            TerminalSession::restore();
        }
    }
}

impl TerminalSession {
    pub fn enter() -> Result<Self> {
        enable_raw_mode().context("cannot enable raw terminal mode")?;
        let mut guard = SetupGuard(true);
        let mut stdout = io::stdout();
        if let Err(error) = execute!(
            stdout,
            EnterAlternateScreen,
            Clear(ClearType::All),
            Hide,
            EnableBracketedPaste
        ) {
            return Err(error).context("cannot enter installer terminal mode");
        }
        stdout
            .write_all(ENABLE_MOUSE)
            .context("cannot enable Kitty-safe mouse tracking")?;
        stdout.flush().context("cannot flush terminal setup")?;
        let terminal = Terminal::new(CrosstermBackend::new(stdout))
            .context("cannot initialize terminal renderer")?;
        guard.0 = false;
        Ok(Self { terminal })
    }

    pub fn restore() {
        let mut stdout = io::stdout();
        let _ = stdout.write_all(DISABLE_MOUSE);
        let _ = execute!(stdout, DisableBracketedPaste, Show, LeaveAlternateScreen);
        let _ = stdout.flush();
        let _ = disable_raw_mode();
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        Self::restore();
    }
}

#[cfg(test)]
mod tests {
    use super::{DISABLE_MOUSE, ENABLE_MOUSE};

    #[test]
    fn kitty_pixel_mouse_mode_is_never_enabled() {
        assert!(!ENABLE_MOUSE.windows(8).any(|mode| mode == b"\x1b[?1016h"));
        assert!(ENABLE_MOUSE.windows(8).any(|mode| mode == b"\x1b[?1016l"));
    }

    #[test]
    fn teardown_disables_every_enabled_mouse_mode() {
        for mode in [
            b"\x1b[?1000l",
            b"\x1b[?1002l",
            b"\x1b[?1003l",
            b"\x1b[?1006l",
        ] {
            assert!(DISABLE_MOUSE.windows(mode.len()).any(|part| part == mode));
        }
    }
}
