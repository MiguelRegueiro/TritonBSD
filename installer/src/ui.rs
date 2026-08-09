use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Direction, Layout, Margin, Rect, Size},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{
        Block, BorderType, Borders, Clear, Paragraph, Scrollbar, ScrollbarOrientation,
        ScrollbarState, Wrap,
    },
};
use ratatui_image::{Image, Resize, picker::Picker};
use unicode_width::UnicodeWidthStr;

use crate::{
    app::{AccountForm, App, FocusPane, Hit, HitRegion, Overlay},
    model::{STEPS, StatusTone, StepKind},
};

const ACCENT: Color = Color::Rgb(216, 154, 30);
const BACKGROUND: Color = Color::Rgb(6, 8, 10);
const PANEL: Color = Color::Rgb(9, 12, 16);
const PANEL_ALT: Color = Color::Rgb(17, 20, 25);
const BORDER: Color = Color::Rgb(52, 55, 60);
const TEXT: Color = Color::Rgb(226, 232, 240);
const MUTED: Color = Color::Rgb(135, 142, 151);
const FAINT: Color = Color::Rgb(77, 84, 94);
const GREEN: Color = Color::Rgb(118, 158, 112);
const AMBER: Color = Color::Rgb(224, 160, 16);
const RED: Color = Color::Rgb(248, 113, 113);
const SELECT_BG: Color = Color::Rgb(41, 49, 59);
const HOVER_BG: Color = Color::Rgb(27, 33, 41);

const SETUP_STEPS: usize = 10;
const LOGO_WIDTH: u16 = 20;
const LOGO_HEIGHT: u16 = 6;

pub fn load_logo() -> Option<ratatui_image::protocol::Protocol> {
    let source = image::load_from_memory(include_bytes!(
        "../../assets/branding/tritonbsd-logo-horizontal.png"
    ))
    .ok()?;
    let bounds = source.as_rgba8()?.dimensions();
    let rgba = source.into_rgba8();
    let mut left = bounds.0;
    let mut right = 0;
    for (x, _, pixel) in rgba.enumerate_pixels() {
        if pixel[3] != 0 {
            left = left.min(x);
            right = right.max(x + 1);
        }
    }
    if left >= right {
        return None;
    }
    let mut logo = image::imageops::crop_imm(&rgba, left, 0, right - left, bounds.1).to_image();
    for pixel in logo.pixels_mut() {
        let alpha = pixel[3] as u16;
        for (channel, background) in [9_u16, 12, 16].into_iter().enumerate() {
            pixel[channel] =
                ((pixel[channel] as u16 * alpha + background * (255 - alpha) + 127) / 255) as u8;
        }
        pixel[3] = 255;
    }
    let picker = Picker::from_query_stdio().unwrap_or_else(|_| Picker::halfblocks());
    picker
        .new_protocol(
            image::DynamicImage::ImageRgba8(logo),
            Size::new(LOGO_WIDTH, LOGO_HEIGHT),
            Resize::Fit(None),
        )
        .ok()
}

pub fn render(frame: &mut Frame, app: &mut App) {
    app.hits.clear();
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(BACKGROUND)),
        area,
    );
    if area.width < 54 || area.height < 17 {
        render_too_small(frame, area);
        return;
    }

    let vertical = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(10), Constraint::Length(1)])
        .split(area);
    render_workspace(frame, vertical[0], app);
    render_footer(frame, vertical[1], app);

    if let Some(overlay) = app.overlay.clone() {
        app.hits.clear();
        render_overlay(frame, area, app, &overlay);
    }
}

fn render_workspace(frame: &mut Frame, area: Rect, app: &mut App) {
    let inner = area.inner(Margin {
        horizontal: 0,
        vertical: 0,
    });
    if inner.width < 76 {
        if app.focus == FocusPane::Navigation {
            render_compact_navigation(frame, inner, app);
        } else {
            render_detail(frame, inner, app);
        }
        return;
    }
    let sidebar_width = if inner.width >= 116 { 35 } else { 30 };
    let columns = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length(sidebar_width),
            Constraint::Length(1),
            Constraint::Min(36),
        ])
        .split(inner);
    render_navigation(frame, columns[0], app);
    render_detail(frame, columns[2], app);
}

