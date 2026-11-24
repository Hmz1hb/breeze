# Breeze interface patterns

Intent: help a Mac owner understand resource use and reclaim storage with a clear next step. Keep actions calm, readable and predictable while evidence stays beside each decision.

Domain: thermal headroom, running tools, rebuildable caches, project output, recovery, disk space and Trash.

Palette: existing Breeze mint for primary actions and successful readings; blue for background atmosphere; system neutral surfaces and primary/secondary text; orange for attention; red for destructive actions. Colors communicate purpose rather than distinguishing otherwise equivalent controls.

Surfaces: retain the existing glass navigation shell and quiet material data panels. Action controls use an opaque system control background and a subtle separator border, with a stronger border in increased contrast.

Typography and spacing: system SF; action labels are 13-point medium (12-point for compact controls). Use a four-point spacing scale, eight-point icon/action gaps, and an eight-point button corner radius.

Shared actions: use `BreezeButtonStyle` through `.breezeAction()`. Standard actions are 34 points tall; compact row actions are 28 points, mini actions 24 points, and explicitly large actions 38 points. Width follows the label with the same horizontal padding. Supporting actions stay neutral; the main action uses mint. Destructive actions use red. Provide consistent hover, press, keyboard-focus, increased-contrast and disabled states. Navigation rows and content previews may retain plain styles.

Cleanup workflow: Scan → Choose → Review → Finish stays visible as a four-step journey. Core cleanup uses full-page workspaces; sheets are reserved for optional inspection, project-folder configuration, scan notes and AI setup. Only the current step carries its primary action. Do not duplicate Scan in the parent Storage header.

Choose: start with rebuildable files. Applications, personal data and permanent tool actions require deliberate selection. A compact recommendation panel explains recovery cost and offers an explicit bulk selection of available rebuildable items. Preserve manual choices across filters and rescans. Provide Rebuildable, Everything, In use and Selected views, then type categories. Group rows by type, with title, estimated size and recovery evidence. Put full paths and date explanations in inspection rather than every row.

Review: the cleanup plan is the single place to resolve blockers and approve removal. Separate Move to Trash from Remove permanently; require acknowledgement for permanent tool actions. Each entry offers Keep and progressive disclosure for paths and context. Show exact process commands/PIDs with their affected items. Offer keeping the affected items for later or stopping selected processes and refreshing the same plan. Normal Quit/SIGTERM only; protect Breeze and its ancestors and revalidate identities. Retain independent manual choices when refreshing an AI plan. Never remove automatically after preparation.

Progress and outcome: scan duration is unknown, so show live stage text with indeterminate activity. Removal uses measured item advancement. Allow cancellation and explain that completed changes remain applied. Keep a persistent completion receipt during automatic background refresh, distinguish Trash locations from permanent tool removals, show failures/partial work and provide Open Trash and review of remaining items. Never equate selected bytes with freed disk space.

Footer: keep the selection summary, Clear, optional Ask AI and Review selection in one anchored action area. Clear stays in position and disables when empty. AI setup remains secondary. Review and finish have their own contextual action bars. Use shared 34-point controls throughout, mint for moving forward and red for approved removal or process stopping.

Motion: `.interface-design/motion.md` is the full spec; `Sources/FanApp/BreezeMotion.swift` is the only source of durations, springs, transitions and motion helpers. Pages never hard-code animation values. Reduce Motion, Reduce Transparency and Increase Contrast are honoured inside that API. Hover treatments exist only as button styles (`.breezeCard`, `.breezeRow`, `.breezeTile`, `BreezeButtonStyle`), and keyboard focus shows the same state plus the 2-point mint ring. Perpetual motion runs only through the `breezeMotionLevel` gate.

The five rules builders may not break:

1. **Live telemetry never rolls.** Text fed by a sensor, a timer or a stream uses `breezeLive()`. Only values the user just caused, discrete results, countdowns and the hero RPM use `breezeNumeric`.
2. **Nothing draws from 0.** Rings, meters and the battery vessel appear at their value and then follow it. A fan ring at 0 reads as "fans stopped".
3. **Entrances once per session.** Reveals, chart draw-ins and path draws run the first time a page or element is shown after launch (`BreezeMotion.firstTime`). On every later visit the page transition is the only motion.
4. **No scroll-linked effects.** Content below the fold simply exists. The only scroll response is the header hairline.
5. **Exits are one value.** Every removal is an opacity fade of 0.20 s (`exit`). Direction lives on the insertion only.

Two more global rules:

- **Geometry-driven animation never runs on a size-only change.** Treemap rects, matched selection pills and chart domains animate when data or selection changes, not during live window resize. Key every such animation on the data (`.animation(_, value: ids)`), never implicitly.
- **System presentations stay system-animated.** Sheets, `fileExporter`, menus, alerts and popovers are not wrapped, delayed or restyled.

Type and rhythm: `BreezeStyle.Typography` (display 42 light rounded, title 28 semibold rounded, numeralL 27 and numeralM 21 medium rounded, eyebrow 9 semibold with 1.0 tracking) and 28-point page padding (`BreezeStyle.pagePadding`). Adopt them when a text or page is touched; no mass rename.

Verification: follow AGENTS.md. Leave automated tests and UI checks to the user unless explicitly requested.
