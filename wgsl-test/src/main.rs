use naga::front::wgsl;
use naga::valid::{Capabilities, ValidationFlags, Validator};

fn validate(path: &str) -> Result<(), String> {
    let source = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read '{path}': {e}"))?;

    let module = wgsl::parse_str(&source)
        .map_err(|e| format!("parse error in '{path}':\n{e}"))?;

    let mut validator = Validator::new(ValidationFlags::all(), Capabilities::all());
    validator
        .validate(&module)
        .map_err(|e| format!("validation error in '{path}':\n{e}"))?;

    Ok(())
}

fn collect_wgsl(dir: &std::path::Path, out: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_wgsl(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("wgsl") {
            out.push(path.to_string_lossy().into_owned());
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let discovered: Vec<String>;
    let files: Vec<&str> = if args.is_empty() {
        discovered = {
            let mut v = Vec::new();
            collect_wgsl(std::path::Path::new(".."), &mut v);
            v.sort();
            v
        };
        discovered.iter().map(String::as_str).collect()
    } else {
        args.iter().map(String::as_str).collect()
    };

    let mut failed = false;
    for path in &files {
        match validate(path) {
            Ok(()) => println!("PASS  {path}"),
            Err(e) => {
                eprintln!("FAIL  {e}");
                failed = true;
            }
        }
    }

    if failed {
        std::process::exit(1);
    }
}