fn render_navigation(frame: &mut Frame, area: Rect, app: &mut App) {
    frame.render_widget(
        Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(if app.focus == FocusPane::Navigation {
                ACCENT
            } else {
                BORDER
            }))
            .style(Style::default().bg(PANEL)),
        area,
    );
    let area = area.inner(Margin {
        horizontal: 1,
        vertical: 1,
    });
    let logo_height = render_logo(frame, area, app);
    let list = Rect {
        y: area.y + logo_height,
        height: area.height.saturating_sub(logo_height),
        ..area
    };
    let visible = list.height as usize;
    keep_visible(&mut app.nav_scroll, app.selected, visible, STEPS.len());
    let end = (app.nav_scroll + visible).min(STEPS.len());
    for (row, index) in (app.nav_scroll..end).enumerate() {
        let rect = Rect {
            x: list.x,
            y: list.y + row as u16,
            width: list.width.saturating_sub(1),
            height: 1,
        };
        render_step_row(frame, rect, app, index, true);
        app.hits.push(HitRegion {
            rect,
            hit: Hit::Step(index),
        });
    }
    if STEPS.len() > visible {
        let mut state = ScrollbarState::new(STEPS.len()).position(app.selected);
        frame.render_stateful_widget(
            Scrollbar::new(ScrollbarOrientation::VerticalRight)
                .thumb_symbol("┃")
                .track_symbol(Some("│"))
                .begin_symbol(None)
                .end_symbol(None)
                .style(Style::default().fg(FAINT))
                .thumb_style(Style::default().fg(ACCENT)),
            list,
            &mut state,
        );
    }
}

fn render_logo(frame: &mut Frame, area: Rect, app: &App) -> u16 {
    if area.width < LOGO_WIDTH || area.height < 24 {
        return 0;
    }
    let logo_area = Rect {
        x: area.x + (area.width - LOGO_WIDTH) / 2,
        y: area.y,
        width: LOGO_WIDTH,
        height: LOGO_HEIGHT,
    };
    if let Some(logo) = app.logo.as_ref() {
        frame.render_widget(Image::new(logo), logo_area);
    } else {
        frame.render_widget(
            Paragraph::new("TritonBSD")
                .style(Style::default().fg(TEXT).add_modifier(Modifier::BOLD))
                .alignment(Alignment::Center),
            Rect {
                height: 1,
                ..logo_area
            },
        );
    }
    LOGO_HEIGHT
}

fn render_compact_navigation(frame: &mut Frame, area: Rect, app: &mut App) {
    frame.render_widget(
        Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(ACCENT))
            .style(Style::default().bg(PANEL)),
        area,
    );
    let area = area.inner(Margin {
        horizontal: 1,
        vertical: 1,
    });
    let logo_height = render_logo(frame, area, app);
    let list = Rect {
        y: area.y + logo_height,
        height: area.height.saturating_sub(logo_height + 2),
        ..area
    };
    let visible = list.height as usize;
    keep_visible(&mut app.nav_scroll, app.selected, visible, STEPS.len());
    let end = (app.nav_scroll + visible).min(STEPS.len());
    for (row, index) in (app.nav_scroll..end).enumerate() {
        let rect = Rect {
            x: list.x,
            y: list.y + row as u16,
            width: list.width.saturating_sub(1),
            height: 1,
        };
        render_step_row(frame, rect, app, index, false);
        app.hits.push(HitRegion {
            rect,
            hit: Hit::Step(index),
        });
    }
    if STEPS.len() > visible {
        let mut state = ScrollbarState::new(STEPS.len()).position(app.selected);
        frame.render_stateful_widget(
            Scrollbar::new(ScrollbarOrientation::VerticalRight)
                .thumb_symbol("┃")
                .track_symbol(Some("│"))
                .begin_symbol(None)
                .end_symbol(None)
                .thumb_style(Style::default().fg(ACCENT))
                .style(Style::default().fg(FAINT)),
            list,
            &mut state,
        );
    }
    let summary = app.state.summary(STEPS[app.selected].kind);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                "CURRENT  ",
                Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
            ),
            Span::styled(summary, Style::default().fg(TEXT)),
        ])),
        Rect {
            y: area.bottom().saturating_sub(1),
            height: 1,
            ..area
        },
    );
}

fn render_step_row(frame: &mut Frame, rect: Rect, app: &App, index: usize, show_group: bool) {
    let step = STEPS[index];
    let selected = index == app.selected;
    let navigation_focused = app.focus == FocusPane::Navigation;
    let hovered = matches!(app.hover, Some(Hit::Step(hit)) if hit == index);
    let base = if selected {
        Style::default()
            .fg(TEXT)
            .bg(if navigation_focused {
                SELECT_BG
            } else {
                HOVER_BG
            })
            .add_modifier(Modifier::BOLD)
    } else if hovered {
        Style::default().fg(TEXT).bg(HOVER_BG)
    } else {
        Style::default().fg(MUTED)
    };
    let marker = if selected { "▌" } else { " " };
    let (status, tone) = app.state.status_for(step.kind);
    let status_style = tone_style(tone);
    let group = if show_group && index < SETUP_STEPS {
        format!("{:02} ", index + 1)
    } else if show_group {
        " ·  ".into()
    } else {
        "    ".into()
    };
    let used = 2 + group.width() + step.label.width() + status.width();
    let gap = rect.width.saturating_sub(used as u16).max(1) as usize;
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                marker,
                Style::default().fg(ACCENT).bg(if selected {
                    if navigation_focused {
                        SELECT_BG
                    } else {
                        HOVER_BG
                    }
                } else if hovered {
                    HOVER_BG
                } else {
                    PANEL
                }),
            ),
            Span::styled(group, base.fg(FAINT)),
            Span::styled(step.label, base),
            Span::styled(" ".repeat(gap), base),
            Span::styled(status, base.patch(status_style)),
        ])),
        rect,
    );
}

