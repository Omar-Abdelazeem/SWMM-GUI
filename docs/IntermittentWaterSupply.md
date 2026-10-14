# Intermittent Water Supply Modeling

This document explains the "intermittent water supply" feature added to the SWMM
GUI: what problem it solves, the hydraulic network it builds behind the scenes,
how that network is represented in the `.inp` file and in the GUI's data model,
and the design decisions behind how it was implemented. It is written so that
someone unfamiliar with this feature (but familiar with SWMM in general) can
read it top to bottom and understand how everything fits together.

It is based on two design documents (`Guide_Intermittent_Nodes.pdf` and
`ControlRulesStructure.pdf`) plus the actual implementation in
`Epaswmm5/Uproject.pas`, `Uexport.pas`, `Uimport.pas`, `Fproped.pas`,
`objprops.txt`, `Umap.pas`, `Fmain.pas`, and `UIntermitDisplay.pas`.

---

## 1. The problem

Standard SWMM assumes every junction always has access to as much water as the
network delivers to it. Many real water-distribution/sewer systems, especially
in developing regions, don't work that way: water only arrives intermittently
(a few hours a day, on a schedule, or whenever upstream pressure allows), and
customers store what they can locally (rooftop or ground tanks) and draw from
that storage the rest of the time. There is also unavoidable leakage from the
service connection itself.

SWMM has no native "intermittent demand node" object. Modeling this behavior
requires wiring together a small sub-network of ordinary SWMM objects (a
storage tank, pressure-dependent outlets, and outfalls) around every junction
that needs this behavior. This feature lets a user flip one switch on a
junction and fill in a handful of fields, and the GUI builds and maintains
that sub-network automatically.

---

## 2. The conceptual network

For every junction configured as an intermittent demand node, the GUI
generates the following chain of SWMM objects (reproduced from
`Guide_Intermittent_Nodes.pdf`):

```
                 Leakage Outlet
            ┌───────────────────────┐
            │                       ▼
            │                 Leakage Outfall
            │
 [Junction] ─┴─▶ [Withdrawal Outlet] ─▶ [Storage Tank] ─▶ [Consumption Outlet] ─▶ [Demand Outfall]
```

- **Original Junction** – the real node the user placed on the map and is
  configuring. All intermittent-supply properties are entered here; none of
  the generated objects are edited directly.
- **Withdrawal Outlet** – a pressure-dependent outlet from the junction to the
  storage tank. It models how much water can be pulled from the (intermittent)
  main into the customer's private tank, based on the pressure at the junction.
- **Storage Tank** – the customer's private storage tank.
- **Consumption Outlet** – drains the tank at the customer's actual demand
  rate (and pattern), discharging to a dedicated "demand" outfall. Modeling
  consumption as an outflow to an outfall (rather than as a withdrawal/demand
  directly on the tank) lets SWMM's normal continuity accounting show exactly
  how much was consumed over time.
- **Demand Outfall** – terminates the consumption outlet; represents water
  actually used by the customer.
- **Leakage Outlet** – a second, independent pressure-dependent outlet running
  directly from the junction (not the tank) to its own outfall, modeling
  losses from the service connection itself.
- **Leakage Outfall** – terminates the leakage outlet.

All of this is generated and kept in sync automatically; the user only ever
edits properties on the original junction.

---

## 3. Junction properties

These fields live on the junction's property sheet, grouped under headings
("Pressure Dependent Withdrawal", "Storage Tank", "Consumption", "Leakage",
"Float Valve") the same way the Outlet dialog groups its fields.

