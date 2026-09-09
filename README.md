# luahellper — Luau Obfuscator

[![Deploy to Render](https://img.shields.io/badge/Deploy-Render-46E3B7?logo=render&logoColor=white)](https://render.com/deploy?repo=https://github.com/S2-max/Duel-script-)  — one-click host to get `loadstring(game:HttpGet("https://luahellper.onrender.com/raw/ID"))()` links. See **[RAWLINKS.md](RAWLINKS.md)**.


A source-level + VM obfuscator for **Luau** (Roblox) scripts. It parses your code
to an AST and rewrites it through several independent layers (or virtualizes it
to custom bytecode), then emits valid Luau that behaves identically to the
original.

Self-contained: the output is plain Luau with **no `loadstring`/`require`
dependency**, so it runs in Roblox environments where `loadstring` is disabled.

## Usage

```sh
lua luahellper.lua input.lua output.lua            # source-transform layers
lua luahellper.lua input.lua output.lua --flatten  # + control-flow flattening
lua luahellper.lua input.lua output.lua --vm       # VM virtualization (strongest)
lua luahellper.lua input.lua                        # prints to stdout
```

Runs under any Lua 5.1+ / LuaJIT / Luau host. (Tested with `lua5.4`.)

### Flags
| flag | effect |
|------|--------|
| `--seed N`     | deterministic build (same input+seed → same output) |
| `--vm`         | **VM virtualization**: compile to custom bytecode + embedded interpreter |
| `--no-vm-protect` | with `--vm`, skip re-obfuscating the emitted loader |
| `--no-encrypt-code` | with `--vm`, keep bytecode as readable tables (default: encrypted blob) |
| `--no-anti-tamper`  | with `--vm`, drop the integrity/anti-hook key derivation |
| `--no-micro-ops`    | with `--vm`, keep composite global access as single opcodes |
| `--max`             | maximum protection: `--vm` + nested virtualization (`--nest 2`) |
| `--nest N`          | with `--vm`, virtualize the loader N times (double VM at N=2) |
| `--watermark ID`    | embed a traceable marker (e.g. a buyer's key id) in the output |
| `--key-url URL`     | ship the payload encrypted; it decrypts only with a key fetched live from URL (your key server's `/key`) |
| `--flatten`    | enable control-flow flattening (off by default) |
| `--no-rename`  | keep original local names |
| `--no-strings` | keep string literals in cleartext |
| `--no-numbers` | keep numeric literals |
| `--no-junk`    | no junk-code insertion |

`--vm` is a distinct pipeline from the source-transform layers above: your code
is turned into bytecode, so there is no recognizable Lua left to rename or
flatten — the logic lives as a table of numbers driven by an interpreter.

## Layers

1. **Identifier renaming** — every local, parameter, and loop variable is
   renamed to a confusable name (`Illl`, `oO0l`, …). Scope-aware: globals and
   API calls (`game`, `print`, `:GetService`, table fields) are never touched.
2. **String encryption** — all string literals (including the literal parts of
   `` `interp {x}` `` strings) are lifted into one runtime pool, encrypted with a
   per-build modular cipher, and decoded on load. No cleartext strings remain.
3. **Number obfuscation** — integer literals become small arithmetic
   expressions.
4. **Junk code** — unused decoy locals are sprinkled between statements.
5. **Control-flow flattening** *(`--flatten`)* — straight-line statement runs are
   replaced by a state-machine dispatcher loop with scrambled case order.

## VM virtualization (`--vm`) — the strong tier

`--vm` compiles your script to a **custom stack-based bytecode** and ships a tiny
interpreter that runs it. This is the technique Luarmor/IronBrew-class protectors
use, and it's a different order of protection: after virtualization there is no
Lua control flow, no variable names, and no function structure to recover — only
an opcode table and a dispatch loop. A deobfuscator has to reconstruct your
program from the instruction semantics, not just undo a text transform.

Implemented:
- Full compiler: expressions, all statements, `if`/`while`/`repeat`/numeric &
  generic `for`, `break`/`continue`, `and`/`or` short-circuit.
- **Closures & upvalues** — captured variables are boxed cells, so nested
  closures share and mutate the same upvalue exactly like real Lua.
- **Multi-value semantics** — varargs, multiple returns, `{f()}` expansion, and
  multiple assignment all preserve Lua's value-count rules.
- **Metatables** work (the VM uses the host's real table operations).
- **Encrypted constant pool** — every string constant is encrypted and decoded
  at load; none appear in cleartext.
- **Per-build opcode randomization** — every build gets a fresh, shuffled
  name→number opcode mapping, so the interpreter's dispatch numbers differ each
  time. A static VM-lifter written against one build is useless against the next.
- **Handler duplication** — each opcode gets several alias numbers, all running
  the same handler; the compiler emits them interchangeably. Defeats frequency
  analysis of the bytecode and fills the dispatch with decoy cases.
- **Encrypted bytecode** — the instruction stream is varint-encoded and
  position-ciphered into an opaque blob, rebuilt at load. No readable
  instruction tables remain (disable with `--no-encrypt-code`).
- **Anti-tamper + anti-hook** — the bytecode-decode key is derived at load from
  an integrity byte-sum over the blobs plus a primitive-behaviour probe. Editing
  the bytecode, or hooking `string.char`/`select`, shifts the key so the
  bytecode decodes to garbage — there is no boolean check to patch out
  (disable with `--no-anti-tamper`).
- **Micro-op splitting** — composite operations (e.g. global load/store) are
  split into primitive stack steps, so "which global" flows through the
  encrypted constant stream as a separate step instead of being baked into one
  opcode (disable with `--no-micro-ops`).
- **Constant JIT-decrypt** — string constants are stored encrypted and decrypted
  at the moment of use, so no plaintext string table sits in memory to be dumped.
- **Anti-hook** — a probe of core primitives (`string.char`, `select`,
  `string.format`, `string.sub`, `tostring`) is folded into the decrypt keys; a
  hook that alters them shifts the keys and the payload decodes to garbage.
- **Nested VM** (`--nest 2` / `--max`) — the interpreter is itself compiled to
  bytecode and run by an outer interpreter (double virtualization).
- **Server-fetched key** (`--key-url`) — the whole payload ships encrypted and
  only decrypts with a key fetched live from your key server, so a captured file
  is useless offline and you can rotate/revoke the key.
- **Watermark** (`--watermark`) — a per-build/per-buyer marker for tracing leaks.
- **Encrypted string constants** — every string constant is encrypted and
  decoded at load; none appear in cleartext.
- **Two-layer by default** — the emitted interpreter/loader is itself run back
  through renaming + junk insertion (disable with `--no-vm-protect`).

## In-browser obfuscator (`web/`)

`web/index.html` (tool) and `web/landing.html` (showcase) run a pure-JavaScript
port of the source-level engine client-side — paste Luau, obfuscate, copy or get
a loadstring, nothing uploaded. No Lua VM / eval, so they work in sandboxed
webviews. Rebuild after changing `web/obfuscator.js` or the templates with
`python3 web/build.py`. When served by the key server, the landing page's
"Get loadstring link" uploads to the paste host and returns a real
`game:HttpGet` link. Full VM virtualization stays in the CLI / server.

## Key + HWID server (`server/`, `loader/`)

For distribution control, `server/keyserver.py` is a dependency-free reference
server that hands your obfuscated script to a client only after validating a
**key bound to a HWID** (the Luarmor model), with expiry, revoke, and rebind.
`loader/loader.luau` is the short Roblox-executor stub users run; it sends
key+HWID and `loadstring`s the returned script. See **[server/README.md](server/README.md)**
for the full workflow. This gates *who receives* the script; pair it with `--vm`
so a captured script is still expensive to reverse.

## How strong is it?

Straight talk: **no client-side obfuscator is truly un-deobfuscatable.** Anything
that runs on a machine the attacker controls can eventually be reversed — the
goal is to raise the cost past what the attacker will pay. This tool destroys
readability (names, strings, constants, structure) and defeats casual/automated
lifting, which covers the large majority of real-world copying.

The strongest tier here is **bytecode VM virtualization** (`--vm`) — the same
class of technique as Luarmor/IronBrew. It is implemented and tested. It raises
the reversing cost dramatically, but it is still not magic: a determined analyst
can study the interpreter, dump the opcode table, and rebuild a decompiler for
this instruction set — though **per-build opcode randomization, handler
duplication, bytecode encryption, and anti-tamper key derivation** (all
implemented) mean they must redo that work for every single build and can't
trivially patch the integrity checks. This is combined with the **key/HWID
server** so protection also lives off the client. None of it is unbreakable —
it makes copying expensive rather than impossible, which is the real goal.

## Layout

```
luahellper.lua       CLI entry
src/lexer.lua        Luau tokenizer (strings, long-strings, interp, numbers)
src/parser.lua       tokens -> AST (Luau type annotations are stripped)
src/emitter.lua      AST -> Luau source
src/scope.lua        scope resolution (safe local vs global)
src/walk.lua         generic AST walker
src/names.lua        shared unique-name factory (no cross-pass collisions)
src/obfuscator.lua   pipeline orchestrator
src/transforms/      rename · strings · numbers · junk · flatten
src/vm/              opcodes (aliasing) · compiler (AST->bytecode) · runtime
                     (interpreter fragments) · serialize (bytecode encryption,
                     anti-tamper, self-contained emit)
server/              keyserver.py (key+HWID auth) + README
loader/              loader.luau (Roblox executor stub)
tests/               sample scripts + round-trip harnesses
```

## Tests

```sh
lua5.4 tests/run.lua       # source-transform + VM layers vs native output
lua5.4 tests/run_vm.lua    # VM semantics (closures, continue, varargs, meta)
```
Every sample is executed before and after obfuscation across many seeds/flag
combinations and asserted to produce identical output.