fn render_detail(frame: &mut Frame, area: Rect, app: &mut App) {
    frame.render_widget(
        Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(if app.focus == FocusPane::Details {
                ACCENT
            } else {
                BORDER
            }))
            .style(Style::default().bg(PANEL)),
        area,
    );
    let area = area.inner(Margin {
        horizontal: 2,
        vertical: 1,
    });
    let step = STEPS[app.selected];
    let index = if app.selected < SETUP_STEPS {
        format!("{:02}", app.selected + 1)
    } else {
        " ·".into()
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                index,
                Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("  {}", step.group),
                Style::default().fg(MUTED).add_modifier(Modifier::BOLD),
            ),
        ])),
        Rect { height: 2, ..area },
    );
    frame.render_widget(
        Paragraph::new(step_title(step.kind))
            .style(Style::default().fg(TEXT).add_modifier(Modifier::BOLD)),
        Rect {
            y: area.y + 2,
            height: 2,
            ..area
        },
    );
    frame.render_widget(
        Paragraph::new(step_description(step.kind))
            .style(Style::default().fg(MUTED))
            .wrap(Wrap { trim: true }),
        Rect {
            y: area.y + 5,
            height: 3,
            ..area
        },
    );

    let controls_y = area.y + 9;
    for (offset, (label, value, tone)) in detail_controls(step.kind, app).into_iter().enumerate() {
        let y = controls_y + offset as u16 * 2;
        if y >= area.bottom().saturating_sub(1) {
            break;
        }
        let rect = Rect {
            y,
            height: 1,
            ..area
        };
        let focused = app.focus == FocusPane::Details && app.detail_selected == offset;
        let hovered = matches!(app.hover, Some(Hit::Detail(hit)) if hit == offset);
        let bg = if focused {
            SELECT_BG
        } else if hovered {
            HOVER_BG
        } else {
            PANEL
        };
        let marker = if focused { "▌ " } else { "  " };
        let used = marker.width() + label.width() + value.width();
        let gap = rect.width.saturating_sub(used as u16).max(2) as usize;
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(marker, Style::default().fg(ACCENT).bg(bg)),
                Span::styled(
                    label,
                    Style::default().fg(TEXT).bg(bg).add_modifier(if focused {
                        Modifier::BOLD
                    } else {
                        Modifier::empty()
                    }),
                ),
                Span::styled(" ".repeat(gap), Style::default().bg(bg)),
                Span::styled(value, tone_style(tone).bg(bg)),
            ])),
            rect,
        );
        app.hits.push(HitRegion {
            rect,
            hit: Hit::Detail(offset),
        });
    }
}

fn render_footer(frame: &mut Frame, area: Rect, app: &App) {
    let inner = area.inner(Margin {
        horizontal: 2,
        vertical: 0,
    });
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                if app.notice_error { "! " } else { "• " },
                Style::default().fg(if app.notice_error { RED } else { ACCENT }),
            ),
            Span::styled(
                &app.notice,
                Style::default().fg(if app.notice_error { RED } else { MUTED }),
            ),
        ])),
        Rect { height: 1, ..inner },
    );
}

