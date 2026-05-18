use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use serde_json::Value;
use nu_plugin_chessdb::core::pgn_to_batch_record;
use nu_protocol::Span;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: lichess_to_jsonl <input_ndjson> <output_positions_jsonl> [max_games] [min_rating]");
        std::process::exit(2);
    }
    let input = &args[1];
    let output = &args[2];
    let max_games: usize = if args.len() > 3 { args[3].parse().unwrap_or(2) } else { 2 };
    let min_rating: i64 = if args.len() > 4 { args[4].parse().unwrap_or(1800) } else { 1800 };

    let infile = File::open(input)?;
    let reader = BufReader::new(infile);

    let mut games_pgn = String::new();
    let mut game_count = 0usize;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() { continue; }
        let v: Value = serde_json::from_str(&line)?;
        // extract players and ratings
        let white = v.get("players").and_then(|p| p.get("white")).and_then(|w| w.get("user")).and_then(|u| u.get("name")).and_then(|n| n.as_str()).unwrap_or("white");
        let black = v.get("players").and_then(|p| p.get("black")).and_then(|b| b.get("user")).and_then(|u| u.get("name")).and_then(|n| n.as_str()).unwrap_or("black");
        let white_rating = v.get("players").and_then(|p| p.get("white")).and_then(|w| w.get("rating")).and_then(|r| r.as_i64()).unwrap_or(0);
        let black_rating = v.get("players").and_then(|p| p.get("black")).and_then(|b| b.get("rating")).and_then(|r| r.as_i64()).unwrap_or(0);
        if white_rating < min_rating || black_rating < min_rating { continue; }

        let id = v.get("id").and_then(|x| x.as_str()).unwrap_or("game");
        let _created_at = v.get("createdAt").and_then(|t| t.as_i64()).unwrap_or(0);
        // For simplicity, leave date unknown (we don't need accurate date for PGN parsing here)
        let date = "0000.00.00".to_string();

        let moves = v.get("moves").and_then(|m| m.as_str()).unwrap_or("");
        let winner = v.get("winner").and_then(|w| w.as_str()).unwrap_or("");
        let result = match winner {
            "white" => "1-0",
            "black" => "0-1",
            _ => "1/2-1/2",
        };

        // Build PGN header + moves with numbering
        let mut pgn = String::new();
        pgn.push_str(&format!("[Event \"lichess.org\"]\n"));
        pgn.push_str(&format!("[Site \"lichess.org\"]\n"));
        pgn.push_str(&format!("[Date \"{}\"]\n", date));
        pgn.push_str(&format!("[White \"{}\"]\n", white));
        pgn.push_str(&format!("[Black \"{}\"]\n", black));
        pgn.push_str(&format!("[Result \"{}\"]\n", result));
        pgn.push_str(&format!("[WhiteElo \"{}\"]\n", white_rating));
        pgn.push_str(&format!("[BlackElo \"{}\"]\n", black_rating));
        pgn.push_str(&format!("[Annotator \"{}\"]\n", id));
        pgn.push_str("\n");

        // Turn moves into numbered SAN list
        let tokens: Vec<&str> = moves.split_whitespace().collect();
        let mut mv_text = String::new();
        let mut i = 0usize;
        while i < tokens.len() {
            let move_no = (i/2) + 1;
            mv_text.push_str(&format!("{}. {}", move_no, tokens[i]));
            if i+1 < tokens.len() {
                mv_text.push_str(&format!(" {} ", tokens[i+1]));
            } else {
                mv_text.push_str(" ");
            }
            i += 2;
        }
        mv_text.push_str(result);
        pgn.push_str(&mv_text);
        pgn.push_str("\n\n");

        games_pgn.push_str(&pgn);
        game_count += 1;
        if game_count >= max_games { break; }
    }

    eprintln!("Collected {} games -> parsing PGN...", game_count);
    let span = Span::unknown();
    let batch = pgn_to_batch_record(&games_pgn, span)?;

    eprintln!("Parsed {} positions (unique)", batch.unique_positions.len());

    let mut out = File::create(output)?;
    for pos in batch.positions {
        let rec = serde_json::json!({"fen": pos.fen, "game_index": pos.game_index, "ply": pos.ply});
        writeln!(out, "{}", rec.to_string())?;
    }

    Ok(())
}
