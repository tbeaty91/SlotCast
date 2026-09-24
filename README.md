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
| `/slotcast status` | version, source bar, managed frame count, current bindings |
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