fn render_overlay(frame: &mut Frame, screen: Rect, app: &mut App, overlay: &Overlay) {
    let available_height = screen.height.saturating_sub(6);
    let desired_height = match overlay {
        Overlay::Account(_) => 18,
        Overlay::Disks { .. } => 22,
        Overlay::Document { .. } => 24,
        Overlay::Choice { items, .. } => 7 + items.len() as u16,
        Overlay::Message { body, .. } => 8 + body.len() as u16,
        Overlay::Input { .. } => 14,
        Overlay::ConfirmTarget { .. } => 14,
        Overlay::ConfirmExit { .. } => 10,
    };
    let height = desired_height.min(available_height).max(10);
    let width = screen.width.saturating_sub(12).clamp(42, 88);
    let sheet = Rect {
        x: screen.x + (screen.width - width) / 2,
        y: screen.y + (screen.height - height) / 2,
        width,
        height,
    };
    frame.render_widget(Clear, sheet);
    frame.render_widget(
        Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(ACCENT))
            .style(Style::default().bg(PANEL)),
        sheet,
    );
    let inner = sheet.inner(Margin {
        horizontal: 2,
        vertical: 1,
    });

    match overlay {
        Overlay::Choice {
            title,
            eyebrow,
            items,
            selected,
            scroll,
            ..
        } => {
            render_sheet_header(frame, inner, eyebrow, title);
            render_choice_list(
                frame,
                Rect {
                    y: inner.y + 3,
                    height: inner.height.saturating_sub(4),
                    ..inner
                },
                app,
                items,
                *selected,
                *scroll,
            );
        }
        Overlay::Input {
            title,
            label,
            hint,
            value,
            ..
        } => {
            render_sheet_header(frame, inner, "SYSTEM IDENTITY", title);
            render_field(
                frame,
                Rect {
                    y: inner.y + 4,
                    height: 3,
                    ..inner
                },
                label,
                value,
                true,
            );
            frame.render_widget(
                Paragraph::new(hint.as_str()).style(Style::default().fg(FAINT)),
                Rect {
                    y: inner.y + 8,
                    height: 1,
                    ..inner
                },
            );
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    key("enter"),
                    hint_span(" save   "),
                    key("esc"),
                    hint_span(" cancel"),
                ])),
                Rect {
                    y: inner.bottom() - 1,
                    height: 1,
                    ..inner
                },
            );
        }
        Overlay::Account(form) => render_account(frame, inner, app, form),
        Overlay::Disks {
            items,
            selected,
            scroll,
        } => {
            render_sheet_header(
                frame,
                inner,
                "READ-ONLY HARDWARE SCAN",
                "Choose a target disk",
            );
            render_disks(
                frame,
                Rect {
                    y: inner.y + 3,
                    height: inner.height.saturating_sub(5),
                    ..inner
                },
                app,
                items,
                *selected,
                *scroll,
            );
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    key("r"),
                    hint_span(" refresh   "),
                    key("enter"),
                    hint_span(" inspect   "),
                    key("esc"),
                    hint_span(" back"),
                ])),
                Rect {
                    y: inner.bottom() - 1,
                    height: 1,
                    ..inner
                },
            );
        }
        Overlay::ConfirmTarget {
            disk,
            confirm_selected,
        } => render_target_confirmation(frame, inner, app, disk, *confirm_selected),
        Overlay::Document {
            title,
            eyebrow,
            lines,
            scroll,
            success,
        } => render_document(frame, inner, title, eyebrow, lines, *scroll, *success),
        Overlay::Message {
            title,
            eyebrow,
            body,
        } => render_message(frame, inner, app, title, eyebrow, body),
        Overlay::ConfirmExit { confirm_selected } => {
            render_exit(frame, inner, app, *confirm_selected)
        }
    }
}

fn render_sheet_header(frame: &mut Frame, area: Rect, eyebrow: &str, title: &str) {
    frame.render_widget(
        Paragraph::new(eyebrow).style(Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
        Rect { height: 1, ..area },
    );
    frame.render_widget(
        Paragraph::new(title).style(Style::default().fg(TEXT).add_modifier(Modifier::BOLD)),
        Rect {
            y: area.y + 1,
            height: 1,
            ..area
        },
    );
}

fn render_choice_list(
    frame: &mut Frame,
    area: Rect,
    app: &mut App,
    items: &[crate::app::ChoiceItem],
    selected: usize,
    mut scroll: usize,
) {
    let rows = area.height.max(1) as usize;
    keep_visible(&mut scroll, selected, rows, items.len());
    let label_column = items
        .iter()
        .map(|item| item.label.width())
        .max()
        .unwrap_or_default()
        .saturating_add(3)
        .min((area.width as usize / 2).max(1));
    for (visible_index, index) in (scroll..(scroll + rows).min(items.len())).enumerate() {
        let rect = Rect {
            x: area.x,
            y: area.y + visible_index as u16,
            width: area.width.saturating_sub(1),
            height: 1,
        };
        let focused = index == selected;
        let hovered = matches!(app.hover, Some(Hit::OverlayItem(hit)) if hit == index);
        let bg = if focused {
            SELECT_BG
        } else if hovered {
            HOVER_BG
        } else {
            PANEL
        };
        let label = clip(&items[index].label, label_column.saturating_sub(1));
        let padding = label_column.saturating_sub(label.width());
        let detail_width = rect
            .width
            .saturating_sub(2)
            .saturating_sub(label_column as u16) as usize;
        let detail = clip(&items[index].detail, detail_width);
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(
                    if focused { "▌ " } else { "  " },
                    Style::default().fg(ACCENT).bg(bg),
                ),
                Span::styled(
                    label,
                    Style::default().fg(TEXT).bg(bg).add_modifier(if focused {
                        Modifier::BOLD
                    } else {
                        Modifier::empty()
                    }),
                ),
                Span::styled(" ".repeat(padding), Style::default().bg(bg)),
                Span::styled(detail, Style::default().fg(MUTED).bg(bg)),
            ])),
            rect,
        );
        app.hits.push(HitRegion {
            rect,
            hit: Hit::OverlayItem(index),
        });
    }
    render_scrollbar(frame, area, items.len(), selected, rows);
}

