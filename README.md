# SlotCast

Click-cast for World of Warcraft (retail), driven by an action bar.

Clique binds a *spell* to a click. SlotCast binds an *action bar slot* to a click.
Set `Shift + Left` to slot 1 of bar 8, drag Renew into that slot, and Shift+Left
on any unit frame casts Renew. Drag Flash Heal over it later and the binding
follows — no options menu, no reconfiguring. The action bar is the config.

## Install

Copy the `SlotCast` folder into:

```
World of Warcraft/_retail_/Interface/AddOns/SlotCast
```

**Check the interface version first.** In game, run:

```
/run print((select(4, GetBuildInfo())))
```

and make sure that number appears in the `## Interface:` line of `SlotCast.toc`.
If it doesn't, either add it or tick *Load out of date AddOns* on the character
select AddOns screen.

## Setup

1. Open Edit Mode and enable an action bar you don't use for keybinds — **bar 6,
   7 or 8**. Those three never change pages.
2. Drag the spells you want to click-cast onto it.
3. Fade it out or shrink it in Edit Mode so it isn't in the way. (Hiding a bar
   outright makes it undraggable, so leave it visible but faint while you're
   still arranging it.)
4. `/slotcast` → pick the bar, then for each slot click the **capture button**
   with the mouse button you want, holding whatever modifiers you want. Clicking
   it with Shift+Right held binds Shift+Right.

Left-click-to-target and right-click-for-menu are available as bindings too, in
the *Unit frame clicks* column, but **nothing there is bound by default**.
Anything left unbound keeps whatever behaviour the unit frame already had —
SlotCast restores the original attribute rather than leaving a hole.

That default matters if you also use Blizzard's Click Bindings. SlotCast writes
*specific* secure attributes (`type1`, `shift-type1`), while Blizzard writes
*wildcard* ones (`*type1`), and a specific attribute wins the lookup. So on any
click SlotCast binds, SlotCast takes precedence — nothing double-fires, but the
Blizzard binding on that exact click stops working. Leaving plain left and right
unbound is what keeps both systems usable side by side.

## What it binds to

Any frame registered in the shared `ClickCastFrames` table — the convention
Clique established. That covers Blizzard's raid and party frames plus Grid2,
Cell, ElvUI, VuhDo and most others, with no per-addon support code. Blizzard's
non-compact frames (player, target, focus, boss, party) are picked up by name.

Run `/slotcast status` to see how many frames are live.

**Don't run Clique at the same time.** Both addons write the same secure
attributes on the same frames and the loser is whoever ran last. SlotCast warns
on login if it finds another owner of `ClickCastFrames`.

## Things that will look like bugs and aren't

**Changes stall in combat.** `SetAttribute` on a secure frame is forbidden while
you're in combat — a hard client restriction, not something an addon can work
around. Drag a new spell onto the bar mid-pull and the binding updates the
instant combat drops. SlotCast tells you when it's holding an update; turn that
off in the code via `announceDefer` if it's noisy.

**Macros don't follow your click.** The secure handler passes a unit to spells
and items, but a macro just runs as typed. A macro in a slot will act on your
current target unless it carries its own `[@mouseover]`. Slots holding such a
macro are marked with a `*` in the options panel and the tooltip says so.

**Flyouts can't be bound.** They need a popup. Put the individual spell in the
slot instead.

**Bar 1 moves under you.** It pages on stance, stealth, dragonriding and
vehicles. SlotCast follows the visible page so the binding matches what you see,
but that means the binding changes when the page does. Use bars 6–8.

## Mapping the bar's shape onto clicks

Edit Mode can lay a bar out as a grid — 3 columns by 4 rows, say. That shape can
be the binding scheme: columns are Left / Middle / Right, rows are no modifier /
Shift / Ctrl / Alt. Twelve clicks, and the bar on screen is the reference card.

**Map grid to clicks** in the options panel does exactly that in one press. It's
a convenience, not the interface: every binding can be set by hand, one click at
a time, in any combination you like. Nothing requires a grid, or a bar shape, or
this scheme.

It does not assume a fold order. The order slots fill a given Edit Mode shape
differs between clients, so SlotCast reads where the buttons actually sit on
screen and clusters them into rows and columns. It works on any shape — 3x4,
4x3, 2x6, a plain row of twelve. Reshape the bar and press it again.

Two toggles sit under the button, because neither choice is universal:

| | |
|---|---|
| **Columns / Rows = buttons** | which axis carries the mouse button. A 3-wide bar usually wants columns, a 3-tall one rows. Disabled on a single-row bar, which has no axis to choose. |
| **L M R / L R M** | the order buttons are handed out along that axis. Put middle last if it's awkward on your mouse. |

Modifier rows always run in the canonical order — none, Shift, Ctrl, Alt, then
the pairs — matching every keybinding UI in the game.

It replaces slot bindings only; target, menu and the other unit-frame actions are
a separate decision and are left alone.

## Press or release

