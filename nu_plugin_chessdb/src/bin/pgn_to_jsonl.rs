use std::env;
use std::io::{self, BufRead};
use std::fs::File;
use std::io::Read;
use serde_json::json;

use nu_plugin_chessdb::core::pgn_to_batch_record;
use nu_protocol::Span;

fn headers_lookup(headers: &Vec<(String,String)>, key: &str) -> Option<String> {
    for (k,v) in headers.iter() {
        if k.eq_ignore_ascii_case(key) { return Some(v.clone()); }
    }
    None
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    let max_games: usize = if args.len() > 1 { args[1].parse().unwrap_or(100) } else { 100 };

    // Read stdin and process each PGN game as soon as we encounter a blank-line separator.
    let stdin = io::stdin();
    let mut current = String::new();
    let mut processed_games = 0usize;
    let span = Span::unknown();

    for line_res in stdin.lock().lines() {
        let line = line_res?;
        if line.trim().is_empty() {
            if !current.trim().is_empty() {
                // We have one game block in `current`. Inspect Result header quickly.
                let mut has_valid_result = false;
                for ln in current.lines() {
                    let ln = ln.trim();
                    if ln.starts_with("[Result ") {
                        if let Some(start) = ln.find('"') {
                            if let Some(end) = ln[start+1..].find('"') {
                                let val = &ln[start+1..start+1+end];
                                if val != "*" && !val.trim().is_empty() {
                                    has_valid_result = true;
                                }
                            }
                        }
                        break;
                    }
                }

                if has_valid_result {
                    match pgn_to_batch_record(&current, span) {
                        Ok(batch) => {
                            for pos in batch.positions {
                                let game_idx = pos.game_index as usize;
                                let game = if game_idx < batch.games.len() { Some(&batch.games[game_idx]) } else { None };
                                let headers = game.map(|g| g.headers.clone()).unwrap_or_default();
                                // Prefer Site tail when available
                                let site = headers_lookup(&headers, "Site").unwrap_or_default();
                                let mut source_game_id = String::new();
                                if site.starts_with("https://lichess.org/") {
                                    if let Some(idx) = site.rfind('/') { source_game_id = site[idx+1..].to_string(); }
                                }
                                if source_game_id.is_empty() {
                                    source_game_id = game.map(|g| g.source_game_id.clone()).unwrap_or_else(|| "".to_string());
                                }
                                let result_hdr = headers_lookup(&headers, "Result").unwrap_or_else(|| game.map(|g| g.result.clone()).unwrap_or_else(|| "*".to_string()));
                                if result_hdr == "*" || result_hdr.trim().is_empty() { continue; }
                                let white_elo = headers_lookup(&headers, "WhiteElo").and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
                                let black_elo = headers_lookup(&headers, "BlackElo").and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
                                let out = json!({
                                    "fen": pos.fen,
                                    "zobrist": pos.zobrist,
                                    "source_game_id": source_game_id,
                                    "ply": pos.ply,
                                    "white_elo": white_elo,
                                    "black_elo": black_elo,
                                    "result": result_hdr
                                });
                                println!("{}", out.to_string());
                            }
                        }
                        Err(e) => eprintln!("pgn_to_batch_record error: {}", e),
                    }
                }

                processed_games += 1;
                if processed_games >= max_games { break; }

                current.clear();
            }
        } else {
            current.push_str(&line);
            current.push('\n');
        }
    }

    // In case file didn't end with a blank line, process last block
    if !current.trim().is_empty() && processed_games < max_games {
        let mut has_valid_result = false;
        for ln in current.lines() {
            let ln = ln.trim();
            if ln.starts_with("[Result ") {
                if let Some(start) = ln.find('"') {
                    if let Some(end) = ln[start+1..].find('"') {
                        let val = &ln[start+1..start+1+end];
                        if val != "*" && !val.trim().is_empty() {
                            has_valid_result = true;
                        }
                    }
                }
                break;
            }
        }
        if has_valid_result {
            match pgn_to_batch_record(&current, span) {
                Ok(batch) => {
                    for pos in batch.positions {
                        let game_idx = pos.game_index as usize;
                        let game = if game_idx < batch.games.len() { Some(&batch.games[game_idx]) } else { None };
                        let headers = game.map(|g| g.headers.clone()).unwrap_or_default();
                        let site = headers_lookup(&headers, "Site").unwrap_or_default();
                        let mut source_game_id = String::new();
                        if site.starts_with("https://lichess.org/") {
                            if let Some(idx) = site.rfind('/') { source_game_id = site[idx+1..].to_string(); }
                        }
                        if source_game_id.is_empty() {
                            source_game_id = game.map(|g| g.source_game_id.clone()).unwrap_or_else(|| "".to_string());
                        }
                        let result_hdr = headers_lookup(&headers, "Result").unwrap_or_else(|| game.map(|g| g.result.clone()).unwrap_or_else(|| "*".to_string()));
                        if result_hdr == "*" || result_hdr.trim().is_empty() { continue; }
                        let white_elo = headers_lookup(&headers, "WhiteElo").and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
                        let black_elo = headers_lookup(&headers, "BlackElo").and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
                        let out = json!({
                            "fen": pos.fen,
                            "zobrist": pos.zobrist,
                            "source_game_id": source_game_id,
                            "ply": pos.ply,
                            "white_elo": white_elo,
                            "black_elo": black_elo,
                            "result": result_hdr
                        });
                        println!("{}", out.to_string());
                    }
                }
                Err(e) => eprintln!("pgn_to_batch_record error: {}", e),
            }
        }
    }

    Ok(())
}