fn render_disks(
    frame: &mut Frame,
    area: Rect,
    app: &mut App,
    items: &[crate::model::Disk],
    selected: usize,
    mut scroll: usize,
) {
    let rows = (area.height / 3).max(1) as usize;
    keep_visible(&mut scroll, selected, rows, items.len());
    for (visible_index, index) in (scroll..(scroll + rows).min(items.len())).enumerate() {
        let rect = Rect {
            x: area.x,
            y: area.y + visible_index as u16 * 3,
            width: area.width.saturating_sub(1),
            height: 3,
        };
        let disk = &items[index];
        let focused = index == selected;
        let hovered = matches!(app.hover, Some(Hit::OverlayItem(hit)) if hit == index);
        let bg = if focused {
            SELECT_BG
        } else if hovered {
            HOVER_BG
        } else {
            PANEL
        };
        let availability = if disk.available {
            "available"
        } else {
            "blocked"
        };
        let availability_style = if disk.available {
            Style::default().fg(GREEN)
        } else {
            Style::default().fg(RED)
        };
        let right = disk.size.width() + availability.width() + 5;
        let model_width = rect.width.saturating_sub(right as u16 + 8) as usize;
        let model = clip(&disk.model, model_width);
        frame.render_widget(
            Paragraph::new(vec![
                Line::from(vec![
                    Span::styled(
                        if focused { "▌ " } else { "  " },
                        Style::default().fg(ACCENT).bg(bg),
                    ),
                    Span::styled(
                        &disk.path,
                        Style::default()
                            .fg(TEXT)
                            .bg(bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(format!("  {model}"), Style::default().fg(MUTED).bg(bg)),
                    Span::styled(
                        " ".repeat(rect.width.saturating_sub(
                            4 + disk.path.width() as u16 + model.width() as u16 + right as u16,
                        ) as usize),
                        Style::default().bg(bg),
                    ),
                    Span::styled(format!("{}  ", disk.size), Style::default().fg(TEXT).bg(bg)),
                    Span::styled(
                        availability,
                        availability_style.bg(bg).add_modifier(Modifier::BOLD),
                    ),
                ]),
                Line::from(vec![
                    Span::styled("    ", Style::default().bg(bg)),
                    Span::styled(
                        format!("serial {}  ·  {}-byte sectors", disk.serial, disk.sector),
                        Style::default().fg(FAINT).bg(bg),
                    ),
                ]),
                Line::from(vec![
                    Span::styled("    ", Style::default().bg(bg)),
                    Span::styled(
                        if disk.available {
                            "Identity can be proven".to_owned()
                        } else {
                            format!("Blocked: {}", disk.reason)
                        },
                        Style::default()
                            .fg(if disk.available { MUTED } else { RED })
                            .bg(bg),
                    ),
                ]),
            ]),
            rect,
        );
        app.hits.push(HitRegion {
            rect,
            hit: Hit::OverlayItem(index),
        });
    }
    render_scrollbar(frame, area, items.len(), selected, rows);
}

fn render_account(frame: &mut Frame, area: Rect, app: &mut App, form: &AccountForm) {
    render_sheet_header(frame, area, "LOCAL USER", "Create your account");
    let fields = [
        ("Full name", form.display.as_str()),
        ("Username", form.username.as_str()),
    ];
    for (index, (label, value)) in fields.into_iter().enumerate() {
        let rect = Rect {
            x: area.x,
            y: area.y + 3 + index as u16 * 3,
            width: area.width,
            height: 3,
        };
        render_field(frame, rect, label, value, index == form.field);
        app.hits.push(HitRegion {
            rect,
            hit: Hit::AccountField(index),
        });
    }
    let admin_y = area.y + 9;
    let admin = Rect {
        x: area.x,
        y: admin_y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                if form.field == 2 { "▌ " } else { "  " },
                Style::default().fg(ACCENT),
            ),
            Span::styled(
                if form.admin { "●" } else { "○" },
                Style::default().fg(if form.admin { ACCENT } else { MUTED }),
            ),
            Span::styled(
                "  Allow administrative tasks",
                Style::default().fg(TEXT).add_modifier(if form.field == 2 {
                    Modifier::BOLD
                } else {
                    Modifier::empty()
                }),
            ),
        ])),
        admin,
    );
    app.hits.push(HitRegion {
        rect: admin,
        hit: Hit::AccountField(2),
    });
    let save = Rect {
        x: area.x,
        y: area.bottom().saturating_sub(1),
        width: 20,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Span::styled(
            "  Save account  →",
            Style::default()
                .fg(TEXT)
                .bg(SELECT_BG)
                .add_modifier(Modifier::BOLD),
        )),
        save,
    );
    app.hits.push(HitRegion {
        rect: save,
        hit: Hit::AccountSave,
    });
}