`RegisterForClicks` is per *frame*, not per binding, so the whole frame commits
to one stroke. Casting on press is worth real milliseconds in competitive play —
it's why the client has a cvar for it — so SlotCast defaults to press wherever it
can.

The built-in `target`, `focus`, `assist` and `menu` action types don't run on the
press stroke. But three of those four have macro equivalents that do (a macro is
just script execution and runs whenever the click handler runs), so SlotCast
emits them as `/target [@mouseover]` and friends when firing on press. Only the
**unit menu** has no press-stroke form.

So the default, `auto`, fires on press — unless you've bound the unit menu, in
which case that frame moves to release. Nothing else forces the switch.

```
/slotcast clicks auto | up | down | both
```

| | |
|---|---|
| `auto` | press, unless the unit menu is bound. Default. |
| `down` | always press. Fastest; the unit menu won't work. |
| `up` | always release. Everything works, casts land a touch later. |
| `both` | registers both strokes. Untested — spells may fire twice. There to be measured, not recommended. |

`/slotcast status` shows the mode and which stroke is actually in effect. A
binding stranded by the current mode is called out in the options panel.

## Spell ranks

On a client with Classic-style spell ranks, every action slot holds one specific
rank — each rank is its own spell ID and its own spellbook entry, so there is no
"rankless" thing to drag. SlotCast therefore has to choose which string to cast,
and that choice is **per slot**:

| Mode | Casts | For |
|---|---|---|
| `in slot` (default) | `Renew(Rank 2)` | downranking — the rank you put there, exactly |
| `highest` | `Renew` | the best rank you know, auto-upgrading as you level |

Each slot row gets a small toggle showing `R2` or `max`; the buttons next to
**Ranks:** at the top of the column set the default for all of them.
`/slotcast rank slot` and `/slotcast rank highest` do the same from chat.

Per-slot is the point. A Classic healer wants Flash Heal at max *and* Greater
Heal at Rank 3 bound at the same time, on different clicks — and re-dragging a
different rank into a slot retunes it without touching the binding at all.

The rank string comes from the client (`C_Spell.GetSpellSubtext`, falling back
to `GetSpellSubtext` and Classic's two-return `GetSpellInfo`), never rebuilt by
hand — the word "Rank" is localised, and the cast parser wants the local one.

### Telling a rank from flavour text

Retail uses subtext for all sorts of things that aren't ranks — "Pit of Saron",
"Skyriding", "Battle Pets" — and on 12.1 *Battle for Azeroth Pathfinder* has the
subtext "Rank 2". So a subtext has to be verified before it can be cast.

The test that looks obvious does not work: asking whether `Name(Subtext)`
resolves to a spell. `C_Spell.GetSpellInfo` **strips the parenthetical and
resolves the base name**, so on retail every one of those flavour subtexts came
back valid. Measured, not assumed.

What a parenthetical cannot fake is changing *which* spell is named. SlotCast
resolves both forms and compares spell ids:

| | `Renew` | `Renew(Rank 2)` | |
|---|---|---|---|
| ranked client | highest rank's id | rank 2's id | different → real rank |
| rankless client | id X | id X | same → flavour text, cast rankless |

The one case this calls "not a rank" on a genuinely ranked client is a slot
holding the highest rank, where both forms name the same spell — and casting
rankless there is identical in effect, so the false negative costs nothing.

### If ranked casts don't fire

The default emits `type="spell"` with `Renew(Rank 2)`, which the secure handler
passes to `CastSpellByName` along with the frame's unit. That is the long-standing
Classic form, but it is worth confirming on a new engine. If a ranked binding does
nothing while an unranked one works:

```
/slotcast castmode macro
```

That switches to `type="macro"` with `/cast [@mouseover,exists][] Renew(Rank 2)`,
which is the syntax you'd type by hand. `/slotcast status` prints the exact cast
string for every binding, so you can see what's being sent.

## Reporting a problem on an unfamiliar client

```
/slotcast probe
```

opens a copyable window (Ctrl+A, Ctrl+C) with everything about the client that
can't be determined from outside the game. `/slotcast check` uses the same window
for a shorter, binding-focused report; both accept a `chat` argument to print to
chat instead, and both are stashed in saved variables (`lastProbe`, `lastCheck`)
so they survive a `/reload`: build and project constants, which
action bars exist and which slots they drive, the full spell API surface and what
it says about the spells on your bar, whether `ClickCastFrames` exists and what's
in it, a real unit frame's secure attributes, and Blizzard's click-binding
profile if there is one.

If a slash command appears to do nothing at all, `/slotcast status` is the place
to start: it reports the addon version, which modules loaded, and any events this
client does not have.

Two traps worth knowing, both of which produce exactly this "nothing happens"
symptom:

- **`RegisterEvent` raises on an unknown event name**, and event names differ
  between clients — `LEARNED_SPELL_IN_TAB` became `LEARNED_SPELL_IN_SKILL_LINE`
  in 11.0. One bad name in a registration loop aborts the rest of the file.
  SlotCast registers events one at a time under `pcall`, so an absent event costs
  that event and nothing else.
- **Retail hides Lua errors** unless `/console scriptErrors 1` is set, so a file
  that died partway looks identical to a file that loaded fine.

Slash commands are registered at the top of `Core.lua`, before anything that can
fail, for the same reason: a diagnostic that only works when everything else
already works is useless.

It reports absences as loudly as presences — `C_ClickBindings = nil` is a useful
answer. Nothing identifying is collected: no character name, realm or guild.

Two things make the report much more useful:

- **Put spells on the source bar first**, including a deliberately downranked
  one. Section 3b dumps every API's view of them.
- **If the client has Blizzard click bindings, set one** before running it.
  Section 5 can only show the real field names if a binding exists.

The report is also written to saved variables as `lastProbe`, so after a
`/reload` you can pull it from
`WTF/Account/<account>/SavedVariables/SlotCast.lua` if the window's copy comes
out truncated.

## Other clients

SlotCast does not hard-code which bars exist or which action slots they own. It
asks each bar's first button which slot it is driving (`ActionButton1`,
`MultiBar5Button1`, ...) and derives the range from that, so a client with a
different slot layout, or fewer bars, maps correctly without a code change. Bars
the client doesn't have are greyed out in the options panel, and the default
source bar falls back to the highest one that exists.

