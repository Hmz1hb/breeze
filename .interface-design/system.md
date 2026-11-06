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

Verification: follow AGENTS.md. Leave automated tests and UI checks to the user unless explicitly requested.
