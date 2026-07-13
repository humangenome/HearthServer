use hearth_save_guard::protect;
use std::path::PathBuf;

fn main() {
    match run() {
        Ok(()) => {}
        Err(message) => {
            eprintln!("ERROR {message}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) != Some("protect") {
        return Err("usage: HearthSaveGuard protect --save <path> --ledger <dir>".into());
    }
    let mut save = None::<PathBuf>;
    let mut ledger = None::<PathBuf>;
    let mut index = 2usize;
    while index < args.len() {
        match args[index].as_str() {
            "--save" if index + 1 < args.len() => {
                save = Some(PathBuf::from(&args[index + 1]));
                index += 2;
            }
            "--ledger" if index + 1 < args.len() => {
                ledger = Some(PathBuf::from(&args[index + 1]));
                index += 2;
            }
            _ => return Err("usage: HearthSaveGuard protect --save <path> --ledger <dir>".into()),
        }
    }
    let save = save.ok_or_else(|| "--save is required".to_string())?;
    let ledger = ledger.ok_or_else(|| "--ledger is required".to_string())?;
    let outcome = protect(&save, &ledger).map_err(|e| e.to_string())?;
    println!(
        "OK current={} ledger_updates={} restored={} world_records={} world_restored={}",
        outcome.current_records,
        outcome.ledger_updates,
        outcome.restored_records,
        outcome.world_records,
        usize::from(outcome.world_restored)
    );
    Ok(())
}
