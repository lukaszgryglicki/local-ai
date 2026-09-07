# Task: text-mode chess program

Create the directory `/data/ai/chess` and implement a complete text-mode chess
game there.

## Language

C, Go, or Rust - pick ONE, whichever lets you deliver the strongest, most
correct program. Prefer a single self-contained source file, standard library
only (no external dependencies).

## Gameplay

- The human plays White and moves first; the computer plays Black.
- Pure text exchange: the user types a move on stdin, the program replies with
  its move on stdout, and so on until the game ends.
- Move input/output format: coordinate notation - `e2e4`, castling as the king
  move (`e1g1`), promotion with a suffix (`e7e8q`, `e7e8n`, ...). Accept
  uppercase input too.
- Reject illegal or unparsable input with a short message and re-prompt; never
  crash and never lose game state.
- Implement the full rules of chess: castling (all legality conditions),
  en passant, promotion (q/r/b/n), check, checkmate, stalemate, the 50-move
  rule, threefold repetition, and insufficient material. Announce check when it
  happens, and on game end print the standard result (`1-0`, `0-1` or
  `1/2-1/2`) plus a one-word reason (checkmate/stalemate/repetition/...), then
  exit.

## Strength

- The computer must play as strongly as you can make it. No difficulty levels,
  no configuration - always maximum strength.
- Recommended: iterative-deepening alpha-beta with quiescence search, move
  ordering and a transposition table. Use the whole available think time.

## Command line

- Exactly one optional argument: the computer's maximum think time per move,
  in seconds. `0` means unlimited (search to a sensible fixed maximum depth),
  e.g. `300` means up to 300 seconds. Default when omitted: 60.
- The limit must be enforced for real (wall clock), not just approximated.

## Board display

- The extra stdin command `d` (instead of a move) draws the current board.
- Output EXACTLY 8 lines of EXACTLY 8 characters: rank 8 first (top), rank 1
  last; file a is the leftmost column. No borders, labels, coordinates or
  extra whitespace.
- Standard FEN piece letters: UPPERCASE = White (`KQRBNP`), lowercase = black
  (`kqrbnp`), space = empty square.

## Quality bar

- Must build cleanly and run on this Linux machine. Build it yourself and
  validate before declaring done: play several scripted scenarios covering
  castling, en passant, promotion, checkmate, stalemate, illegal-move
  rejection, the `d` output format, and the think-time cap.
- Add a short `README.md` in the same directory: build command, usage, the
  option, and the `d` command.