fn render_field(frame: &mut Frame, area: Rect, label: &str, value: &str, active: bool) {
    let border = if active { ACCENT } else { BORDER };
    frame.render_widget(
        Paragraph::new(format!(" {value}"))
            .style(Style::default().fg(TEXT).bg(PANEL_ALT))
            .block(
                Block::default()
                    .title(Span::styled(
                        format!(" {label} "),
                        Style::default()
                            .fg(if active { ACCENT } else { MUTED })
                            .add_modifier(Modifier::BOLD),
                    ))
                    .borders(Borders::ALL)
                    .border_type(BorderType::Rounded)
                    .border_style(Style::default().fg(border))
                    .style(Style::default().bg(PANEL_ALT)),
            ),
        area,
    );
    if active {
        let x = area.x + 2 + value.width().min(area.width.saturating_sub(4) as usize) as u16;
        frame.set_cursor_position((x, area.y + 1));
    }
}

fn render_target_confirmation(
    frame: &mut Frame,
    area: Rect,
    app: &mut App,
    disk: &crate::model::Disk,
    confirm_selected: bool,
) {
    render_sheet_header(
        frame,
        area,
        "RECORD TARGET IDENTITY",
        "Use this disk in the plan?",
    );
    let lines = [
        ("DEVICE", disk.path.as_str()),
        ("MODEL", disk.model.as_str()),
        ("SERIAL", disk.serial.as_str()),
        ("CAPACITY", disk.size.as_str()),
        ("SECTOR SIZE", disk.sector.as_str()),
    ];
    for (index, (label, value)) in lines.into_iter().enumerate() {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(format!("{label:<14}"), Style::default().fg(FAINT)),
                Span::styled(value, Style::default().fg(TEXT)),
            ])),
            Rect {
                y: area.y + 4 + index as u16,
                height: 1,
                ..area
            },
        );
    }
    frame.render_widget(
        Paragraph::new("This records identity only. No disk will be modified.")
            .style(Style::default().fg(AMBER)),
        Rect {
            y: area.y + 10,
            height: 1,
            ..area
        },
    );
    render_buttons(frame, area, app, "Record target", "Back", confirm_selected);
}

fn render_document(
    frame: &mut Frame,
    area: Rect,
    title: &str,
    eyebrow: &str,
    lines: &[String],
    scroll: usize,
    success: bool,
) {
    render_sheet_header(frame, area, eyebrow, title);
    let body = Rect {
        y: area.y + 3,
        height: area.height.saturating_sub(5),
        ..area
    };
    for (row, line) in lines
        .iter()
        .skip(scroll)
        .take(body.height as usize)
        .enumerate()
    {
        let style = if line.starts_with("[pass]") || (success && line.contains("No disk writes")) {
            Style::default().fg(GREEN)
        } else if line.starts_with("[") {
            Style::default().fg(AMBER)
        } else {
            Style::default().fg(TEXT)
        };
        frame.render_widget(
            Paragraph::new(line.as_str()).style(style),
            Rect {
                y: body.y + row as u16,
                height: 1,
                ..body
            },
        );
    }
    if lines.len() > body.height as usize {
        render_scrollbar(frame, body, lines.len(), scroll, body.height as usize);
    }
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            key("↑↓"),
            hint_span(" scroll   "),
            key("enter"),
            hint_span(" return"),
        ])),
        Rect {
            y: area.bottom() - 1,
            height: 1,
            ..area
        },
    );
}

fn render_message(
    frame: &mut Frame,
    area: Rect,
    app: &mut App,
    title: &str,
    eyebrow: &str,
    body: &[String],
) {
    render_sheet_header(frame, area, eyebrow, title);
    for (index, line) in body
        .iter()
        .take(area.height.saturating_sub(6) as usize)
        .enumerate()
    {
        frame.render_widget(
            Paragraph::new(line.as_str()).style(Style::default().fg(
                if line.starts_with("Reason:") {
                    RED
                } else {
                    TEXT
                },
            )),
            Rect {
                y: area.y + 4 + index as u16,
                height: 1,
                ..area
            },
        );
    }
    let close = Rect {
        x: area.x,
        y: area.bottom() - 1,
        width: 12,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Span::styled(
            "  Close  ",
            Style::default()
                .fg(TEXT)
                .bg(SELECT_BG)
                .add_modifier(Modifier::BOLD),
        )),
        close,
    );
    app.hits.push(HitRegion {
        rect: close,
        hit: Hit::OverlayCancel,
    });
}

