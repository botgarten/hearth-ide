---
name: Hearth IDE
description: Dein Agent. Dein Abo. Unser Feuerring. A ring of field stones around a fire, at night.
colors:
  night: "#0e0a12"
  night-2: "#170f1c"
  plum: "#2a1e2e"
  crimson: "#c4161c"
  ember: "#ff5a1f"
  flame: "#ffa62b"
  core: "#ffe3a1"
  ash: "#e9dfe6"
  ash-2: "#bfb0bb"
  ash-3: "#9a8b97"
  cold: "#8a8194"
  unlit: "#8f7d95"
  hearth-well: "#120c15"
  tip-well: "#1d1420"
  frame-well: "#19151c"
  stone-body: "#7a6470"
  stone-lip: "#f4e6dc"
  stone-recess: "#0c0708"
  rule-line: "rgba(233, 223, 230, .14)"
  rule-line-soft: "rgba(233, 223, 230, .1)"
typography:
  display:
    fontFamily: "Bricolage Grotesque, Avenir Next, sans-serif"
    fontSize: "clamp(2.7rem, 5.6vw, 5.4rem)"
    fontWeight: 800
    lineHeight: 0.93
    letterSpacing: "-0.035em"
    fontVariation: "\"opsz\" 96"
  headline:
    fontFamily: "Bricolage Grotesque, Avenir Next, sans-serif"
    fontSize: "clamp(2rem, 3.8vw, 3.4rem)"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "-0.03em"
  numeral:
    fontFamily: "Bricolage Grotesque, Avenir Next, sans-serif"
    fontSize: "4.4rem"
    fontWeight: 800
    lineHeight: 0.8
  roster-name:
    fontFamily: "Bricolage Grotesque, Avenir Next, sans-serif"
    fontSize: "clamp(1.3rem, 2.2vw, 1.8rem)"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.015em"
  title:
    fontFamily: "Bricolage Grotesque, Avenir Next, sans-serif"
    fontSize: "1.35rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  title-sm:
    fontFamily: "Bricolage Grotesque, Avenir Next, sans-serif"
    fontSize: "1.15rem"
    fontWeight: 700
    lineHeight: 1.2
  lede:
    fontFamily: "Hanken Grotesk, Avenir Next, sans-serif"
    fontSize: "clamp(1.05rem, 1.4vw, 1.2rem)"
    fontWeight: 400
    lineHeight: 1.6
  body:
    fontFamily: "Hanken Grotesk, Avenir Next, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.6
  small:
    fontFamily: "Hanken Grotesk, Avenir Next, sans-serif"
    fontSize: "0.9rem"
    fontWeight: 400
    lineHeight: 1.35
  label:
    fontFamily: "Hanken Grotesk, Avenir Next, sans-serif"
    fontSize: "0.9rem"
    fontWeight: 600
    lineHeight: 1.2
  code:
    fontFamily: "Azeret Mono, ui-monospace, SF Mono, monospace"
    fontSize: "0.84rem"
    fontWeight: 400
    lineHeight: 1.55
    fontFeature: "\"liga\" 0, \"calt\" 0"
  mono-label:
    fontFamily: "Azeret Mono, ui-monospace, SF Mono, monospace"
    fontSize: "0.8rem"
    fontWeight: 500
    lineHeight: 1
    fontFeature: "\"liga\" 0, \"calt\" 0"
  agent-name:
    fontFamily: "Azeret Mono, ui-monospace, SF Mono, monospace"
    fontSize: "clamp(1.05rem, 1.9vw, 1.45rem)"
    fontWeight: 600
    lineHeight: 1
    fontFeature: "\"liga\" 0, \"calt\" 0"
rounded:
  focus: "4px"
  tip: "9px"
  well: "12px"
  frame: "14px"
  pill: "999px"
spacing:
  gutter: "clamp(1rem, 4vw, 3.5rem)"
  container: "1240px"
  section: "clamp(4rem, 9vw, 8rem)"
  row: "1.25rem"
  column: "1.6rem"
