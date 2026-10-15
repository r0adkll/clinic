---
status: accepted (built 2026-10-14)
date: 2026-10-14
amends: "[[ADR-199 Clinic Plays OpenPeon Sound Packs]] (the Browse and Installed sections, and the pack's page)"
tags: [adr, sounds, ui, openpeon, filters]
---
# ADR-200: Sounds are browsed by language, franchise, tags and quality

## Context
User (2026-10-14), after seeing phase 1 of [[ADR-199 Clinic Plays OpenPeon Sound Packs]]: *"the UI could use
some UX/UI design improvements. We should have better filtering ability (a lang filter would be nice). Lets
look at the website again and get inspiration."*

Phase 1's Browse had a header row of the ten most common tags with no counts, a two-column list and
detail, and a pack page of capsules wrapping unevenly. The first screenshot of it also showed every row
carrying an *Official* badge in the accent, descriptions that only restated the name, and a blank detail
pane.

openpeon.com/packs, looked at the same day, has filter clouds for Franchises, Tags, Languages and Quality,
each value with a count, and a sort menu: A → Z, Z → A, Most sounds, Fewest sounds, Newest, Oldest,
Recently Updated, Quality. Its pack page puts a row of chips under the title, then each category's code and
meaning over a three-column grid of large ▶ buttons, then related packs. **Franchise is not in the
registry.** The site resolves it from a list in its own source (`site/src/lib/constants.ts`, MIT), with a
TODO to move it into the registry.

A design round on a canvas compared three layouts, built on the live registry with every filter working:
- A, a filter column, then the list, then the detail;
- B, a card grid under filter clouds, like the site;
- C, two panes with filter menus in the header.

It also compared the site-style pack page with phase 1's. The user chose A and the site-style page, and
narrowed the filters to *"language, franchises, tags, and qualities"*, which dropped Voices and Installed. A
second iteration was drawn at two real content widths (1100 pt and 880 pt) and accepted: *"That looks good,
lets go with that."*

## Decision
- **Browse is three columns.**
  - The filter column (220 pt) has collapsible sections: Language, Franchise, Tags and Quality.
  - The list column (320 pt, or 290 when tight) holds the search, the result count, the sort menu, and a
    chip for each active filter with *Clear all*.
  - The pack page takes the rest.
- **The filter column folds by itself** below 900 pt of content, which is Clinic's default window.
  A button beside the search shows or hides it, carrying a badge with the number of active filters while
  it is hidden. In a wide window that choice is remembered (`ClinicSoundsFiltersShown`).
- **The facets:**
  - **Language** shows native names with the reader's name beside them (日本語 *Japanese*). The Mac's own
    languages come first, then the five most common, then *All N languages*. Codes fold to their base
    language (`zh-CN` is `zh`), and `en,ru` counts under both.
  - **Franchise** lists the eight most common, then *All N franchises* with a field to narrow them, and
    *No franchise* last, however many packs it holds.
  - **Tags** are chips with counts, the twelve most common first.
  - **Quality** is Gold and Silver, then Official, Verified and Community.
- **How filters combine:**
  - Values in one facet widen the list (Japanese or Chinese); values in different facets narrow it
    (Japanese and Gold).
  - A count is what ticking that value would show with the other facets applied, so it leaves its own
    facet out. A value that would show nothing is dimmed, not hidden, so the column does not jump.
  - Whatever is ticked always stays visible.
- **The search** reads names, franchise, author, tags, the description and every line the pack says. It
  ignores case and punctuation, so *work work* finds "Work, work." Under *Recommended*, the whole phrase in
  the name ranks first, then in what the pack is about, then in what it says, then every word somewhere.
  Then come official and verified packs, gold, and the name. Other sorts: Name, Most lines, Newest,
  Recently updated.
- **Franchise comes from a bundled copy of the site's list.** `scripts/sound-franchises` reads
  `constants.ts` and writes `ClinicCore/Resources/sound-franchises.json` with its source and MIT notice;
  run it to refresh. A pack's franchise is, in order: the registry's own `franchise` (decoded already, for
  the day the registry serves it), the franchise whose keys hold the pack's name, then the first of its
  tags a franchise holds, which is the site's order.
- **Every pack's manifest is read in the background** when the screen opens. They are read eight at a time,
  cached by name and version in Caches, and fold into the search and the pack pages as they arrive. The list
  is usable before they finish.
- **The pack page follows the site:**
  - an initials tile, the name, the franchise as a link that filters to it, and the author;
  - chips for quality, trust, version, language, license, lines, *N of 9 categories* and size;
  - the description only when it says more than the name;
  - an action bar: Install / Use as Default / *Default pack*, Update, *Use for Project…* and *Add to
    Rotation* (disabled until phase 2), status text, and Uninstall in a ⋯ menu;
  - each category as its code, its title and when Clinic plays it ("a turn, run or checks finish, or a child
    reports"; "Clinic doesn't play this yet" for `resource.limit` and `task.progress`), over an adaptive grid
    of line tiles, six shown then *Show all N*;
  - a dashed note naming the categories with no lines, which fall back to the notification sound;
  - *More from ‹franchise›* (or related by tag), and the source repository as a link.
- **Rows** read *Franchise · N lines · Quality · author*, with a language badge and *Installed* or
  *Default*. They carry no trust badge: the list already sorts official packs first.
- **Installed** keeps the list and the page without the filter column. Its search narrows by name.
- **Changing a filter scrolls the list to the top.**

## Consequences
- ClinicCore gains `SoundCatalog`, `SoundPackFilter` and `SoundFranchises`, unit-tested: facets widening
  and narrowing, counts leaving their own facet out, search across franchises and lines, ranking, sorts,
  franchise resolution, language folding, and the bundled list loading. `SoundRegistry.Entry` drops its own
  `matches` for the catalog's, and gains `added`, `franchise` and `languages`.
- The franchise list goes stale between refreshes. Proposing upstream that the registry serve `franchise`
  is open; nothing has been sent.
- 370 manifests are fetched once per version, about 2 MB. The first open costs that many requests to
  raw.githubusercontent.com, eight at a time.

## Verification
- `make test`: ClinicCore 678 pass, nine of them new for the catalog. One test caught that "Work, work."
  did not match *work work* until search text dropped punctuation.
- Clinic Dev, driven through accessibility (granted to the host Clinic once its stale grants were reset)
  and captured with `screencapture -l`:
  - Browse at 1440 × 950: 370 packs, the four sections and the counts.
  - GLaDOS's page: chips, action bar, every category with its *when*, and the line grid.
  - 日本語 then Gold: 19, then 2 packs; zero-count values dimmed; chips with *Clear all*.
  - *work work*: Orc Peon first, then its Polish version.
  - 1180 × 760 with Overwatch ticked: the column folded and the filter button carrying a *1*; *Show
    filters* brought it back.
  - Install from Peon's page: it was written to Clinic Dev's own `SoundPacks/peon` and became the default,
    and the footer said "Installed Orc Peon."
- Clinic Dev's `SoundPacks`, `ClinicSoundPacks` and `ClinicSoundsFiltersShown` were removed afterwards.