Everything version-specific is feature-detected rather than assumed:

| Depends on | If absent |
|---|---|
| `C_ClickBindings` (retail 10.0+) | conflict panel says there's nothing to conflict with |
| `Settings.RegisterCanvasLayoutCategory` (10.0+) | falls back to `InterfaceOptions_AddCategory` |
| `C_Spell.GetSpellInfo` (11.0+) | falls back to `GetSpellInfo` |
| `CompactUnitFrame_SetUpFrame` | named-frame sweep still runs |
| `UIPanelButtonTemplate` | hand-built button |

The TOC deliberately carries no `AllowLoadGameType` line, which would otherwise
stop the addon loading on any client that reports a different game type.

What it genuinely requires is the secure-action engine: `SecureActionButtonTemplate`,
`SetAttribute`, the `alt-ctrl-shift-` modifier prefix convention, and the
`ClickCastFrames` registry. That set has been stable for roughly fifteen years and
is the same foundation Clique runs on — **if Clique works on a client, SlotCast's
core will too.** The fragile parts are isolated in `Conflicts.lua` and `Options.lua`,
and both degrade rather than error.

No addon works forever; Blizzard breaks the addon API on a schedule (11.0 deleted
the entire dropdown widget system, which is why this one draws its own). But
nothing here is built on a surface that moves often.

## Blizzard's built-in Click Bindings

Retail has its own click-casting (Spellbook → Click Bindings). It runs through a
separate secure path, so a click bound in both places fires **both** actions.

SlotCast reads that profile and shows overlaps in the options panel, warns once
on login, and offers a *Clear Blizzard's* button. `/slotcast conflicts` prints
the full list.

> The field names in Blizzard's `ClickBindingInfo` struct are the one thing in
> this addon that can't be verified outside the game. `Conflicts.lua` reads them
> defensively and falls back to printing raw values. If the panel says it can't
> read them, run **`/slotcast dump`** and the raw structure goes to chat.

## Commands

| Command | |
|---|---|
| `/slotcast` | open (or close) the options window |
| `/slotcast probe` | full client capability report in a copyable window |
| `/slotcast probe chat` | same report printed to chat instead |
| `/slotcast status` | version, source bar, managed frame count, bindings and their cast strings |
| `/slotcast rank slot\|highest` | default rank handling for all slots |
| `/slotcast castmode spell\|macro` | how casts are emitted; switch if ranked casts don't fire |
| `/slotcast clicks auto\|up\|down\|both` | which mouse stroke bindings fire on |
| `/slotcast check` | read bindings back off a live frame; proves whether they landed |
| `/slotcast check chat` | same, printed to chat instead of the copy window |
| `/slotcast check PlayerFrame` | check one frame by name rather than whichever is sampled |
| `/slotcast conflicts` | list Blizzard's click bindings and any overlap |
| `/slotcast dump` | raw `C_ClickBindings.GetProfileInfo()` output |
| `/slotcast toggle` | enable/disable without unloading |

`/sc` works as a short form.

## Layout

| File | |
|---|---|
| `Core.lua` | saved variables, events, refresh scheduling, slash commands |
| `Slots.lua` | bar → slot mapping, reading a slot, building the attribute plan |
| `Secure.lua` | frame discovery, attribute writes, original restore, combat queue |
| `Conflicts.lua` | Blizzard click-binding detection |
| `Options.lua` | settings panel |

The central idea is the **plan** in `Slots.lua`: a flat list of
`{attribute, value}` pairs describing the entire binding set. It's built once per
refresh and handed unchanged to every frame, which is what makes restoring
originals exact — `Secure.lua` remembers the prior value of every attribute it
writes and puts it back when a binding goes away.