components:
  install-command:
    backgroundColor: "{colors.hearth-well}"
    textColor: "{colors.core}"
    typography: "{typography.code}"
    rounded: "{rounded.well}"
    padding: ".95rem 1.1rem"
    width: "36rem"
  copy-button:
    backgroundColor: "{colors.flame}"
    textColor: "{colors.night}"
    typography: "{typography.label}"
    padding: "0 1.1rem"
  copy-button-hover:
    backgroundColor: "{colors.core}"
    textColor: "{colors.night}"
  version-badge:
    textColor: "{colors.flame}"
    typography: "{typography.mono-label}"
    rounded: "{rounded.pill}"
    padding: ".3rem .45rem"
  rule-tip:
    backgroundColor: "{colors.tip-well}"
    textColor: "{colors.ash}"
    rounded: "{rounded.tip}"
    padding: ".6rem .8rem"
    width: "21rem"
  pin:
    backgroundColor: "{colors.flame}"
    textColor: "{colors.night}"
    rounded: "{rounded.pill}"
    padding: ".4rem .65rem"
  screenshot-frame:
    backgroundColor: "{colors.frame-well}"
    rounded: "{rounded.frame}"
  nav-link:
    textColor: "{colors.ash-2}"
  nav-link-hover:
    textColor: "{colors.ash}"
  text-link:
    textColor: "{colors.flame}"
  text-link-hover:
    textColor: "{colors.core}"
---

# Design System: Hearth IDE

## Overview

**Creative North Star: "Feuerring bei Nacht"**

The page is a night clearing with one fire in it. The fire is the only light source; everything else is night ground, ash-coloured type and field stones that are lit from the side facing the flames. The sandbox is the ring of stones: what is inside burns freely, what is outside stays cold. Each stone carries a literal sandbox target (`~/.ssh`, `example.com`, `Port 22`) cut into its face.

Density is low and typographic. Content sits on a 1240px column inside a responsive gutter. Sections are open fields separated by vertical rhythm rather than containers; lists are ruled with ash hairlines, not boxed. Warm colour appears only where the fire would reach: the lit half of the headline, the install control, pins, glows and stone heat. Motion follows the same idea: the fire flickers, sparks rise, embers smoulder, numbers ignite. With reduced motion all of it holds still in its lit state.

The world is procedural rather than illustrated. Fire, smoke and sparks come from a canvas particle loop. Stones are smooth SVG slabs (dark body, fine grain, a heat glow and a rim of firelight) whose light turns towards the fire as the ring slowly circles it; far stones pass behind the flames, near ones in front. Sparks that hit a stone break on it with a shockwave and fall back towards the fire. The only rasters are the app icon and real app screenshots.

**Key Characteristics:**
- Night ground (night → night-2 → plum → night-2 → night, a vertical wash over ~220rem) with firelight as the only light.
- Field stones as the signature component: irregular smoothed slabs, lit from the fire, with labels cut into a smoothed face.
- One shared light variable (`--flicker`) drives every firelit surface.
- Bricolage Grotesque at 800 for big compressed statements, Hanken Grotesk for German prose, Azeret Mono for literal machine strings.
- Ruled lists (hairline ash borders) instead of cards.
- Soft, downward, black shadows; the only coloured glow is the fire's.

## Colors

A night palette with a four-step fire ramp (crimson → ember → flame → core) and a three-step ash ramp for text.

### Primary
- **Flame** (flame): The fire's working colour. Used for the lit headline span, text links, the copy button, pins, the version badge, focus rings, rule names in the tip, and the roster name on hover.
- **Ember** (ember): Fire at contact. Used for the `$` prompt, list markers, the install and tip borders (35–45% alpha), stone heat, the final state of ignited numerals, and `::selection`.
- **Core** (core): The white-hot centre. Used for code and literal strings inside the ring (install command, agent name, `~/dein-projekt`), and as the hover state of flame-filled controls and links.

### Secondary
- **Crimson** (crimson): The deep edge of the flame. Used only in light falloff (firelight and ember glows), the pin's dot, and one beat of the ignite sequence. Never used for text or fills.

