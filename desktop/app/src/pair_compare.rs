//! The «Сравнение» window (the Mac's `PairCompareWindow`): the two runs of a pair side by side — the outcome, the
//! answer and the files each one changed, a file's changes line by line, one variant against the other, and
//! «Оставить этот вариант», «Влить в …», «Убрать папку и ветку». Opened by «Сравнить с …» under a run of a pair.

use crate::runs::{outcome_text, Runs};
use crate::strings;
use claudepult_core::pair_compare::{self, DiffLine};
use claudepult_core::projects::Tools;
use claudepult_core::runs::{Run, RunState};
use claudepult_core::session_changes;
use serde::Serialize;
use std::path::Path;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

/// The pair the window shows.
#[derive(Default)]
pub struct PairCompare {
    pair: Mutex<Option<String>>,
}

fn git() -> Result<std::path::PathBuf, String> {
    Tools::find().map(|tools| tools.git).ok_or_else(|| "git".to_owned())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FileRow {
    path: String,
    added: Option<String>,
    removed: Option<String>,
    note: Option<String>,
    /// Both sides changed it.
    common: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Side {
    id: String,
    agent: &'static str,
    /// «готово», «влит в main»…
    state: String,
    /// `ok`, `error` or `secondary`: the colour of `state`.
    tone: &'static str,
    branch: Option<String>,
    outcome: String,
    /// None until git has been asked; then «файлов: 3 +120 −8» and the files.
    summary: Option<String>,
    files: Option<Vec<FileRow>>,
    folder_gone: bool,
    keep: Option<String>,
    merge: Option<(String, String)>,
    tidy: Option<String>,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PairView {
    title: String,
    sides: Vec<Side>,
    /// «Оба изменили файлов: 2».
    common: Option<String>,
    between: bool,
    finished: bool,
}

/// What git says of both sides now; reads the folders, so it runs off the main thread.
fn view(app: &AppHandle) -> PairView {
    let texts = strings(app);
    let Some(pair) = app.state::<PairCompare>().pair.lock().unwrap().clone() else { return PairView::default() };
    let runs = app.state::<Runs>().list();
    let Some(sides) = pair_compare::sides(&pair, &runs) else { return PairView::default() };
    let git = git().ok();
    let target = git.as_deref().and_then(|git| pair_compare::current_branch(git, Path::new(&sides[0].project_path)));
    let changes: Vec<Option<session_changes::Changes>> = sides
        .iter()
        .map(|run| if run.discarded() { None } else { git.as_deref().and_then(|git| session_changes::read(git, Path::new(&run.folder), Some(run.started_at))) })
        .collect();
    let paths: Vec<Vec<String>> = changes.iter().map(|c| c.as_ref().map(|c| c.files.iter().map(|f| f.path.clone()).collect()).unwrap_or_default()).collect();
    let common: Vec<String> = pair_compare::common(&paths[0], &paths[1]).into_iter().cloned().collect();
    let side = |run: &Run, changes: &Option<session_changes::Changes>| {
        let (state, tone) = match pair_compare::side_state(&texts, run) {
            Some(text) => (text, if run.merged_into().is_some() { "ok" } else { "error" }),
            None => (
                outcome_state(&texts, run),
                match run.state {
                    RunState::Succeeded => "ok",
                    RunState::Failed => "error",
                    _ => "secondary",
                },
            ),
        };
        let other = sides.iter().find(|s| s.id != run.id);
        Side {
            id: run.id.clone(),
            agent: run.agent_title(),
            state,
            tone,
            branch: run.worktree_branch.clone(),
            outcome: outcome_text(&texts, run),
            summary: changes.as_ref().filter(|c| !c.files.is_empty()).map(|c| c.summary(&texts)),
            files: changes.as_ref().map(|c| {
                c.files
                    .iter()
                    .take(200)
                    .map(|file| {
                        let lines = file.added.zip(file.removed);
                        FileRow {
                            path: file.path.clone(),
                            added: lines.map(|(a, _)| a).filter(|a| *a > 0).map(|a| format!("+{a}")),
                            removed: lines.map(|(_, r)| r).filter(|r| *r > 0).map(|r| format!("−{r}")),
                            note: if file.is_new { Some(texts.t("новый").to_owned()) } else if lines.is_none() { Some(texts.t("двоичный").to_owned()) } else { None },
                            common: common.contains(&file.path),
                        }
                    })
                    .collect()
            }),
            folder_gone: run.discarded() || !Path::new(&run.folder).exists(),
            keep: other.filter(|_| pair_compare::can_keep(run, &sides)).map(|other| pair_compare::removal_warning(&texts, other)),
            merge: target.as_deref().filter(|target| pair_compare::can_merge(run, &sides, Some(target))).map(|target| (texts.format("Влить в %@", &[target]), pair_compare::merge_warning(&texts, run, target))),
            tidy: pair_compare::can_tidy(run).then(|| pair_compare::tidy_warning(&texts, run)),
        }
    };
    let finished = sides.iter().all(|run| run.state != RunState::Running);
    PairView {
        title: format!("{}: {}", sides[0].project, sides[0].task),
        common: (!common.is_empty()).then(|| texts.format("Оба изменили файлов: %lld", &[&common.len().to_string()])),
        between: finished && sides.iter().all(|run| !run.discarded() && run.worktree_branch.is_some()),
        finished,
        sides: sides.iter().zip(&changes).map(|(run, changes)| side(run, changes)).collect(),
    }
}

/// A run's state as the panel says it.
fn outcome_state(texts: &claudepult_core::i18n::Strings, run: &Run) -> String {
    match run.state {
        RunState::Running => texts.t("выполняется").to_owned(),
        RunState::Succeeded => texts.t("готово").to_owned(),
        RunState::Failed => texts.t("ошибка").to_owned(),
        RunState::Stopped | RunState::TimedOut => texts.t("завершена").to_owned(),
    }
}

#[tauri::command]
pub async fn pair_view(app: AppHandle) -> PairView {
    tauri::async_runtime::spawn_blocking(move || view(&app)).await.unwrap_or_default()
}

/// «Сравнить с …» under a run: its pair in the window.
#[tauri::command]
pub fn open_pair_compare(app: AppHandle, id: String) -> Result<(), String> {
    let runs = app.state::<Runs>().list();
    let pair = runs.iter().find(|run| run.id == id).and_then(Run::pair).ok_or("not a pair")?.to_owned();
    *app.state::<PairCompare>().pair.lock().unwrap() = Some(pair);
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("pair-compare") {
        let _ = window.emit("pair-changed", ());
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let title = format!("{} — {}", claudepult_core::APP_NAME, strings(&app).t("Сравнение"));
    crate::off_main_thread(move || {
        let _ = tauri::WebviewWindowBuilder::new(&app, "pair-compare", tauri::WebviewUrl::App("pair-compare.html".into())).title(title).inner_size(900.0, 560.0).min_inner_size(640.0, 380.0).center().build();
    });
    Ok(())
}

fn side(app: &AppHandle, id: &str) -> Result<(Run, Vec<Run>), String> {
    let pair = app.state::<PairCompare>().pair.lock().unwrap().clone().ok_or("no pair")?;
    let runs = app.state::<Runs>().list();
    let sides: Vec<Run> = pair_compare::sides(&pair, &runs).ok_or("no pair")?.into_iter().cloned().collect();
    let run = sides.iter().find(|run| run.id == id).cloned().ok_or("not a side of the pair")?;
    Ok((run, sides))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffView {
    title: String,
    lines: Vec<DiffLine>,
    cut: bool,
}

/// A click on a file: what that side changed in it.
#[tauri::command]
pub async fn pair_file_diff(app: AppHandle, id: String, path: String) -> Result<DiffView, String> {
    let (run, _) = side(&app, &id)?;
    let listed = session_changes::read(&git()?, Path::new(&run.folder), Some(run.started_at)).is_some_and(|c| c.files.iter().any(|f| f.path == path));
    if !listed {
        return Err("not a changed file".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let (lines, cut) = pair_compare::diff_lines(&pair_compare::file_diff(&git()?, &run, &path), pair_compare::DIFF_LIMIT);
        Ok(DiffView { title: format!("{}: {path}", run.agent_title()), lines, cut })
    })
    .await
    .map_err(|e| e.to_string())?
}

/// «Различия между вариантами»: the second side's branch against the first's.
#[tauri::command]
pub async fn pair_between_diff(app: AppHandle) -> Result<DiffView, String> {
    let pair = app.state::<PairCompare>().pair.lock().unwrap().clone().ok_or("no pair")?;
    let runs = app.state::<Runs>().list();
    let sides: Vec<Run> = pair_compare::sides(&pair, &runs).ok_or("no pair")?.into_iter().cloned().collect();
    tauri::async_runtime::spawn_blocking(move || {
        let refs: Vec<&Run> = sides.iter().collect();
        let (lines, cut) = pair_compare::diff_lines(&pair_compare::between_diff(&git()?, &refs), pair_compare::DIFF_LIMIT);
        Ok(DiffView { title: format!("{} → {}", sides[0].agent_title(), sides[1].agent_title()), lines, cut })
    })
    .await
    .map_err(|e| e.to_string())?
}

/// The three actions, each asked in the window first. The run's record is changed only when git did its part.
#[tauri::command]
pub async fn pair_action(app: AppHandle, id: String, action: String) -> Result<PairView, String> {
    let handle = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let app = handle;
        let texts = strings(&app);
        let (run, sides) = side(&app, &id)?;
        let refs: Vec<&Run> = sides.iter().collect();
        let git = git()?;
        let store = app.state::<Runs>();
        match action.as_str() {
            "keep" => {
                if !pair_compare::can_keep(&run, &refs) {
                    return Err("not now".into());
                }
                let mut other = sides.iter().find(|s| s.id != run.id).cloned().ok_or("no other side")?;
                pair_compare::discard_worktree(&git, &other)?;
                other.mark_discarded();
                store.replace(&other);
                eprintln!("pair: kept {}, removed {}", run.agent_title(), other.agent_title());
            }
            "merge" => {
                let target = pair_compare::current_branch(&git, Path::new(&run.project_path));
                if !pair_compare::can_merge(&run, &refs, target.as_deref()) {
                    return Err(texts.t("Папка проекта уже на другой ветке — откройте сравнение заново.").to_owned());
                }
                let target = target.unwrap_or_default();
                pair_compare::merge_branch(&git, &texts, &run, &target)?;
                let mut merged = run.clone();
                merged.mark_merged(&target);
                store.replace(&merged);
                eprintln!("pair: {} merged into {target}", run.agent_title());
            }
            "tidy" => {
                if !pair_compare::can_tidy(&run) {
                    return Err("not now".into());
                }
                pair_compare::remove_merged_worktree(&git, &texts, &run)?;
                let mut tidied = run.clone();
                tidied.mark_discarded();
                store.replace(&tidied);
            }
            _ => return Err("no such action".into()),
        }
        let _ = app.emit("sessions-changed", ());
        Ok(view(&app))
    })
    .await
    .map_err(|e| e.to_string())?
}

/// «Открыть папку» of a side.
#[tauri::command]
pub fn pair_open_folder(app: AppHandle, id: String) -> Result<(), String> {
    let (run, _) = side(&app, &id)?;
    crate::projects::open_with_system(run.folder.as_ref())
}