fn render_exit(frame: &mut Frame, area: Rect, app: &mut App, confirm_selected: bool) {
    render_sheet_header(
        frame,
        area,
        "LEAVE INSTALLER",
        "Exit this installer session?",
    );
    frame.render_widget(
        Paragraph::new("Your installer settings will be discarded. No disk has been modified.")
            .style(Style::default().fg(MUTED))
            .wrap(Wrap { trim: true }),
        Rect {
            y: area.y + 4,
            height: 3,
            ..area
        },
    );
    render_buttons(
        frame,
        area,
        app,
        "Exit installer",
        "Keep planning",
        confirm_selected,
    );
}

fn render_buttons(
    frame: &mut Frame,
    area: Rect,
    app: &mut App,
    confirm: &str,
    cancel: &str,
    confirm_selected: bool,
) {
    let cancel_width = cancel.width() as u16 + 4;
    let confirm_width = confirm.width() as u16 + 4;
    let y = area.bottom().saturating_sub(1);
    let cancel_rect = Rect {
        x: area.right().saturating_sub(cancel_width),
        y,
        width: cancel_width,
        height: 1,
    };
    let confirm_rect = Rect {
        x: cancel_rect.x.saturating_sub(confirm_width + 2),
        y,
        width: confirm_width,
        height: 1,
    };
    let confirm_hovered = matches!(app.hover, Some(Hit::OverlayConfirm));
    let cancel_hovered = matches!(app.hover, Some(Hit::OverlayCancel));
    let confirm_active = confirm_hovered || (!cancel_hovered && confirm_selected);
    let cancel_active = cancel_hovered || (!confirm_hovered && !confirm_selected);

    frame.render_widget(
        Paragraph::new(format!(
            "{} {confirm}  ",
            if confirm_active { "▌" } else { " " }
        ))
        .style(
            Style::default()
                .fg(if confirm_active { Color::Black } else { TEXT })
                .bg(if confirm_active { ACCENT } else { SELECT_BG })
                .add_modifier(Modifier::BOLD),
        ),
        confirm_rect,
    );
    frame.render_widget(
        Paragraph::new(format!(
            "{} {cancel}  ",
            if cancel_active { "▌" } else { " " }
        ))
        .style(
            Style::default()
                .fg(if cancel_active { Color::Black } else { TEXT })
                .bg(if cancel_active { ACCENT } else { SELECT_BG })
                .add_modifier(Modifier::BOLD),
        ),
        cancel_rect,
    );
    app.hits.push(HitRegion {
        rect: confirm_rect,
        hit: Hit::OverlayConfirm,
    });
    app.hits.push(HitRegion {
        rect: cancel_rect,
        hit: Hit::OverlayCancel,
    });
}

fn render_scrollbar(
    frame: &mut Frame,
    area: Rect,
    length: usize,
    position: usize,
    viewport: usize,
) {
    if length <= viewport {
        return;
    }
    let mut state = ScrollbarState::new(length).position(position);
    frame.render_stateful_widget(
        Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .thumb_symbol("┃")
            .track_symbol(Some("│"))
            .begin_symbol(None)
            .end_symbol(None)
            .style(Style::default().fg(FAINT))
            .thumb_style(Style::default().fg(ACCENT)),
        area,
        &mut state,
    );
}

fn render_too_small(frame: &mut Frame, area: Rect) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage(40),
            Constraint::Length(5),
            Constraint::Min(0),
        ])
        .split(area);
    frame.render_widget(
        Paragraph::new("◈  TRITON / INSTALLER")
            .style(Style::default().fg(ACCENT).add_modifier(Modifier::BOLD))
            .alignment(Alignment::Center),
        Rect {
            y: rows[1].y,
            height: 1,
            ..rows[1]
        },
    );
    frame.render_widget(
        Paragraph::new(format!(
            "Terminal is {}×{}\nResize to at least 54×17",
            area.width, area.height
        ))
        .style(Style::default().fg(MUTED))
        .alignment(Alignment::Center),
        Rect {
            y: rows[1].y + 2,
            height: 2,
            ..rows[1]
        },
    );
}

fn keep_visible(scroll: &mut usize, selected: usize, visible: usize, total: usize) {
    if total <= visible {
        *scroll = 0;
        return;
    }
    if selected < *scroll {
        *scroll = selected;
    }
    if selected >= *scroll + visible {
        *scroll = selected + 1 - visible;
    }
    *scroll = (*scroll).min(total.saturating_sub(visible));
}