### Neutral
- **Night** (night): Page ground, `theme-color`, text on flame fills, the dark end of every stone's shade gradient.
- **Night 2** (night-2) and **Plum** (plum): The middle stops of the body's vertical night wash. Plum is the deepest the night gets toward the middle of the page.
- **Ash** (ash): Primary text and headlines.
- **Ash 2** (ash-2): Ledes, section ledes, nav links, roster login column, stroke body.
- **Ash 3** (ash-3): Quiet metadata: facts, captions, footer, side notes, the roster "how" column, copy status.
- **Cold** (cold): Things outside the ring. Used for the "Draußen bleiben:" heading, which stays out of the fire's colour on purpose.
- **Unlit** (unlit): A numeral before it ignites.
- **Wells** (hearth-well, tip-well, frame-well): Near-black plum surfaces for the install command, the rule tip and the screenshot frame. They are slightly lifted from night so a hairline and soft shadow can sit on them.
- **Stone body / lip / recess** (stone-body, stone-lip, stone-recess): The stone's base fill before lighting, and the two layers of a cut label.
- **Rule line** (rule-line at 14%, rule-line-soft at 10%): Ash hairlines for ruled lists and the footer. The 14% line opens a list; 10% lines separate its rows.

### Named Rules
**The One Light Rule.** All warm colour is firelight. Crimson, ember, flame and core appear only where the fire reaches (lit text, the install control, pins, glows, stone heat, sparks). The ground, wells and stones stay night, plum and ash. If you can't say what fire lights a warm pixel, it shouldn't be warm.

**The Inside/Outside Rule.** Literal things inside the ring (your project, the running agent, the install line) are set in core. Things the ring keeps out are set in cold or carved into stones. The palette carries the sandbox boundary.

## Typography

**Display Font:** Bricolage Grotesque (with Avenir Next, sans-serif), variable 400–800, self-hosted
**Body Font:** Hanken Grotesk (with Avenir Next, sans-serif), variable 400–600, self-hosted
**Label/Mono Font:** Azeret Mono (with ui-monospace, SF Mono, monospace), variable 400–600, self-hosted, ligatures always off

**Character:** Bricolage at 800 with tight negative tracking reads as heavy and compressed, close to a carved sign. Hanken is calm and readable for German prose. Azeret Mono is used for every string a machine would recognise: paths, hosts, commands, versions, agent CLI names and nono rule names.

### Hierarchy
- **Display** (display): The hero headline only. Optical size 96, `text-wrap: balance`, with the final clause lit in flame.
- **Headline** (headline): Section headlines, written as short complete sentences ending in a full stop, balanced.
- **Numeral** (numeral): The three stroke numbers, which ignite in order.
- **Roster name** (roster-name): Agent names in the roster, turning flame on row hover.
- **Title** (title, title-sm): Stroke titles at 1.35rem; status column heads at 1.15rem. The "outside" heading uses the same face at 1.25rem in cold.
- **Lede** (lede): The hero subline, limited to 34ch (46ch below 960px). Section ledes are 1.1rem in ash-2, limited to 52ch.
- **Body** (body): Default prose. Notes and captions stay within 70ch.
- **Small** (small): Captions, the arc's stone notes, roster "how" column and footer (0.86–0.95rem).
- **Label** (label): Button text and pins (0.82–0.9rem, weight 600).
- **Code** (code): The install command; inline code runs at 0.92em.
- **Mono label** (mono-label): Values in the fact border and the version badge. The tip's rule line is the same role at 0.74rem/600 in flame.
- **Agent name** (agent-name): The cycling name above the fire, in core.

### Named Rules
**The Mono Is Literal Rule.** Azeret Mono only ever sets something you could type into a terminal or a config (a path, host, port, command, version, CLI name or rule). German explanation always stays in Hanken.

**The Weight Carries It Rule.** Hierarchy comes from Bricolage at 700–800 with negative tracking against Hanken at 400. Uppercase and letterspaced labels are not used.

## Layout

A single centred column (container, padded by gutter) holds everything. The hero is a two-column grid (5fr copy / 7fr ring) with a minimum height of min(92vh, 860px), vertically centred. Sections use section padding on top and no bottom padding, so the next headline sets the rhythm. The closing section is centred and slightly taller (clamp(5rem, 10vw, 9rem) above).