| Group | Field | Units | Used by | Meaning |
|---|---|---|---|---|
| — | Intermittent Demand Node | — | toggle | YES/NO — turns the whole feature on/off for this junction. |
| Pressure Dependent Withdrawal | Min Pressure `Hmin` | m | Withdrawal Outlet | Pressure below which no withdrawal occurs (e.g., elevation difference between the main and the tank's feed point). |
| | Exponent `n` | — | Withdrawal Outlet | Exponent of `Withdrawal = C·H^n`. |
| | Desired Pressure `Hdes` | m | Withdrawal Outlet | Pressure at which withdrawal equals the desired rate. |
| | Desired Rate `Qdes` | flow | Withdrawal Outlet | The target withdrawal rate used to size the outlet's coefficient. |
| Storage Tank | Tank Height | m | Storage Tank | Tank's maximum depth (0 disables the tank/network). |
| | Tank Area | m² | Storage Tank | Tank's (constant) surface area. |
| | Initial Depth | m | Storage Tank | Starting water depth in the tank. |
| Consumption | Base Consumption Rate | flow | Consumption Outlet rating curve | The customer's steady demand rate. |
| | Consumption Pattern | — | Consumption Outlet setting | Name of a Time Series that scales consumption over time. |
| Leakage | Leakage Coefficient `A` | varies | Leakage Outlet | Coefficient in `Leakage = A·Q^B`. |
| | Leakage Exponent `B` | — | Leakage Outlet | Exponent in `Leakage = A·Q^B`. |
| Float Valve | Tank Float Valve Height | m | Float-valve control curve | Depth in the tank above which withdrawal is throttled, mimicking a float valve. Default `0.9` (see §5). |

The "Elevation" field used by the storage tank and both outfalls is not a new
field — it's copied from the junction's existing Invert elevation.

---

## 4. How each generated object is built

### Storage Tank
| Property | Value |
|---|---|
| Elevation | junction's invert |
| MaxDepth | Tank Height |
| InitDepth | Initial Depth |
| Shape | `FUNCTIONAL` |
| Coefficients `a1`, `a2` | `0`, `0` |
| Constant `a0` | Tank Area (a functional curve with `a1=a2=0` gives a constant surface area equal to `a0`) |
| Surcharge Depth | `0` |

### Withdrawal Outlet (Junction → Storage Tank)
| Property | Value |
|---|---|
| Type | `FUNCTIONAL/DEPTH` |
| Coefficient `Cw` | `Qdes / sqrt(Hdes - Hmin)` (0 if `Hdes <= Hmin`) |
| Exponent `n` | user input |
| Gated | `YES` |

The coefficient is derived so that the outlet's `Q = Cw·H^n` curve passes
through the desired rate at the desired pressure.

### Consumption Outlet (Storage Tank → Demand Outfall)
| Property | Value |
|---|---|
| Type | `TABULAR/DEPTH` |
| Curve | a 2-point rating curve: `(0, 0)` and `(0.01, Qdes_consumption)` i.e. the Base Consumption Rate |

A near-vertical rating curve like this makes the outlet discharge the
(roughly) constant Base Consumption Rate as soon as there's any depth in the
tank. The outlet's `SETTING` is then driven by the junction's **Consumption
Pattern** time series through a control rule (see below), which scales that
base rate up/down over time.

### Leakage Outlet (Junction → Leakage Outfall)
| Property | Value |
|---|---|
| Type | `FUNCTIONAL/DEPTH` |
| Coefficient | Leakage Coefficient `A` |
| Exponent | Leakage Exponent `B` |
| Gated | `YES` |

### Both Outfalls (Demand and Leakage)
| Property | Value |
|---|---|
| Elevation | junction's invert |
| Type | `FREE` |
| Gated | `NO` |

---

## 5. Float-valve throttling (`ControlRulesStructure.pdf`)

Real tanks have a float valve: once the tank is nearly full, inflow throttles
down to a trickle rather than stopping abruptly. This is reproduced with a
control rule plus a purpose-built control curve, both regenerated every time
the project is exported:

```
RULE Control<JuncID>
IF NODE <StorageTankID> DEPTH >= <FloatValveHeight>
THEN OUTLET <WithdrawalOutletID> SETTING = CURVE <ControlCurveID>
```

The curve `Control<JuncID>Curve` (type `CONTROL`) ramps the outlet's setting
from effectively "fully open" down to `0` as tank depth rises from the float
valve height to the tank's max height:

```
y = tanh( 5 · (Htank − x) / (Htank − Hfloat) )²
```

sampled at 25 equal steps between `Hfloat` and `Htank`. If the tank's height
is not greater than the float valve height, no curve/rule is generated for
that junction (there's no room to throttle).

**Design note:** the original implementation hardcoded the float valve height
as a single constant (`0.9`) shared by every intermittent junction, regardless
of its tank height or the project's unit system. This was changed to a real
per-junction property (**Tank Float Valve Height**, default `0.9`) so projects
using feet, or tanks shorter than 0.9, aren't silently left without any
throttling behavior.

---

## 6. Consumption pattern switching

If a junction has a **Consumption Pattern** set, a second rule combines all
such junctions into one block:

```
RULE Patterns
IF SIMULATION TIME > 0
THEN OUTLET <ConsumptionOutlet_1> SETTING = TIMESERIES <Pattern_1>
AND OUTLET <ConsumptionOutlet_2> SETTING = TIMESERIES <Pattern_2>
...
```

This scales each consumption outlet's rating-curve output by its own pattern
over the course of the simulation.

---

## 7. Naming convention

All generated object IDs are derived from the parent junction's ID and
truncated to fit SWMM's 16-character ID limit when necessary. These names are
built in exactly one place in the code, `UIntermitDisplay.BuildIntermitIDs` /
`BuildIntermitCurveIDs`, so every part of the system (object creation, the
control rules, and the curves) refers to the same names:

| Object | Prefix |
|---|---|
| Storage tank | `_IS_ST_` |
| Demand outfall | `_Outfall_` |
| Leakage outfall | `_L_Outfall_` |
| Withdrawal outlet | `W_OUTLET_` |
| Leakage outlet | `_L_OUTLET_` |
| Consumption outlet | `_C_OUTLET_` |
| Consumption rating curve | `_DEMAND_` |
| Float-valve control curve | `Control…Curve` |

These prefixes are also how the GUI recognizes a generated object after the
fact (`IsIntermitGeneratedID`), and how `Uimport.pas` knows to skip reading
them back in as independent, user-editable objects when a saved project is
reopened (see next section).

---

## 8. Architecture: two generations

### 8.1 Original design — text injected at export time

The first implementation treated the generated network purely as text:
`Uexport.pas` had three functions (`ExportIntermitStorage`,
`ExportIntermitOutfalls`, `ExportIntermitOutlets`) that looped over all
junctions and appended `[STORAGE]`/`[OUTFALLS]`/`[OUTLETS]` lines directly into
the exported `.inp` stream — **without ever creating corresponding objects in
the GUI's in-memory project model** (`Project.Lists[...]`). A matching pair of
functions (`ExportIntermitCurves`, `ExportControlCurves`) generated the rating
curve and control curve the same way.

This was intentionally regenerate-only: `Uimport.pas` explicitly **skips**
re-reading any object whose ID matches one of the prefixes above, so opening a
saved project never clutters the editable object lists with these generated
nodes — they get rebuilt fresh from the junction's properties on export.

This worked for running simulations, but it had two consequences:

1. **No results could be displayed for the generated network.** Nothing in
   the GUI's map, time-series picker, or results tables could reference an
   object that never existed outside the exported text — there was only a
   cosmetic, non-interactive schematic overlay (`DrawIntermitStorOverlay`,
   drawn in pixel space, toggled by **View ▸ Intermittent Nodes**) showing
   where the network *would* be, with no data behind it.
2. **A real node/link index-ordering bug.** SWMM assigns each node/link's
   internal result index by the order objects appear while scanning the
   `.inp` file. Because the synthetic `[OUTFALLS]`/`[STORAGE]`/`[OUTLETS]`
   blocks were written **before** the real ones of the same type
   (`ExportIntermitOutfalls` then `ExportOutfalls`, etc.), the engine's
   internal indices for any genuine user-created Outfall/Storage/Outlet were
   shifted by however many synthetic objects preceded them. The GUI's own
   index bookkeeping (`Uoutput.SetupResultsArrays`) assumes a real object's
   position in `Project.Lists[Type]` matches the engine's index, so any
   project that had both an intermittent junction *and* a real outfall/storage
   /outlet would show results for the wrong node.

### 8.2 Current design — materialized, synced objects

The generated network is now built as real `TNode`/`TLink` objects, added to
`Project.Lists[STORAGE/OUTFALL/OUTLET]`, by a new routine:

```pascal
procedure UIntermitDisplay.SyncIntermitObjects;
```

For every junction that is currently "live" (see §8.3), it creates-or-updates
the storage tank, both outfalls, and all three outlets, populating their
`Data[]` fields exactly as described in §4, and gives them real map
coordinates (a small offset from the junction, auto-scaled to the project's
extent — see §8.4). It also removes any previously generated objects that no
longer apply (junction deleted, renamed, or no longer intermittent).

Because these are now ordinary project objects:

- `Uexport.ExportStorage` / `ExportOutfalls` / `ExportOutlets` write them out
  automatically, in `Project.Lists` order, like any other object — so the
  three old `ExportIntermit*` text-injector functions, and the "don't write
  the section header twice" workarounds in the plain exporters, were removed
  entirely. This also **fixes the index-ordering bug** from §8.1: there is no
  longer a reason for synthetic objects to appear before real ones in the
  file, since both now come from the same `Project.Lists` iteration.
- `Umap.pas`'s existing node/link drawing loops (`DrawNodes`, `DrawLinks`)
  draw them with their real simulation-result colors automatically — no new
  rendering code needed. The old `DrawIntermitStorOverlay` schematic is no
  longer called (kept, unused, for reference).
- The object browser tree, time-series picker, and results tables — anything
  that walks `Project.Lists` — can reference them the same way they reference
  any other node or link.

`SyncIntermitObjects` is called:

- At the start of `Uexport.ExportProject` (covers both **Save** and **Run**,
  since both funnel through this one function).
- Right after a project finishes loading (`Fmain.ReadInpFile`), so results and
  the map reflect a project's intermittent junctions immediately on open,
  without requiring a fresh run.
- When the user turns on **View ▸ Intermittent Nodes**, so the display is
  refreshed on demand.

Nothing changed about how projects are saved or reopened: `Uimport.pas` still
skips reading these objects back in by name (§7), so a saved `.inp` round-trips
exactly as before — the generated network is rebuilt fresh by
`SyncIntermitObjects` the next time it's needed.

### 8.3 What makes a junction "live"

Two independent checks existed previously and were not always applied
together: whether the **Intermittent Demand Node** toggle was `YES`, and
whether the tank fields were non-zero. The old `[STORAGE]`/`[OUTFALLS]`/
`[OUTLETS]` writers only checked tank size, while the curve/control-rule
writers also checked the toggle. That meant a junction with the toggle
switched back to `NO` but tank values still populated from a previous edit
would keep generating the hydraulic network (storage tank, outlets) while no
longer generating the rating curve or control rule it depends on — producing
an outlet that references an undefined curve.

This is now expressed as one predicate used everywhere:

```pascal
function JunctionIsIntermittent(N: TNode): Boolean;
begin
  Result := SameText(Trim(N.Data[JUNCTION_INTERMITTENT_TOGGLE_INDEX]), 'YES')
            and JunctionHasIntermitStorage(N);
end;
```

### 8.4 Generated objects are read-only and cannot be deleted directly

Since the junction's properties are the real source of truth and the
generated network is just their "compiled" form (§8.2), a user editing or
deleting a generated object directly would be misleading — any such change
would simply be overwritten (or recreated) the next time `SyncIntermitObjects`
runs. To make that clear instead of surprising, two guards were added:

- **Property Editor**: `PropEdit.TPropEdit` gained a `ReadOnlyOverride`
  property that forces every row read-only (visually and behaviorally)
  regardless of its own per-field style. `Uedit.EditNode`/`EditLink` set it
  whenever the selected Storage/Outfall/Outlet's ID matches
  `UIntermitDisplay.IsIntermitGeneratedID`, so a generated object's properties
  can still be inspected but never edited (including its name and
  coordinates).
- **Deletion**: `Ubrowser.BrowserDeleteObject` (the single routine behind both
  the Browser's Delete button and the map's Delete key) now checks the same
  predicate first and, if the selected object is generated, shows an
  explanatory message and refuses to delete it — pointing the user back to
  the junction's "Intermittent Demand Node" toggle / tank size instead.

(Renaming a *real*, user-created object to collide with one of the reserved
ID prefixes, or using "Convert Object Type" on a generated object, are not
specifically guarded against - low-probability edge cases left for a
follow-up if they turn out to matter in practice.)

### 8.5 Placement of the generated objects

Since the generated nodes need real map coordinates (not just pixel offsets),
`SyncIntermitObjects` estimates a sensible spacing from the spread of the
project's existing junctions (2% of their bounding-box diagonal, or a fixed
fallback if none are placed yet) and lays the chain out around the junction:
storage tank one step east, demand outfall two steps east, leakage outfall one
step north. If the junction itself has no coordinates yet, its generated
objects are left unplaced too (consistent with how any other node with
missing coordinates is treated elsewhere in the GUI).

---

## 9. Where things live in the code

| File | Role |
|---|---|
| `Uproject.pas` | `JUNCTION_INTERMIT_*` property indices; `MAXNODEPROPS`. |
| `objprops.txt` | Default values, property-grid field definitions, hints, and units for the junction's intermittent-supply fields. |
| `Fproped.pas` | Enables/disables the intermittent fields in the property grid based on the toggle. |
| `UIntermitDisplay.pas` | Canonical ID builders, qualifying predicate, and `SyncIntermitObjects` (object materialization/pruning). |
| `Uexport.pas` | Writes the `.inp` file; calls `SyncIntermitObjects`; builds the consumption rating curve, float-valve control curve, and control rules; persists the custom round-trip `[INTERMIT_STORAGE]` section. |
| `Uimport.pas` | Skips re-reading generated objects by name prefix; reads back the custom `[INTERMIT_STORAGE]` section into the junction's properties. |
| `Umap.pas` | Draws the generated objects like any other node/link; hides them when the View option is off; retired `DrawIntermitStorOverlay`. |
| `Fmain.pas` | Hooks `SyncIntermitObjects` into project-open and the **View ▸ Intermittent Nodes** toggle. |

---

## 10. Using it in the GUI

1. Select a junction, set **Intermittent Demand Node** to `YES`.
2. Fill in the Pressure Dependent Withdrawal, Storage Tank, Consumption, and
   Leakage fields (and Tank Float Valve Height if the default of `0.9` isn't
   appropriate for the tank's height or the project's units).
3. Turn on **View ▸ Intermittent Nodes** to see the generated storage tank,
   outfalls, and outlets appear on the map near the junction.
4. Run the simulation (or just save the project) — this regenerates the
   network from the current property values.
5. After a run, the generated objects behave like any other SWMM object:
   select them on the map or in the browser tree to color-code or plot their
   results (tank depth, withdrawal/leakage/consumption flow, outfall inflow)
   using the normal SWMM results tools.

---

## 11. Known limitations / possible follow-ups

- The generated objects also appear in the object browser tree, node/link
  counts, and any other UI that walks `Project.Lists` — only the **map
  drawing** currently respects the View ▸ Intermittent Nodes toggle. Hiding
  them from the browser tree and other pickers as well would be a follow-up.
- Their map position is only recomputed when `SyncIntermitObjects` runs (on
  open, save/run, or toggling the View option) — dragging the junction on the
  map doesn't instantly drag its generated objects along with it.
- The "skip the tank entirely for a junction with no tank size" mode described
  in `Guide_Intermittent_Nodes.pdf` (explicitly called out there as lowest
  priority / not required for a first version) is still not implemented:
  today, a junction with the toggle on but all three tank fields at `0`
  generates no network at all.
- `Uimport.ReadIntermitStorageData`'s length check (`Ntoks < 8`) is slightly
  looser than the 12-13 fields it actually reads; a hand-edited or corrupted
  `[INTERMIT_STORAGE]` line with between 8 and 11 tokens could raise an
  index-out-of-range error. Pre-existing, unrelated to this feature's design,
  and not touched here.
- Generated objects are protected from editing (§8.4) and deletion, but
  renaming a *real* object to collide with a reserved ID prefix, or using
  "Convert Object Type" on a generated object, are not specifically guarded
  against.
