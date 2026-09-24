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

Left-click-to-target and right-click-for-menu are bindings too, in the *Unit
frame clicks* column, and they're set that way by default. Anything left
unbound keeps whatever behaviour the unit frame already had — SlotCast restores
the original attribute rather than leaving a hole.

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
Retail also uses subtext for things that aren't ranks at all ("Fire", "Holy"), so
a subtext only counts as a rank if it contains a number; anything else falls back
to the rankless cast, which is the safe direction to be wrong in.

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
can't be determined from outside the game: build and project constants, which
action bars exist and which slots they drive, the full spell API surface and what
it says about the spells on your bar, whether `ClickCastFrames` exists and what's
in it, a real unit frame's secure attributes, and Blizzard's click-binding
profile if there is one.

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
| `/slotcast` | open options |
| `/slotcast probe` | full client capability report in a copyable window |
| `/slotcast status` | version, source bar, managed frame count, bindings and their cast strings |
| `/slotcast rank slot\|highest` | default rank handling for all slots |
| `/slotcast castmode spell\|macro` | how casts are emitted; switch if ranked casts don't fire |
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