Content grids: the outside arc is 6 equal columns, with stones lifted on a curve (`--lift` 1.4 / .5 / 0 / 0 / .5 / 1.4 rem) so the row reads as the far side of a ring. Strokes and status are 3 equal columns. Roster rows use a three-part grid (minmax(10rem, 1.1fr) / 1.4fr / 1fr), baseline-aligned, with row padding top and bottom.

Firelight is placed absolutely behind content: a 70×52rem hero light off the top right, and 42×30rem ember lights pushed partly off the left or right edge of individual sections. The page clips horizontal overflow so these never cause scrolling.

**Responsive at 960px:** the hero becomes one column with the ring above the copy (max 560px, centred, 4.5rem below it for the tip). The ledes widen to 46ch. The arc drops to 3 columns and loses its lift. Strokes and status stack, with strokes ruled horizontally. Roster rows stack with a .3rem gap.

**Responsive at 560px:** the nav keeps only GitHub. The copy button keeps only its icon. The ring's "lesen + schreiben" note hides. The arc goes to 2 columns. The screenshot swaps to the phone crop, keeps two pins (moved), and shortens the chat pin's label.

## Elevation & Depth

Depth comes from light, not from layers. The page is flat night lit from one fire. Surfaces show depth through radial light falloff, through the stones' computed lighting, and through soft black shadows that fall downward with negative spread. No shadow is coloured, and none is offset sideways.

