mod app;
mod backend;
mod model;
mod terminal;
mod ui;

use std::{
    env,
    io::IsTerminal,
    panic,
    sync::{Arc, atomic::AtomicBool},
};

use anyhow::{Context, Result, bail};
use signal_hook::{
    consts::signal::{SIGHUP, SIGINT, SIGTERM},
    flag,
};

use crate::{app::App, backend::Backend, terminal::TerminalSession};

fn main() {
    if let Err(error) = run() {
        TerminalSession::restore();
        eprintln!("triton-install: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    match env::args().nth(1).as_deref() {
        Some("--self-test") => {
            println!("rust-ui-ok");
            return Ok(());
        }
        Some(_) => bail!("usage: triton-install"),
        None => {}
    }
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        bail!("an interactive terminal is required");
    }

    let backend = Backend::new().context("cannot initialize installer model")?;
    let terminate = Arc::new(AtomicBool::new(false));
    for signal in [SIGHUP, SIGINT, SIGTERM] {
        flag::register(signal, Arc::clone(&terminate))
            .context("cannot install terminal-restoration signal handler")?;
    }
    let mut session = TerminalSession::enter()?;
    let mut app = App::new(backend, terminate).context("cannot read installer state")?;

    let previous = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        TerminalSession::restore();
        previous(info);
    }));

    app.run(&mut session.terminal)
}