fn detail_controls(kind: StepKind, app: &App) -> Vec<(&'static str, String, StatusTone)> {
    match kind {
        StepKind::Keyboard => vec![(
            "Keyboard layout",
            app.state.get("KEYBOARD_KEYMAP").to_owned(),
            StatusTone::Neutral,
        )],
        StepKind::Region => vec![
            (
                "Language",
                app.state.get("LOCALE").to_owned(),
                StatusTone::Neutral,
            ),
            (
                "Time zone",
                app.state.get("TIMEZONE").to_owned(),
                StatusTone::Neutral,
            ),
        ],
        StepKind::Network => vec![(
            "Inspect interfaces",
            "read only".into(),
            StatusTone::Neutral,
        )],
        StepKind::Hostname => vec![(
            "Computer name",
            app.state.get("HOSTNAME").to_owned(),
            StatusTone::Neutral,
        )],
        StepKind::Account => vec![
            (
                "Full name",
                app.state.get("DISPLAY_NAME").to_owned(),
                if app.state.get("DISPLAY_NAME").is_empty() {
                    StatusTone::Attention
                } else {
                    StatusTone::Neutral
                },
            ),
            (
                "Username",
                app.state.get("USERNAME").to_owned(),
                if app.state.get("USERNAME").is_empty() {
                    StatusTone::Attention
                } else {
                    StatusTone::Neutral
                },
            ),
            (
                "Administrative access",
                app.state.get("ADMIN_ACCESS").to_owned(),
                StatusTone::Neutral,
            ),
        ],
        StepKind::Target => vec![(
            "Target disk",
            app.state.summary(kind),
            if app.state.target_ready() {
                StatusTone::Ready
            } else {
                StatusTone::Attention
            },
        )],
        StepKind::Layout => vec![(
            "Storage layout",
            app.state.summary(kind),
            StatusTone::Neutral,
        )],
        StepKind::Profile => vec![(
            "Package source",
            app.state.get("PACKAGE_SOURCE").to_owned(),
            StatusTone::Neutral,
        )],
        StepKind::Boot => vec![("Boot mode", app.state.summary(kind), StatusTone::Neutral)],
        StepKind::Review => vec![(
            "Review installation plan",
            "open".into(),
            if app.state.account_ready() && app.state.target_ready() {
                StatusTone::Ready
            } else {
                StatusTone::Attention
            },
        )],
        StepKind::Help => vec![("Installer help", "open".into(), StatusTone::Neutral)],
        StepKind::Exit => vec![("Exit installer", "open".into(), StatusTone::Attention)],
    }
}

fn step_title(kind: StepKind) -> &'static str {
    match kind {
        StepKind::Keyboard => "Choose how keys are interpreted",
        StepKind::Region => "Set language and local time",
        StepKind::Network => "Inspect live connectivity",
        StepKind::Hostname => "Name this TritonBSD system",
        StepKind::Account => "Create the primary local account",
        StepKind::Target => "Choose where TritonBSD would be installed",
        StepKind::Layout => "Plan the disk layout",
        StepKind::Profile => "Choose where packages come from",
        StepKind::Boot => "Configure firmware startup",
        StepKind::Review => "Read the complete plan",

        StepKind::Help => "Installer controls and safety",
        StepKind::Exit => "Leave the installer",
    }
}

fn step_description(kind: StepKind) -> &'static str {
    match kind {
        StepKind::Target => {
            "Hardware is scanned read-only. Live media, mounted disks, active swap, ambiguous identity and incomplete metadata are blocked."
        }
        StepKind::Account => {
            "This installer prototype records the account identity only. Passphrase setup is deferred until a secure installation backend exists."
        }

        StepKind::Review => {
            "This document describes future actions. The installer prototype contains no partitioning, formatting or installation backend."
        }
        _ => "Select a setting below. Changes apply only to this installer session.",
    }
}

fn tone_style(tone: StatusTone) -> Style {
    Style::default().fg(match tone {
        StatusTone::Ready => GREEN,
        StatusTone::Attention => AMBER,
        StatusTone::Muted => FAINT,
        StatusTone::Neutral => TEXT,
    })
}

fn key(value: &'static str) -> Span<'static> {
    Span::styled(
        format!(" {value} "),
        Style::default()
            .fg(TEXT)
            .bg(SELECT_BG)
            .add_modifier(Modifier::BOLD),
    )
}
fn hint_span(value: &'static str) -> Span<'static> {
    Span::styled(value, Style::default().fg(MUTED))
}
fn clip(value: &str, width: usize) -> String {
    if value.width() <= width {
        return value.to_owned();
    }
    if width <= 1 {
        return "…".into();
    }
    let mut output = String::new();
    for character in value.chars() {
        if output.width() + character.to_string().width() + 1 > width {
            break;
        }
        output.push(character);
    }
    output.push('…');
    output
}

#[cfg(test)]
mod tests {
    use super::{clip, keep_visible};

    #[test]
    fn navigation_scroll_keeps_large_font_viewport_usable() {
        let mut scroll = 0;
        keep_visible(&mut scroll, 13, 6, 14);
        assert_eq!(scroll, 8);
        keep_visible(&mut scroll, 2, 6, 14);
        assert_eq!(scroll, 2);
    }

    #[test]
    fn clipping_preserves_exact_visible_width() {
        assert_eq!(clip("Kingston DataTraveler", 10), "Kingston …");
        assert_eq!(clip("NVMe", 10), "NVMe");
    }
}