### Shadow Vocabulary
- **Well** (`box-shadow: 0 16px 30px -16px rgba(0,0,0,.9), inset 0 1px 0 rgba(255,166,43,.12)`): The install command. A flame-tinted top edge suggests the fire catching its rim.
- **Float** (`box-shadow: 0 12px 30px -12px rgba(0,0,0,.8)`): The rule tip.
- **Pin** (`box-shadow: 0 8px 20px -8px rgba(0,0,0,.8)`): Pins over the screenshot.
- **Frame** (`box-shadow: 0 30px 60px -30px rgba(0,0,0,.95)`): The screenshot frame.
- **Icon** (`box-shadow: 0 4px 10px -4px rgba(0,0,0,.8)` at 36px; `0 14px 30px -12px rgba(0,0,0,.9)` at 96px): The app icon.
- **Stone shadow**: A blurred ellipse in near-black (#050307 at 85%), offset away from the fire, under every stone.

### Light Vocabulary
- **Firelight**: radial `rgba(196,22,28,.32)` → `rgba(255,90,31,.1)` at 55% → transparent, with opacity `calc(.75 + .25 * var(--flicker))`.
- **Ember light**: radial `rgba(255,90,31,.12)` → transparent, smouldering.
- **Embers halo** (close): radial `rgba(255,90,31,.45)` → `rgba(196,22,28,.15)` at 60% → transparent, behind the app icon.

### Named Rules
**The Flicker Bus Rule.** Every surface lit by the fire reads one shared variable, `--flicker`, rather than animating on its own. The canvas loop eases it toward a random value between .75 and 1.25 (factor .14 per step) and writes it to `:root` every frame. The firelight and the stones' heat layer (`calc(.35 + .4 * var(--flicker))`) follow it. Light sources away from the fire, such as ember lights and the closing halo, smoulder on their own CSS loop.

**The Shadows Fall Down Rule.** Shadows are black, soft, have negative spread and fall straight down. Stone shadows are the one exception, falling away from the fire.

## Shapes

There are two form languages. Built surfaces (install well, tip, screenshot frame) are gently rounded rectangles (9–14px) with a 1px hairline. Pills (999px) are kept for small tokens: the version badge and the pins.

Stones are the organic counterpart. Each outline is a closed Catmull-Rom curve through 12 points. Each point's radius is jittered between 74% and 100%, and the lower half is flattened to 70% so the stone rests on the ground. There are no hard corners and no regular ellipses.

Focus rings are 2px flame, offset 3px, at 4px radius. On a stone, focus strokes the rock outline in flame at 3px.

## Components

### Field Stone (signature)
A field stone is a procedural SVG slab lit by the fire, with a sandbox target cut into its face.
- **Surface:** A height map gives the stone its volume: the outline's alpha blurred by 0.22 × stone height (a rounded body), roughened by fractalNoise (baseFrequency .028–.042, 4 octaves, per-stone seed, 9% weight). Its colour is a low-frequency mottle mapped to warm grey (about #6f6062 ± 20%) with fine dark grains (noise at .42, thresholded). feDiffuseLighting (surfaceScale 0.42–0.5 × height, lighting-color #ffd8b4) and a soft feSpecularLighting sheen (constant .32, exponent 18, #ffae70) share one fePointLight at the fire's position, z = 1.25 × stone height. Colour × light (k1 1.12) plus 17% ambient keeps the far side readable; the sheen adds at 38%. Clipped to the outline.
- **Shade and heat:** A linear shade runs from transparent on the fire side to night at 55% on the far side. A radial heat layer (#ff7a2a at 34% → ember at 0) sits on the fire side, and its opacity follows `--flicker`.
- **Cut label:** First a smoothed face: a blurred ellipse in #3f3439 at 78%, sized to the label. On it, the label in Azeret Mono with ligatures off is drawn twice: a stone-recess copy 1.4 units higher, then a stone-lip copy. The pale lip with a dark recess just above it reads as letters cut into the stone.
- **Hit:** A radial hitglow (flame → ember → crimson → transparent) fades in over .08s and out over .7s. Hover, focus or a spark landing on the stone triggers it.
- **Interaction:** Ring stones are focusable list items, labelled with "target: consequence". Hover or focus shows the rule tip with the real nono rule and holds it: while a stone is hovered or focused, no spark is aimed at the ring and nothing replaces the tip. Otherwise a spark lands on a stone every 5–7s and shows the tip for 4s.
- **Placement:** In the ring, 8 stones sit on an ellipse (rx 375, ry 255 in a 1000×860 viewBox). They are scaled by depth (far stones smaller) and painted back to front. In the outside arc, each stone gets its own SVG lit from above the arc's centre.

### Fire (canvas)
- **Clock:** The simulation runs in fixed 60 Hz steps (at most 4 per frame), so the fire burns at the same pace on 60 and 120 Hz screens. All counts below are steps.
- **Fire:** Every step spawns 10 flame particles on seven columns, hotter and longer-lived in the middle. Each is a vertically stretched radial blob (1.9 → 4.5× as it ages) whose colour comes from one continuous heat ramp (pale gold #ffde96 → #ffaa3a → ember → #d63416 → deep red). A shared draught bends whole tongues and grows with height, so the tips lick. Flames are summed additively into a buffer, then laid on twice: blurred (1.4% of the width, 70%) for the glow and sharp for the licks, over a faint white-hot heart at the base. Under them: a bed of 18 coals that pulse on their own phases, and three logs with bark grain, sawn ends with a ring, and glowing cracks that follow the flicker. A floor glow (ember → crimson) follows the flicker.
- **Smoke:** Every 4th step adds a smoke puff (rgba(96,68,72) at most 11%). It drifts up and fades out before reaching the top of the canvas, which itself is masked transparent → black over its top 22%.
- **Sparks:** Every 10th step a free spark rises, drawn as a short tail along its path. Every 5–7s a spark is aimed at a random stone (unless one is hovered or focused), dies on contact, triggers that stone's hit, and breaks into 7 short ember fragments.
- **Agent name:** Above the fire, in core, cycling claude / codex / copilot / opencode / gemini every 4.2s with a .4s fade and 6px blur.
- **Economy:** The loop pauses when the ring leaves the viewport or the tab is hidden. DPR is capped at 2.

### Install Command
- **Shape:** A well (install-command) with a 1px ember border at 35% and the Well shadow, max 36rem wide.
- **Content:** Code in core with an ember `$` prompt that can't be selected. Long URLs break at `<wbr>` points rather than scrolling.
- **Copy control:** A flame-filled block on the right edge, with a 1px ember divider at 30% and a 0 11px 11px 0 radius. It holds a stroked inline SVG copy icon and the label "Kopieren". Hover turns it core. When done it turns #ffd27a and reads "Kopiert" for 3.2s, with a polite status line below. If the clipboard is unavailable, it selects the command and says so.
- **Closing variant:** Centred. A successful copy makes the embers halo flare.

### Fact Border
A ruled strip under the install command, max 36rem: rule-line hairlines top and bottom, rule-line hairlines between items, no outer side borders. Each item pairs ash-3 Hanken text (0.86rem) with an ash mono value (mono-label) and does not wrap internally.

### Ruled Lists
- **Roster:** Opens with a rule-line hairline at the top. Each row ends with a rule-line-soft hairline and holds three columns: name (roster-name, ash → flame on hover over .3s), login (ash-2), how (small, ash-3).
- **Strokes:** Opens with a rule-line hairline. Three columns are separated by rule-line-soft vertical hairlines; below 960px they are separated by horizontal hairlines instead. Each column has a numeral, a title and a body capped at 34ch.
- **Status:** Three plain bulleted lists under title-sm heads, with ember markers.
- **Inside list:** A wrapped inline list in ash-2, where literal items (code, strong) light up in core at 600.

### Rule Tip
A tip-well panel with a 1px ember border at 45%, the Float shadow, and 0.86rem/1.4 text. It shows the nono rule in flame mono above a plain German consequence. It sits centred under the ring and fades over .25s.

### Pins
Flame pills in label type with night text, placed over the real screenshot. Each has a 7px crimson dot as its leading mark. Pins name regions of the screenshot; they never stand in for it.

### Navigation
A wordmark (36px app icon at 9px radius, "Hearth IDE" in Bricolage 700 1.15rem, version badge) on the left. Plain text links in ash-2 on the right, ash on hover, no underline. Below 560px only GitHub remains.

### Links
Flame, 1px underline offset .2em, core on hover.

### Motion (world-wide)

All motion uses the `--ease` curve `cubic-bezier(.16, 1, .3, 1)` unless noted.
- **Flicker:** The canvas loop drives `--flicker` (see The Flicker Bus Rule).
- **Smoulder:** Opacity .55 → .9 → .7 → 1, ease-in-out, alternating, infinite. Ember lights run at 5.5s; the closing halo at 2.6s.
- **Ignite:** Stroke numerals step through unlit → flame → unlit → core → crimson → flame → ember over .9s with `steps(1, end)`, so the colour jumps like a match catching. They fire in order (250ms + 750ms per stroke) once the list is 40% in view.
- **Flare:** On a successful copy in the closing section, the embers halo scales 1 → 1.45 → 1 over 1.2s.
- **Reduced motion:** All CSS animations and transitions are off. The canvas draws one still frame of logs and fire. Agent names don't cycle. Numerals are lit from the start. The halo doesn't flare.

## Do's and Don'ts

### Do:
- **Do** light everything from the fire. Each new firelit surface reads `--flicker`, and each new stone points its rim light and heat glow at the fire's actual position (`light()` in site.js).
- **Do** cut stone labels as recess plus lip on a smoothed face, in Azeret Mono with ligatures off.
- **Do** put real, literal sandbox targets on stones and real nono rules in tips.
- **Do** separate list items with hairlines (rule-line opening a list, rule-line-soft between rows) rather than cards.
- **Do** keep warm colour for firelit things and literal inside-the-ring strings; keep outside things cold.
- **Do** keep shadows black, soft, negative-spread and falling down.
- **Do** give every animation a still, lit reduced-motion state, and pause the canvas off screen.

### Don't:
- **Don't** use gradients as decoration. Every radial gradient is light falloff from a source (fire, ember, hit); the body's vertical night wash is the only non-light gradient.
- **Don't** add a second light source or light stones from a generic top-left.
- **Don't** box content in cards, or tint panels with fire colours. Wells stay near-black plum.
- **Don't** set German prose in mono or literal machine strings in Hanken.
- **Don't** use uppercase letterspaced labels above headlines. Headlines stand on their own.
- **Don't** replace the real screenshot with mockups or illustrations, or replace stones with flat chips.
