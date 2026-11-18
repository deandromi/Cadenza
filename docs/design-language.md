# Cadenza design language

Draft one. The style comes from a family of small product sites the team
admires, re-expressed with Apple-native materials rather than their fonts,
their Chinese typography or any of their details: warm paper and warm ink,
editorial serif display type at large sizes, hairline rules, one deep stamp
accent, whisper-soft shadows, and edges that dissolve into the paper. On
top of that paper world the operating chrome is Liquid Glass, the way Apple
intends it: a few hand-sized lenses floating on the sheet, never a band of
frosted material owning a region of the window.

The concept, in one line: ink on paper, tools of glass.

## Surfaces and ink

Two appearances, both warm, both defined as dynamic colors so light, dark,
increased contrast and reduced transparency all work from the same names.

| Role | Light | Dark |
| --- | --- | --- |
| Paper (the window) | ivory, warm off-white | lamp-lit charcoal |
| Parchment (recessed washes, faded edges) | one step deeper than paper | one step lighter than paper |
| Ink (primary text, staff lines) | warm near-black | warm ivory |
| Secondary ink (hints, timestamps) | warm mid gray | warm mid gray |
| Hairline (rules, card strokes) | paper-dark, low contrast | paper-light, low contrast |
| Stamp (the one accent, state only) | deep carmine | softened carmine |

Rules:

- The accent carries state and nothing else: recording, a chord sounding,
  an error. Decoration never takes it.
- Errors stay quiet sentences in the ink hierarchy; the accent gives them
  weight, exclamation marks never will.
- Paper cards float only when they are truly above something; otherwise
  ink sits directly on paper, separated by hairlines and space.

## Type

Native fonts only. The serif character of the reference family comes from
the system serif (the New York design) through
`NSFontDescriptor.SystemDesign.serif`; the interface copy stays system sans
at default sizes.

| Step | Face | Role |
| --- | --- | --- |
| Display | System serif, large (about 96 pt) | The chord that is sounding now |
| Heading | System serif, medium (about 28 to 34 pt) | Section moments |
| Row | System serif, small (about 20 pt) | Chord symbols in the history |
| Body | System sans, default sizes | All controls and copy |
| Digits | Monospaced digits | Time, counts |

- Copy is sentence case everywhere.
- Large type earns its size: the display step shows one chord, not a
  paragraph.

## The glass contract

What makes chrome Liquid Glass rather than frosting:

- One `NSGlassEffectContainerView` hosts every lens. Lenses negotiate
  blending through the container, which is what makes several of them look
  like objects on one desk instead of panels from different apps.
- Lenses sit on content, they do not own territory. A full-width pinned bar
  is a tiled toolbar, not a lens. Each lens is sized to its content and
  floats with at least 24 pt of paper visible on its sides.
- Controls on glass are `effectIsInteractive` lenses themselves: an
  interactive glass button highlights and dims on hover and press through
  the material, not through a bezel.
- Tint is state. Recording tints the transport lens with the stamp color at
  low alpha; a quiet session tints nothing.
- Glass gets no hand-rolled shadows, no gradient halos, no fake blur
  stacks. It refracts the paper world it floats on, which is exactly why
  the paper world has to be worth refracting.
- Content scrolls edge to edge underneath the lenses.

The lenses on the practice screen:

1. Transport, bottom center. Compact pill: listen and record actions,
   sentence case. Interactive glass. Tints stamp while recording.
2. Session meta, top right. Clear glass, never interactive: level, duration,
   note count. At rest it is nearly invisible; the level line inside it
   breathes with what the room is doing, so the glass is live rather than
   decorative.
3. Nothing else. If a third lens is ever wanted, one of these has to go.

Fallbacks:

- Reduce transparency: lenses become paper cards with hairline strokes,
  same shapes, same layout, opaque.
- Increase contrast: ink and hairlines step darker (light) or brighter
  (dark), accent stays, layout unchanged.
- Every control is reachable and labeled for VoiceOver; the level line
  also has an accessibility value so the meter is not decoration.

What the current app gets wrong against this contract, and what changes:
the single glass bar is pinned full width, so it reads as a tiled footer;
it lives outside any container view; its buttons are ordinary rounded
bezels rather than interactive glass; the backdrop under it is a generic
cool gradient with nothing to refract; the giant chord renders in a flat
gray instead of ink; and there are no reduced-transparency or
increased-contrast answers.

## The practice screen

Paper fills the window. Reading order, top to bottom:

1. Session label, small system sans in secondary ink, with a hairline under
   it running the width of the text column.
2. The current chord: display serif in ink. When a chord lands its symbol
   takes the stamp color for as long as the chord is sounding, then settles
   back to ink as it releases. Typography carries the state, so the lens
   above stays quiet.
3. The history: one line per chord, monospaced time in secondary ink then a
   row-serif symbol, eight points of leading, a hairline rule every minute
   of session time. The list scrolls to the newest entry and its top edge
   dissolves into paper, the same fade the paper family uses, done with a
   soft paper-colored gradient over the scroll region, never a blur.
4. Chrome floats over all of it: the transport pill bottom center, the
   meta lens top right. The history runs underneath them unchanged.

An empty session shows the display chord as a dash in secondary ink and
one quiet sentence: start listening and play.

## The engraving pass, later

When sheet music generation lands (see the roadmap), it stays in this
world: the score is ink on paper, one page at a time, staff lines at
hairline weight. The choices step (time signature, key, tempo) reads as a
short document footer the generator writes down, paper cards with hairlines
rather than a modal quotation, and the glass transport lens carries the
action that engraves it. Notation rendering itself never puts glass over
the staff; lenses remain chrome for pages, zoom and annotate.

## Motion

Nothing spins. A new chord crossfades over roughly 120 ms, history rows
append at reading speed, the meta lens level moves continuously. Reduce
motion replaces all of it with hard cuts and a static level number.
