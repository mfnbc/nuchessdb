# Asynchronous Coach Pipeline — Architecture

## Design principle

HUGM is not a chess engine. It's a **sensor array** that detects chess concepts in a position and hands them to an LLM for coaching. This means:

- **No speed constraints**: evaluate one position at a time, not millions per second
- **Readable Rust**: descriptive structs, explicit pattern matching, no bitboards in the output layer
- **LLM handles language**: Rust code only detects facts; the LLM generates questions, commentary, and PGN annotations

## Three layers

```
┌─────────────────────────────────────────────────┐
│ LAYER 1: SENSOR ARRAY                            │
│ "What is true about this position?"              │
│                                                  │
│ Input:  FEN string                               │
│ Output: SensorReport (typed concepts)            │
│ Code:   eval/position.rs → eval/concepts.rs      │
│                                                  │
│ Concepts detected:                               │
│   Tactical:   forks, pins, skewers, discovered   │
│   Positional: outposts, open files, passed pawns │
│   Material:   balance, bishop pair, redundancy   │
│   Structural: pawn islands, shelter, space       │
│   Threats:    hanging pieces, overload, x-ray    │
└───────────────────────┬─────────────────────────┘
                        │ SensorReport (JSON)
┌───────────────────────┴─────────────────────────┐
│ LAYER 2: CONCEPT FILTER                          │
│ "What matters for this player?"                  │
│                                                  │
│ Input:  SensorReport + player ELO                │
│ Output: RankedConceptList                        │
│ Code:   eval/concepts.rs (extract_concepts,      │
│         concepts_for_elo)                        │
│                                                  │
│ Rules:                                           │
│   Severity ranking (material > fork > outpost)   │
│   ELO gating (discovered attack hidden at 1000)  │
│   Top-N selection (most important 2-3 concepts)  │
└───────────────────────┬─────────────────────────┘
                        │ RankedConceptList (JSON)
┌───────────────────────┴─────────────────────────┐
│ LAYER 3: LLM COACH                               │
│ "How do I say this to a 1400-rated player?"      │
│                                                  │
│ Input:  RankedConceptList + player ELO + history │
│ Output: Socratic question or PGN comment         │
│ Code:   (external — nu-agent or LLM API)         │
│                                                  │
│ Task: linguistic packaging only.                 │
│ The LLM receives structured facts and generates  │
│ age-appropriate, ELO-appropriate commentary.     │
└─────────────────────────────────────────────────┘
```

## Concept types

### TacticalConcept (transient threats)
```rust
struct Fork {
    attacker: PieceRef,    // "Nd5"
    targets: Vec<PieceRef>, // ["Qf6", "Rb6"]
}

struct Pin {
    attacker: PieceRef,    // "Bb5"
    pinned: PieceRef,      // "Nc6"
    shielded: PieceRef,    // "Ke8"
    pin_type: PinType,     // Absolute | Relative
}

struct Skewer {
    attacker: PieceRef,
    front: PieceRef,       // piece in front, higher value
    behind: PieceRef,      // piece behind, lower value
}

struct DiscoveredAttack {
    mover: PieceRef,       // piece that moves
    attacker: PieceRef,    // piece that attacks after move
    target: PieceRef,
}

struct HangingPiece {
    piece: PieceRef,
    square: Square,
    attacker_count: u8,    // pieces that can capture it
}
```

### PositionalConcept (persistent features)
```rust
struct Outpost {
    piece: PieceRef,       // knight or bishop
    square: Square,
    supported_by: PieceRef, // pawn that guards it
}

struct OpenFile {
    file: File,            // 'a' through 'h'
    rook_count: u8,
    side: Color,
}

struct PassedPawn {
    square: Square,
    rank: Rank,
    is_protected: bool,
    is_unstoppable: bool,
}

struct PawnIsland {
    files: Vec<File>,
    count: u8,
    side: Color,
}

struct KingExposure {
    side: Color,
    shelter_files: u8,     // pawns protecting king
    attacker_count: u8,    // enemy pieces near king
}
```

### MaterialConcept (persistent, large magnitude)
```rust
struct MaterialBalance {
    white: PieceCounts,
    black: PieceCounts,
    centipawns: i64,
}

struct BishopPair {
    side: Color,
}

struct PieceRedundancy {
    piece: Role,           // Rook, Queen
    count: u8,             // more than 1 = redundant
    side: Color,
    penalty_cp: i64,
}
```

## Concept severity → ELO mapping

| Severity tier | Concepts | ELO threshold | Rationale |
|--------------|----------|---------------|-----------|
| Critical (100+) | Check, hanging queen, mate threat | 800 | A beginner must see these |
| High (50-99) | Fork, skewer, material imbalance > 200cp | 1000 | Basic tactics |
| Medium (25-49) | Pin, passed pawn, rook on 7th | 1200 | Intermediate tactics |
| Low (10-24) | Open file, outpost, king exposure | 1400 | Positional awareness begins |
| Subtle (5-9) | Isolated pawn, doubled pawn, development | 1600 | Pawn structure |
| Advanced (1-4) | Bishop pair, pawn majority, breaks, center | 1800 | Strategic concepts |
| Expert (0) | Minority attack, space, piece coordination | 2000 | Master-level understanding |

## LLM Coach contract

`prj/nu-agent/contracts/chess_coach.toml` — Enrich verb (JSON in, output enriched).

## Implementation status

1. ✅ Define concept types in `eval/concept_types.rs`
2. ✅ Add `SensorReport` — sensor.rs
3. ✅ Tactical detectors produce typed concepts (forks, pins, skewers, discovered)
4. ✅ Conversion functions — `board_to_piece_ref`, `forks_to_typed`, etc.
5. ✅ Concept severity + ELO gating — concepts.rs
6. ✅ Chess coach contract — nu-agent/contracts/chess_coach.toml
7. ⬜ Positional detectors → typed concepts (outposts, open files, passed pawns)
8. ⬜ Full SensorReport wired into PositionRecord output
9. ⬜ Plugin command exposes SensorReport JSON

## Original plan (archived)

1. Define concept types in `eval/concept_types.rs`

1. Define concept types in `eval/concept_types.rs` — no logic, just data
2. Add `SensorReport` — collection of all detected concepts
3. Refactor `compute_groups()` to populate `SensorReport` alongside `EvalGroups`
4. Update `concepts.rs` to use typed concepts instead of string terms
5. Add concept example extraction (piece names, squares) to detection functions
6. Expose `SensorReport` through the plugin command output
