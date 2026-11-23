# Breeze motion and design plan (final build spec)

Read `.interface-design/system.md` first; everything there still holds. This file adds motion, atmosphere and a few design-system unifications. Builders follow it literally: pages never hard-code animation values, they call the API in section 4. A builder edits only its own files (section 6). `foundation` lands first.

## 1. The idea

**Breeze moves like conditioned air: things arrive on a soft current and settle without bounce, and the only thing that keeps moving is the air your fans are actually moving.**

1. **Motion is the reading.** Perpetual motion exists only where its speed, direction or colour is bound to a live measurement (fan RPM, heat, network rate, power flow). Nothing loops for decoration.
2. **Everything else moves once, on change.** Shapes (rings, meters, markers) ease to a new sample. Text that shows live telemetry does not animate at all.
3. **Calm control.** One spring family, critically damped. Entrances ease out, exits are a 0.20 s fade. The one expressive spring (`lift`) is reserved for two earned moments: the Checkup verdict and the Cleanup receipt.

### The five rules builders may not break

These also go into `system.md` (Motion section), verbatim:

1. **Live telemetry never rolls.** Text fed by a sensor, a timer or a stream uses `breezeLive()`. Only values the user just caused, discrete results, countdowns and the hero RPM use `breezeNumeric`.
2. **Nothing draws from 0.** Rings, meters and the battery vessel appear at their value and then follow it. A fan ring at 0 reads as "fans stopped".
3. **Entrances once per session.** Reveals, chart draw-ins and path draws run the first time a page or element is shown after launch (`BreezeMotion.firstTime`). On every later visit the page transition is the only motion.
4. **No scroll-linked effects.** Content below the fold simply exists. The only scroll response is the header hairline.
5. **Exits are one value.** Every removal is an opacity fade of 0.20 s (`exit`). Direction lives on the insertion only.

Two more global rules:

- **Geometry-driven animation never runs on a size-only change.** Treemap rects, matched selection pills and chart domains animate when data or selection changes, not during live window resize. Key every such animation on the data (`.animation(_, value: ids)`), never implicitly.
- **System presentations stay system-animated.** Sheets, `fileExporter`, menus, alerts and popovers are not wrapped, delayed or restyled.

## 2. Signature effect: Live Airflow (Overview hero)

The one screenshot moment. It lives in the Overview hero card (`OverviewSummaryView.swift`) and nowhere else in the main window. The fan motif appears in exactly two places: this hero and the menu-bar icon. Sidebar, fan list and widget use static `fanblades` symbols.

The hero has four designed states, all of them intentional frames:

| State | Condition | Ring (124 pt) | Centre | Airflow | Eyebrow (9 pt) |
| --- | --- | --- | --- | --- | --- |
| No reading | `snapshot == nil` | empty track | "—" | none | LIVE FROM YOUR MAC, secondary colour |
| Passive | `snapshot.fans.isEmpty` | fraction = heat (0...1), tint `thermalColor(heat)` | static `thermometer.medium`, hottest °C (`breezeLive`), caption HOTTEST | none; a soft radial wash of `thermalColor(heat)` at 8% behind the ring carries the card | PASSIVE COOLING · NO FANS |
| Still air | fastest fan under 1 RPM | track only (true value 0) | static `fanblades.fill`, "0", RPM | the streaks, frozen, at 60% opacity | STILL AIR · FANS AT REST |
| Moving | fastest fan 1 RPM or more | fan fraction, end tint `thermalColor(heat)`, follows with `drift` | `BreezeFanGlyph` at real RPM, RPM `breezeNumeric` (the one rolling live number in the app) | live streaks | LIVE FROM YOUR MAC |

- The 27 pt status title is the model's own `statusTitle` (it already says "Passively cooled", "Heat boost · 100%" and so on). It swaps with `.contentTransition(.interpolate)`, weight unchanged. It is never delayed by a stagger.
- Heat boost engages (`boosted` becomes true): one orange halo leaves the ring (`breezePulse`), the boost line enters with `breezeDrop`. Fan-safety copy is unchanged.
- Accessibility: the ring keeps "Fastest fan n RPM"; in the passive state it reads "Hottest sensor n°C, n percent of the way to heat boost".

`BreezeAirflow` parameters (implemented once, in foundation):

| Parameter | Value |
| --- | --- |
| `speed` input | fan fraction 0...1 |
| Streak velocity | `18 + 120 * speed` pt/s |
| Streak count | `Int(16 + 40 * speed * density)`, hard cap 56 |
| Streak length / width | `10 + 36 * speed` pt / 1 to 1.5 pt, round caps |
| Streak opacity | per-seed 0.08...0.22 (light), 0.10...0.30 (dark) |
| Flow field | `y = y0 + A * sin(x / 180 + seedPhase + phase * 0.3)`, `A` 6...14 pt per seed |
| Colour | `BreezeMotion.thermalColor(heat)` |
| Mask | horizontal gradient: 1.0 at the ring edge, 0.5 under the title column, 0 at 72% of card width |
| Frame budget | 30 fps when the window is focused, 10 fps when visible but inactive, paused when hidden or `speed <= 0` |
| State | stateless particles: position is a pure function of an integrated `phase` and a per-index hash seed. The phase lives in a non-observable reference box and is advanced from `context.date` inside the `TimelineView` closure with `dt = min(dt, 0.25)`, so resuming after occlusion never jumps. Nothing is written to `@State` per frame |

Fallbacks: Reduce Motion draws the frozen 60% frame. Reduce Transparency or Increase Contrast hides the airflow layer. The layer is `accessibilityHidden(true)` and `allowsHitTesting(false)`.

## 3. Motion tokens

All in `Sources/FanApp/BreezeMotion.swift`.

```swift
enum BreezeMotion {
    static let xs = 0.12   // press, focus ring
    static let s  = 0.20   // hover, every exit
    static let m  = 0.32   // default entrance
    static let l  = 0.48   // journey step, layout morph, treemap drill
    static let xl = 0.80   // one-shot draws, count-ups, live-shape easing

    static let stagger = 0.045          // seconds between siblings
    static let staggerCap = 6           // later siblings share the last delay (max 0.27 s)
    static let travel: CGFloat = 12     // entrance offset

    enum Token { case press, hover, settle, glide, drift, lift, enter, exit, ambient }
}
```

| Token | Swift value | Use |
| --- | --- | --- |
| `press` | `.spring(response: 0.18, dampingFraction: 0.90)` | button press scale, focus ring |
| `hover` | `.spring(response: 0.26, dampingFraction: 0.86)` | hover lift, row highlight |
| `settle` | `.spring(response: 0.36, dampingFraction: 0.88)` | default state change, page and tab switches, numeric roll |
| `glide` | `.spring(response: 0.48, dampingFraction: 0.90)` | Cleanup steps, selection capsules, treemap, layout morphs |
| `drift` | `.spring(response: 0.80, dampingFraction: 1.00)` | rings, meters, live markers (0.8 s of a 2 s sample interval) |
| `lift` | `.spring(response: 0.42, dampingFraction: 0.72)` | only Checkup verdict and Cleanup receipt |
| `enter` | `.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)` | opacity on entrance |
| `exit` | `.timingCurve(0.4, 0, 1, 1, duration: 0.20)` | every removal |
| `ambient` | `.easeInOut(duration: 2.4)` | backdrop heat colour, on change only |
| reduced | `.easeInOut(duration: 0.16)` | returned for every token when Reduce Motion is on |

- One-shot draws and count-ups use `.timingCurve(0.22, 1, 0.36, 1, duration: xl)`.
- Direct manipulation (slider thumbs and their numerals, scrub rule, curve point drags) is 1:1 with the pointer and never animated.
- No `repeatForever`, no blur anywhere, no non-integer scale on containers that hold text (text shimmers).
- There is no `exitFactor`. Exit is `exit`.

## 4. API contract (`BreezeMotion.swift`, foundation builder)

```swift
extension BreezeMotion {
    static func animation(_ token: Token, reduceMotion: Bool) -> Animation
    /// withAnimation outside view bodies. Reads NSWorkspace.shared.accessibilityDisplayShouldReduceMotion on every call.
    static func animate(_ token: Token = .settle, _ body: () -> Void)
    static func delay(_ index: Int) -> Double                         // min(index, staggerCap) * stagger
    /// True for every caller in the main-queue turn that first asks for `key`, false for the rest of the app session.
    @MainActor static func firstTime(_ key: String) -> Bool
    /// clamp((temperature - 45) / (boost - 45), 0, 1); 0 when nil.
    static func heat(temperature: Double?, boost: Double) -> Double
    /// mint at 0, orange at 1. Never red (red is destructive only).
    static func thermalColor(_ heat: Double) -> Color
    static func nearest<T>(_ samples: [T], to date: Date, by key: KeyPath<T, Date>) -> T?
}

enum BreezeMotionLevel {
    case off, background, full
    var isActive: Bool { self != .off }
    func interval(fps: Double) -> Double        // full: 1 / fps; background: 1 / min(fps, 10)
}

extension EnvironmentValues {
    @Entry var breezeMotionLevel: BreezeMotionLevel = .off   // perpetual motion allowed right now
    @Entry var breezeHeat: Double = 0                        // 0...1, set by Dashboard
}

extension View {
    func breezeMotionScope() -> some View                    // main window root only (Dashboard)
    func breezeAnimation<V: Equatable>(_ token: BreezeMotion.Token, value: V) -> some View
    func breezeReveal(_ index: Int = 0, key: String) -> some View   // first time per session: opacity + y 12, delay(index)
    func breezeNumeric(_ value: Double?) -> some View        // numericText(value:) + settle + monospacedDigit
    func breezeLive() -> some View                           // monospacedDigit + .updatesFrequently, no content transition
    func breezePulse<T: Equatable>(trigger: T, tint: Color = BreezeStyle.mint) -> some View
    func breezeChartDrawIn(key: String) -> some View         // inside chartPlotStyle { $0.breezeChartDrawIn(key:) }
    func breezeChartScrub(_ selection: Binding<Date?>) -> some View   // on the Chart: hover scrubbing
    func breezeScrollEdge(_ scrolled: Binding<Bool>) -> some View     // on scroll content: true once content passes 8 pt
}

extension ButtonStyle where Self == BreezeCardButtonStyle { static var breezeCard: Self }
extension ButtonStyle where Self == BreezeRowButtonStyle  { static var breezeRow: Self }
extension ButtonStyle where Self == BreezeTileButtonStyle { static var breezeTile: Self }

extension AnyTransition {
    static func breezePage(forward: Bool) -> AnyTransition   // insertion y +6 (forward) or -6; removal = exit fade
    static func breezeStep(forward: Bool) -> AnyTransition   // insertion x +24 (forward) or -24; removal = exit fade
    static var breezeDrop: AnyTransition                     // insertion y -8; removal = exit fade
    static var breezeFade: AnyTransition                     // opacity; removal = exit fade
}

/// The one way to switch keyed content (pages, tabs, workspaces, journey steps).
struct BreezeSwitcher<Key: Hashable, Content: View>: View {
    init(_ key: Key, index: Int, axis: Axis = .horizontal, token: BreezeMotion.Token = .settle,
         @ViewBuilder content: () -> Content)
}

struct BreezeAirflow: View      { init(speed: Double, heat: Double, density: Double = 1) }
struct BreezeFanGlyph: View     { init(rpm: Double, size: CGFloat, weight: Font.Weight = .light, tint: Color = BreezeStyle.mint) }
struct BreezeRing: View         { init(fraction: Double, lineWidth: CGFloat = 9, tint: Color = BreezeStyle.mint, endTint: Color? = nil) }
struct BreezeMeter: View        { init(fraction: Double?, tint: Color = BreezeStyle.mint, height: CGFloat = 6, marker: Double? = nil) }
struct BreezeCountUp: View      { init(_ value: Double, format: @escaping (Double) -> String) }
struct BreezeDelayedProgress: View { init(_ label: String? = nil) }   // ProgressView that appears after 0.3 s
struct BreezePageHeader<Trailing: View>: View {
    init(_ title: String, subtitle: String, scrolled: Bool = false, @ViewBuilder trailing: () -> Trailing)
}
struct BreezeChartCallout: View { init(title: String, value: String, tint: Color = BreezeStyle.mint) }
```

Load-bearing implementation notes:

- **`firstTime`** is backed by a `@MainActor static var seen: Set<String>`. On the first ask it returns true and inserts the key on the next main-queue turn (`DispatchQueue.main.async`), so every sibling in the same stagger group gets true. `breezeReveal`, `breezeChartDrawIn` and every path draw read it once into `@State` at creation. Needed because `Dashboard.content` destroys a page when you leave it, so a local "appeared" flag would reset on every sidebar click.
- **`BreezeSwitcher`** is `ZStack(alignment: .top) { content().id(key).transition(...) }.animation(token, value: key)`. Axis `.vertical` uses `breezePage`, `.horizontal` uses `breezeStep`. Direction comes from a non-observable reference box in `@State` that compares `index` with the previous index during `body`, so jumps from the widget, Checkup and cards are directional too. Because only the insertion is directional, the removal can never play a stale direction. Content inside a switcher must not add its own insertion transition or reveal to its initial state (no double animation).
- **Transitions** are built on the `Transition` protocol (macOS 14). `body(content:phase:)` applies a private modifier that reads `@Environment(\.accessibilityReduceMotion)` and zeroes the offset, leaving opacity. `.animation(exit)` is attached to the removal half only.
- **`breezeMotionScope()`** captures the hosting `NSWindow` with a zero-size `NSViewRepresentable` and observes `NSWindow.didChangeOcclusionStateNotification`, miniaturize and deminiaturize, `NSApplication.didBecomeActive` / `didResignActive`, `NSProcessInfoPowerStateDidChange`, and `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`. Level: `.off` when the window is not `.visible`, is miniaturized, the screens sleep, Low Power Mode is on or Reduce Motion is on; `.background` when visible but `!NSApp.isActive`; otherwise `.full`. Reduce Motion is read from the environment in `body` on every evaluation, never cached. The widget panel has no perpetual motion and installs no scope.
- **`BreezeFanGlyph`** uses the menu bar's mapping (`min(rpm / 3000, 3)` visual revolutions per second), `TimelineView(.animation(minimumInterval: level.interval(fps: 30), paused: !level.isActive || rpm < 1))`, angle integrated in a reference box with `dt = min(dt, 0.25)`.
- **`BreezeRing` / `BreezeMeter`** appear at their value (no draw-in, ever) and follow changes with `drift`, scoped with `.animation(_, value: fraction)` on the shape only. `BreezeMeter.marker` is a 2 pt tick that moves with `drift`. A `nil` fraction renders the empty track. Each carries the accessibility label and value of the control it replaces.
- **`breezeNumeric`** uses `.contentTransition(.numericText(value:))` with `settle`; under Reduce Motion `.contentTransition(.opacity)`. `nil` leaves the text untouched (for "—").
- **`BreezeCountUp`** animates 0 to value once over `xl` through an `Animatable` modifier. The animated text is `accessibilityHidden(true)`; the container carries `accessibilityLabel` and `accessibilityValue` of the final formatted value. Reduce Motion shows the final value. Allowed in two places only: speed test result and Cleanup receipt.
- **Hover button styles.** `.breezeCard`: y -2, shadow radius 6 to 12 at 12% black, 120 pt radial spotlight at 7% white following `onContinuousHover` (skipped on macOS 26 interactive glass, which supplies its own). `.breezeRow`: primary 5% background and a 2 pt trailing-chevron nudge. `.breezeTile`: +8% brightness and a 1 pt inner stroke. No tilt, no scale. Each style reads `@Environment(\.isFocused)` and `configuration.isPressed` inside the style, so keyboard focus shows the identical lift or highlight plus the 2 pt mint ring (inset -3, same as `BreezeButtonStyle`). Non-interactive rows get no hover treatment. Reduce Motion: no offset, flat 5% highlight.
- **`breezePulse`**: one expanding ring, scale 1 to 1.6, opacity 0.5 to 0 over `l`, via `.phaseAnimator(trigger:)`. Never driven by a sample or a timer, only by a state change.
- **`breezeChartDrawIn(key:)`**: leading-to-trailing mask over `xl`, once per session per key. **`breezeChartScrub`**: `chartOverlay` with a clear hit shape and `onContinuousHover` that converts the pointer x to a date through `ChartProxy.value(atX:)` inside `proxy.plotFrame`, and clears on exit (deterministic hover on macOS; `chartXSelection` is not used). Inside the chart the builder draws a `RuleMark` (primary 25%, 1 pt), a `PointMark` (symbolSize 48) at `BreezeMotion.nearest(...)`, and `.annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { BreezeChartCallout(...) }`. Keyboard: the chart (or chart group) is one `.focusable()` stop; left/right arrows step one sample, Escape clears. The rule is never animated.
- **`breezeScrollEdge`**: `onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < -8 } action: { scrolled = $0 }` (single-value overload, back-deployed to macOS 13). **`BreezePageHeader`**: title 28 pt semibold rounded, subtitle `.subheadline` secondary, padding horizontal 28, top 30, bottom 20; `scrolled: true` fades in a hairline under the header with `settle`. No layout change, so no oscillation. The header arrives with the page transition; it has no entrance of its own. Wire `scrolled` only where the header sits outside the `ScrollView` (true in Dashboard's shared branch, Statistics, Battery, Checkup, This Mac; Network and Storage builders check their own layout).
- **`BreezeDelayedProgress`**: nothing for 0.3 s, then a `ProgressView` with `breezeFade`. Loading to content is one `breezeFade` swap. Empty and "no data" states use `breezeFade` with no stagger.

### Design-system unifications (foundation, `BreezeStyle.swift`)

- `BreezeStyle.Typography`: `display` 42 light rounded, `title` 28 semibold rounded, `numeralL` 27 medium rounded, `numeralM` 21 medium rounded, `eyebrow` 9 semibold tracking 1.0. Builders switch when they touch a text; no mass rename.
- Page padding is 28 everywhere (the default pages use 26 today).
- Local mint copies (`accent`, `storageMint`, `networkMint`, `diskMint`) become `BreezeStyle.mint` when a builder already edits the line.
- `BreezeButtonStyle`: press scale 0.97 with `press` (labels are single-line, fixed height), hover overlay fades with `hover`, focus ring fades with `press`. Heights 24 / 28 / 34 / 38 and colour roles unchanged.
- `BreezeDisclosure`: replace `.snappy(duration: 0.2)` with `BreezeMotion.animate(.settle)`.
- Segmented controls stay the native `Picker(.segmented)` on every macOS version.
- `system.md` gains a "Motion" section: the five rules of section 1, the two global rules, and a pointer here.

## 5. Atmosphere: thermal aurora

`BreezeBackdrop` keeps the behind-window `NSVisualEffectView` and replaces the fixed gradient with three soft `RadialGradient` fields (end radius 520), one code path on macOS 14 and later:

| Field | Colour | Centre (unit point) |
| --- | --- | --- |
| Cool | mint, opacity 0.10 | (0.15, 0.10) |
| Depth | blue, opacity 0.06 | (0.90, 0.95) |
| Heat | `thermalColor(applied)`, opacity `0.05 + 0.09 * applied` | (0.62, 0.22) |

- **Change-driven with hysteresis.** The backdrop keeps an `applied` heat. On each new `breezeHeat` it computes the 0.05 step; it applies the new value when it differs from `applied` by 0.10 or more, or when the same different step has been pending for 10 s or more. A temperature hovering on a boundary therefore never retriggers the animation.
- The change animates with `ambient` (2.4 s) only while `breezeMotionLevel.isActive`. While off, the value is stored without animation, and it is applied without animation when the window becomes visible again.
- Fields do not move per page, there is no grain layer and no `MeshGradient`.
- Reduce Transparency or Increase Contrast: unchanged opaque `windowBackgroundColor` path, no fields. Reduce Motion: colour updates with the 0.16 s curve.
- **No Metal.** Nothing in this plan needs a shader; `scripts/build.sh` is untouched.

## 6. Choreography by surface

Priority: **signature** (the one), **core** (must ship), **polish** (ship if budget allows).

### Global / foundation (`BreezeMotion.swift`, `BreezeStyle.swift`, `system.md`)

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| foundation-motion-tokens | Section 3 tokens, `animation`, `animate`, `delay`, `firstTime`, `heat`, `thermalColor`, `nearest`; Typography; `system.md` Motion section with the five rules | Every token resolves to 0.16 s ease | Consistency | core |
| foundation-motion-scope | `breezeMotionScope()` and `BreezeMotionLevel` (section 4) | Always `.off` | All-day energy cost | core |
| foundation-thermal-aurora | Section 5 | Colour updates in 0.16 s | Ambient awareness of thermal headroom | core |
| foundation-airflow-canvas | `BreezeAirflow` and `BreezeFanGlyph` (section 2) | Frozen streaks at 60%, static glyph | The signature | signature |
| foundation-interaction-states | Animated `BreezeButtonStyle`, `.breezeCard` / `.breezeRow` / `.breezeTile`, `BreezeDisclosure` | No offset or scale; flat highlight | Feedback, affordance, keyboard parity | core |
| foundation-reveal-transitions | `breezeReveal(_:key:)`, four transitions, `BreezeSwitcher`, `BreezeDelayedProgress` | Opacity only, no delay | Hierarchy on first arrival, continuity between states | core |
| foundation-live-primitives | `breezeLive`, `breezeNumeric`, `BreezeCountUp`, `BreezeRing`, `BreezeMeter`, `breezePulse` | Opacity swap, final values, jumps in 0.16 s | A change is noticed; a readout stays readable | core |
| foundation-page-header | `BreezePageHeader`, `breezeScrollEdge` | Hairline appears in 0.16 s | One header rhythm; shows that content continues under it | core |
| foundation-chart-kit | `breezeChartDrawIn(key:)`, `breezeChartScrub`, `BreezeChartCallout` | Fade in; scrub unchanged | Read an exact historical value | core |

### Shell, Overview, Cooling, Settings (`Dashboard.swift`, `OverviewSummaryView.swift`, `CoolingControlsView.swift`)

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| shell-sidebar-selection | Keep `List(selection:)` `.sidebar` (native vibrancy, type-select, one focus stop, VoiceOver "row n of 9", macOS 26 glass). The selected row's icon switches to its filled variant with `.contentTransition(.symbolEffect(.replace))` and plays one `.symbolEffect(.bounce, value: model.page)`. Storage busy spinner uses `breezeFade`. Cmd-1 to Cmd-9 select pages through hidden, accessibility-hidden buttons with `.keyboardShortcut` in the Dashboard background | No bounce | Orientation without leaving the native sidebar | core |
| shell-page-transition | Dashboard root installs `breezeMotionScope()` and `breezeHeat`. `content` is wrapped in `BreezeSwitcher(model.page, index: sidebarIndex, axis: .vertical)` so all nine pages, including Overview, Cooling and Settings which share one branch, are keyed. New page rises 6 pt (down the sidebar) or drops 6 pt (up) with `hover` (0.26); old page fades in 0.20 s. No blur. `AppModel` untouched | 0.16 s crossfade | Continuity: content moves the way you moved in the nav | core |
| shell-header-notices | Shared branch uses `BreezePageHeader` with `breezeScrollEdge`; padding 26 becomes 28. Connection dot colour animates with `settle` and pulses once when control connects. Notices enter with `breezeDrop`, leave with `exit`; they are never staggered. Footer status text `.contentTransition(.opacity)`; busy spinner `breezeFade` | Fades | Errors and messages arrive clearly | core |
| shell-live-readouts | Sidebar footer: RPM `breezeLive`, status label crossfades, static symbol. Metric tiles: `breezeLive`; CPU and GPU tile icon tint follows `thermalColor` of that die with `settle`. Fan list: static `fanblades`, `BreezeMeter(fraction:marker:)` with the target RPM as the marker (moves with `drift`), RPM `breezeLive`, MANUAL/SYSTEM badge crossfades. No "Applied n%" pulse: the marker moving is the confirmation | Meters jump in 0.16 s | Target versus actual fan speed at a glance | core |
| overview-airflow-hero | Section 2, all four states, composed in `OverviewSummaryView` | Frozen streaks, static glyph, ring jumps; airflow hidden under Reduce Transparency or Increase Contrast | Fan effort and thermal headroom in one glance, on every Mac including fanless ones | signature |
| overview-load-choreography | First show per session only (`key: "overview"`): metric tiles and the hero card at index 0 with no delay (status and safety state never wait), thermal chart panel 1 with draw-in, destination cards 2 to 4, fan list 5. Under 0.9 s. On revisit the page transition is the only motion | All visible at once | Hierarchy: status first, detail after | core |
| overview-destination-cards | Three cards use `.buttonStyle(.breezeCard)`: y -2, shadow 6 to 12, 7% spotlight; `arrow.up.right` moves (2, -2) pt with `hover` on hover or focus. Click triggers the page transition | Flat highlight | These are doors to other pages | core |
| overview-thermal-chart | `temperatureChart` (Overview, Cooling, Statistics Thermal tab) and fan-speed history: `.interpolationMethod(.monotone)`, draw-in once per session, scrub callout "62°C · 14:03:22", Peak and Average `breezeLive`, range change animates the x domain with `settle` (user-caused), empty state `breezeFade`. New samples are not animated | Fade in; scrub unchanged | Exact temperature at any moment | core |
| cooling-editor-morph | Mode `Picker(.segmented)` stays native; mode content sits in `BreezeSwitcher(mode, index:)` and the panel height follows. Curve: Balanced/Performance morph the line with `glide` keyed on the preset; the orange live `RuleMark` and a `PointMark` riding the curve follow with `drift` scoped to those marks only (`.animation(_, value: liveTemp)` or `animation(_:body:)`), so point edits and drags stay 1:1. Point rows insert with `breezeDrop`, leave with `exit`. Scrub reads "58°C → 72%". No crossing pulse | Crossfade; marker jumps | See where the Mac sits on the curve now; understand a preset before applying | core |
| cooling-controls-feedback | Manual % and target °C numerals use `breezeLive()` and `.transaction { $0.animation = nil }` while the slider's `onEditingChanged` flag is true; target numeral tinted `thermalColor`. Preview RPM uses `breezeNumeric` after release. Preset cards `.buttonStyle(.breezeCard)` with a mint check that bounces once when staged. Timed boost row swaps picker+Start and countdown+End with `breezeFade`; countdown `.contentTransition(.numericText(countsDown: true))`; a 2 pt `BreezeMeter` drains along the row. Apply label crossfades to "Applying…" while busy | Opacity swaps | Confirmation that a setting was staged or took effect | core |
| settings-quiet-motion | Page transition only, no reveal. Helper status line crossfades with symbol replace; stepper value `breezeNumeric`; helper buttons swap with `breezeFade`; the conditional charge-limit note uses `breezeDrop` | Fades | Calm, legible state on a utility page | polish |

### Statistics (`ActivityView.swift`)

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| stats-tabs-and-state | `BreezePageHeader`; resource `Picker(.segmented)` stays native; tab content in `BreezeSwitcher(tab, index:)` with `settle`. Pause icon `.contentTransition(.symbolEffect(.replace))`. Paused: footer dot orange and still, charts at 60% saturation with `settle`. No per-sample pulse | Crossfade | Location within Statistics; live versus paused is unmistakable | core |
| stats-ring-and-bars | `ActivityRing` wraps `BreezeRing` (line 6), appears at its value, follows with `drift`; centre and legend values `breezeLive`; user/system bar and per-core bars follow with `drift` | Jump in 0.16 s | Load changes read as trends instead of flicker, numbers stay readable | core |
| stats-chart-draw-scrub | `historyChart`: monotone line, draw-in once per session per chart, header value `breezeLive`. One shared scrub date per tab: hovering any chart shows the rule and callout on every chart of that tab at the same instant; the tab's chart group is one focus stop with arrow-key stepping. The x domain does not slide between samples | Fade in | Exact values, and what else was happening at that moment | core |

`ActivityProcessesView.swift` is unowned and unchanged.

### Battery, Checkup, This Mac (`BatteryView.swift`, `Checkup.swift`, `MacInfoView.swift`)

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| battery-charge-vessel | Hero replaces the 58 pt symbol and `ProgressView` with a drawn vessel (132 x 58, cap) that appears at its value; fill follows with `drift`; a 2 pt tick marks the charge limit; percent `breezeLive` at `Typography.display`; mint to orange at 20% and below with `settle` (colour means charge only). A dashed 1.5 pt path flows into the vessel while charging and out while discharging at `8 + min(watts, 100) * 0.4` pt/s; it stops below 1 W in either direction. `TimelineView` at `level.interval(fps: 20)`, dash phase a pure function of integrated phase | Static vessel; static chevrons show direction | Charge level, limit and power direction in one look | core |
| battery-metrics-reveal | `BreezePageHeader`; loading to content: `BreezeDelayedProgress` then one `breezeFade`; metric tiles `breezeReveal(index, key: "battery")` and `breezeLive`; device rows `BreezeMeter` at value; refresh icon `.symbolEffect(.bounce, value: refreshCount)`; charge-limit control value `breezeNumeric` | Fades | No spinner flash; refresh acknowledged | polish |
| checkup-scan-sequence | Running: stethoscope `.symbolEffect(.variableColor.iterative, isActive: running && level.isActive)`. The verdict seal updates the moment results exist: symbol replace, scale 0.9 to 1 with `lift`, title crossfade. Under it, rows `breezeReveal(index, key: "checkup.<run id>")`; level icons `.transition(.symbolEffect(.drawOn))` under `#available(macOS 26, *)`, `.transition(.symbolEffect(.appear))` on 14 and 15; attention rows draw a 3 pt orange leading bar with `glide`. "Open …" buttons always visible. `BreezePageHeader` | Rows fade together; no scale | Verdict first, evidence right after | core |
| mac-info-reveal | `BreezePageHeader`; loading: `BreezeDelayedProgress` then `breezeFade`; groups `breezeReveal(index, key: "mac")`. No hero | Fades | Calm reference page | polish |

### Network (`NetworkView.swift`)

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| network-route-packets | Laptop, router and globe joined by a 1.5 pt path, drawn once per session (`xl`). `Canvas` packets (3 pt): download mint toward the laptop, upload blue away; emit interval `clamp(1.2 - log10(max(rate, 1)) * 0.18, 0.15, 1.2)` s, at most 12 dots, `level.interval(fps: 20)`, paused when both rates are under 1 KB/s or the level is off. Positions are a pure function of integrated phase, emit interval and index; nothing is appended to `@State`. Unreachable: router-to-globe segment turns orange and dashed with `settle`, packets stop at the router; status dot pulses once on a reachability change | Static line with coloured segments | Is traffic flowing, which way, where does it break | core |
| network-traffic-live | `BreezePageHeader`; tab `Picker(.segmented)` stays native with `BreezeSwitcher` content. 29 pt rates `breezeLive`, unit swaps without animation; traffic chart draws in once, monotone, scrub callout shows both directions; window change animates the domain with `settle` | Fades | Exact rates over time; location within Network | core |
| network-connectivity-strip | Bars keyed by probe date (trailing placeholders keyed by slot). Only a bar whose probe is newer than the strip's appearance grows from the baseline (`scaleEffect(y:anchor: .bottom)`, `settle`, local state); all others move without animation. The strip is one focus stop (`.focusable()` + `onKeyPress`); hover (`onContinuousHover` to index) or arrow keys lift the focused bar 2 pt and show a `BreezeChartCallout` with time and latency or "Probe failed". Existing help text kept. Latency, jitter and success `breezeLive` | Callout unchanged; no growth | Find the moment the connection dropped | core |
| network-speedtest-sequence | Results land with `BreezeCountUp` once per completed test; status caption crossfades per stage; Start/Cancel label crossfades; speedometer `.symbolEffect(.variableColor.iterative, isActive: testing && level.isActive)`; error label `breezeDrop` | Final values with fades | A long task feels alive; the result is the peak | polish |
| network-devices-scan | Scan progress `BreezeMeter`; device rows insert with `breezeDrop` as found (`settle` keyed on count); loading: `BreezeDelayedProgress`; empty list `breezeFade`; empty-state router symbol animates only while scanning and `level.isActive`; rows that are Buttons use `.breezeRow`; app rates `breezeLive` | Rows fade in | Discovery progress is visible as it happens | polish |

### Storage (`StorageView.swift`, `StorageOverviewView.swift`)

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| storage-workspace-switch | `BreezePageHeader`; workspace and Files-tab `Picker(.segmented)` stay native (disabled state kept); content in `BreezeSwitcher(workspace, index:)` with `settle`; message banner `breezeDrop`. The review sheet and `fileExporter` stay system-animated | Crossfade | Location inside Storage | core |
| storage-capacity-activity | 48 segments revealed by a leading mask once per session (`xl`, a static capacity). On drive switch the segments recolour with `settle` and free space rolls from the previous drive's value (`breezeNumeric`); no count-up. Orange state with `settle`. Volume rail: selection background moves with `matchedGeometryEffect` and `glide` only if the rail is a plain stack in one view (keep native selection if it is a `List`); rail meters `BreezeMeter` at value. Read/write chart draws in once and scrubs; rates `breezeLive`; health tiles `breezeReveal(index, key: "storage.health")` | Final values, fades | Free space is the headline; switching drives keeps context | core |
| storage-treemap-drill | Tiles keyed by `url`, the overflow tile by a stable id, placed with `.position`. Rect changes animate with `glide` keyed on the tile id set, so deletion and a finished rescan animate while window resize and a streaming scan do not. Drill-in: the button action stores the clicked rect in a reference box, then changes the folder; the new level (`.id(folder)`) is inserted scaled and offset from that rect to the full map with `glide`; labels fade in over the second half. Drill-up: the parent level is inserted zoomed in on the child's rect (from `StorageTreemap.layout`) and settles to identity; if either scale factor exceeds 8 it crossfades. The old level always leaves with `exit`. Breadcrumb chips `breezeDrop`; tiles `.buttonStyle(.breezeTile)`; map show/hide animates height with `glide` | Crossfade between levels | Never lose track of where a folder sits in the whole | core |
| storage-scan-and-rows | Scan panel `breezeDrop`; file count `breezeLive`; results show final values at once, `breezeReveal(index, key: "storage.scan.<scan id>")`; browser rows that are Buttons use `.breezeRow`, size bars `BreezeMeter`; checkbox `.contentTransition(.symbolEffect(.replace))`; footer selection total `breezeNumeric` | Fades | Scan progress and selection totals stay legible | polish |

### Cleanup journey (`StorageCleanupView.swift`, `StorageCleanupFlowView.swift`, `StorageCleanupAssistantView.swift`)

The four steps, their order, their actions and every approval rule in `system.md` are unchanged.

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| cleanup-journey-rail | Connector lines fill with mint from the leading edge (`glide`) as steps complete; step icons swap number to checkmark with symbol replace; a mint 12% capsule behind the current step moves with `matchedGeometryEffect` and `glide` (one view, one namespace); label weight with `settle` | Instant fill, crossfade | Where am I in Scan, Choose, Review, Finish | core |
| cleanup-step-morph | The step body (intro, results, review, activity, receipt) sits in `BreezeSwitcher(stepKey, index: stepIndex, token: .glide)`: forward enters from +24 pt trailing, back from leading, old step fades in 0.20 s. Intro icon, title and features `breezeReveal(0...3, key: "cleanup.intro")`. "Start scan" to activity is carried by the step transition alone; the activity panel has no insertion transition of its own | Crossfade | Forward and back read as one journey | core |
| cleanup-progress-assistant | Activity: icon symbol replace per phase and `.symbolEffect(.variableColor.iterative, isActive:)` while scanning (gated by level); removal `BreezeMeter` with "n of m" `breezeLive`; phase title crossfades; stage and path text update with no transition, copied into local `@State` by a 250 ms task loop (4 Hz); cancel label crossfades. Assistant: notices `breezeDrop`; sparkles animate only while the assistant runs and `level.isActive`; a new proposal banner draws a mint border once per proposal (trim 0 to 1, `l`); conversation lines append with `breezeDrop` | Fades; no border draw | Long work is visibly alive; a waiting proposal is noticed | core |
| cleanup-selection-ledger | Choose: category selection background moves with `matchedGeometryEffect` (source and destination in one view, not across the lazy stack); first eight rows `breezeReveal(index, key: "cleanup.results.<scan id>")`; checkbox symbol replace and mint row tint with `settle`; footer selected size `breezeNumeric`; Review button pulses once when the selection goes from empty to non-empty. Review: total `breezeNumeric`; a kept row leaves with `exit` and the group closes with `settle` (Choose and Review stay `LazyVStack`; a dropped off-screen removal is fine); readiness banner orange to mint with symbol replace; the destructive action fades to enabled after acknowledgement | Opacity swaps | Every choice visibly changes the total before anything is removed | core |
| cleanup-receipt-finish | Success only: the seal scales 0.6 to 1 with `lift` and one mint halo, alone, for 0.2 s (`.transition(.symbolEffect(.drawOn))` on macOS 26); then the title crossfades and result values `BreezeCountUp` to the receipt's reported counts while tiles and list fade in together with `enter`. Stopped or failures: orange icon with `settle`, no halo, no count-up. Selected bytes are never shown as freed space; no confetti | Final state with a 0.16 s fade | A clear, honest ending (peak-end) | core |

### Menu-bar widget (`BreezeWidgetView.swift`, `BreezeMenuBarController.swift`)

| ID | Behaviour | Reduce Motion | UX job | Priority |
| --- | --- | --- | --- | --- |
| widget-panel-open | AppKit only, `animationBehavior` stays `.none`. Open: set `alphaValue = 0` and the frame 4 pt above its final origin, order front, then one `NSAnimationContext` group over 0.15 s (0.22, 1, 0.36, 1) to alpha 1 and the final frame. No scale, no section stagger, no SwiftUI appear flag. Close: alpha to 0 over 0.10 s, then the existing teardown. A click during the fade finishes the teardown at once and reopens; `stop()` and quit tear down without animation; resizes during the open animation are deferred to its completion | Alpha only, 0.12 s | The panel belongs to the status item, and the reading is there immediately | core |
| widget-live-tiles | Tiles `breezeLive`; temperature tile tinted `thermalColor`; meters become `BreezeMeter` at value with `drift`; header fan symbol stays static; cooling status line crossfades with symbol replace; temperature chart has no draw-in and gets `breezeChartScrub`; boost countdown `.contentTransition(.numericText(countsDown: true))`; `WidgetButtonStyle` press scale 0.97 with `press`. No perpetual motion in the panel | Opacity swaps | Readable in a two-second glance | core |
| widget-menubar-fan-energy | Keep the cached-`CGImage` compose path (`drawLabel`), no `ImageRenderer` per frame. Timer interval 1/30 s at 1 visual rev/s or more, 1/15 s below. Stop the timer on `NSWorkspace.screensDidSleepNotification` and `willSleepNotification`, when the status-item window loses `.visible` occlusion, in Low Power Mode, while `model.sleeping`, and under Reduce Motion (existing). `updateFanAnimation` restarts it only when all of those are clear. Not gated on `NSApp.isActive` | Static icon (existing) | Fan activity at a glance at the lowest all-day cost | core |

Unowned files (`ActivityProcessesView`, `WidgetSettingsView`, `Alerts`, `CoolingAutomation`, `StorageMediaPreview`, `AppModel`, `BreezeApp`) are not edited. They inherit the animated button style and backdrop only. No model changes are needed: every motion state is view-local.

## 7. Energy rules

1. Perpetual motion exists in exactly five places: `BreezeAirflow`, the hero `BreezeFanGlyph`, the battery power-flow dash, network packets, the menu-bar fan. Caps: 30 fps (airflow, glyph, menu bar), 20 fps (dash, packets), all 10 fps while the main window is visible but Breeze is not the active app.
2. The four in-window effects read `breezeMotionLevel` and pause when it is `.off`: window occluded, miniaturized or hidden, screens asleep, Low Power Mode, Reduce Motion. The menu-bar fan has its own gates (section 6).
3. Each perpetual effect also stops at its own zero: under 1 RPM, both rates under 1 KB/s, under 1 W.
4. All four are stateless: a pure function of an integrated phase, advanced inside the timeline closure with a clamped `dt`. No per-frame `@State` writes.
5. Symbol effects with `isActive:` are tied to a real in-progress task and to `level.isActive`.
6. Live values move shapes on change; text does not animate. No chart slides its domain between samples. The backdrop has no loop and has hysteresis.
7. `breezePulse` fires on state changes only, never per sample.
8. No `repeatForever`, no blur, no `.drawingGroup()` on text.
9. Budget to check by hand in Activity Monitor (testing is left to the user): Overview at full fan speed should add no more than a few percent of one core over the current build; an occluded or miniaturized window should add nothing.

## 8. Accessibility rules

- Reduce Motion is honoured inside the foundation API: crossfades of 0.16 s, no offset, scale, stagger delay, particles, spinning, path draw or count-up.
- Reduce Transparency and Increase Contrast paths in `BreezeBackdrop`, `BreezeSurface`, `BreezeGlass` and `BreezeButtonStyle` are kept; the aurora and airflow are removed there.
- Keyboard parity: hover treatments exist only as button styles, which show the same state for focus plus a 2 pt mint ring. The sidebar and segmented pickers are native. Each chart group and the connectivity strip is a single focus stop operated with arrow keys. Hover never reveals information or controls that are otherwise hidden.
- No custom cursor. The only cursor-reactive effect is the 7% card spotlight.
- Decorative layers are `accessibilityHidden(true)`. `BreezeRing`, `BreezeMeter` and the battery vessel carry the label and value of the control they replace. `BreezeCountUp` exposes only its final value.
- Live text keeps `monospacedDigit()` so layouts never shift.
- Colour is never the only signal: thermal tint always sits beside a number or label; orange states keep their icon and text.
- Fan-safety semantics are untouched: heat boosts to 100%, 0% is the reported minimum, copy unchanged. Nothing is removed automatically; Review remains the only approval point.

## 9. Availability map

| API | Minimum | Note |
| --- | --- | --- |
| Springs, `Transition`, `phaseAnimator`, `numericText(value:)`, `symbolEffect` (bounce, variableColor, replace, appear), `SymbolEffectTransition`, scoped `animation(_:body:)`, `CoordinateSpaceProtocol.scrollView`, `ChartProxy.plotFrame`, `annotation(...overflowResolution:)`, `onKeyPress`, `geometryGroup` | macOS 14 | no gate |
| `onGeometryChange(for:of:action:)` single-value action, `onContinuousHover`, `chartOverlay` | macOS 13 | the (old, new) `onGeometryChange` overload is macOS 15 and is not used |
| `.transition(.symbolEffect(.drawOn))` | macOS 26 | `#available`; `.symbolEffect(.appear)` transition on 14 and 15 |
| `glassEffect`, `GlassEffectContainer` | macOS 26 | existing material path |
| `MeshGradient`, `TextRenderer`, `onScrollGeometryChange`, `chartXSelection`, Metal shaders | not used | n/a |

## 10. Awwwards rubric target

Scores are the creative director's estimates from reading the code, not jury results or measurements.

| Criterion | Weight | Before | Target | What moves it |
| --- | --- | --- | --- | --- |
| Design | 40% | 6.4 | 8.4 | Thermal aurora, unified type and 28 pt page rhythm, one hero per screen, drawn ring, vessel and route in place of stock symbols and progress bars |
| Usability | 30% | 7.4 | 8.9 | Directional transitions, readable live numbers, synchronized chart scrubbing with keyboard parity, target-versus-actual fan markers, visible journey progress, native sidebar and pickers, full Reduce Motion path |
| Creativity | 20% | 4.0 | 8.0 | Live Airflow bound to real RPM and heat with a designed fanless state, rate-bound packets, power-flow path, treemap drill-in |
| Content | 10% | 7.0 | 7.6 | Same honest copy; exact values on hover; hero states named in words |
| Weighted | | 6.3 | 8.4 | |

Build order: `foundation` first (section 4 must compile on its own), then `shell`, `statistics`, `battery`, `network`, `storage`, `cleanup`, `widget` in parallel. `README.md` and `BreezeApp.swift` are outside every builder's file list; if the orchestrator wants the energy behaviour documented or the Cmd-1 to Cmd-9 shortcuts listed in a View menu, assign that explicitly.

## 11. Critique decisions

All 30 required changes from the UX review are applied. Where this spec differs from the letter of the review, it goes further in the same direction, for the reason given.

| Review item | Decision | Why it is better for the user |
| --- | --- | --- |
| 1 once per session | Applied as `firstTime(key)` with next-turn insertion, so a whole stagger group shares one key | A consuming check would let only the first sibling animate |
| 2 live versus rolling | Applied: `breezeLive` and `breezeNumeric`; the hero RPM is the only rolling live value | Monitoring text stays readable |
| 3 draw from 0 | Stricter: rings, meters and the vessel never draw in, static values included. Only the 48-segment capacity bar, charts and the route path draw, once per session | One rule with no exceptions to misapply; no reading ever passes through a false value |
| 5 per-window gate | Applied for the main window, with the optional 10 fps level for a visible but inactive window. The widget header glyph is cut, so the panel has no perpetual motion and needs no gate | The menu-bar fan spins directly above the panel; a second fan there adds nothing to a two-second glance |
| 6, 19, 25 transition mechanics | Applied through one `BreezeSwitcher`. Differs on one point: removals are opacity-only (the review kept an 8 pt exit offset). Treemap drill-up is a zoom-out insertion of the parent | SwiftUI plays the removal transition captured at last render, so a directional exit can play the wrong direction. Insertion-only direction cannot |
| 7 sidebar | Confirmed: keep `List(.sidebar)`; symbol swap, one bounce, Cmd-1 to Cmd-9 | Native selection, type-select, VoiceOver and macOS 26 glass outweigh a gliding pill |
| 8 kinetic title and compaction | Per-glyph and line-rise titles cut. Compaction is replaced by a scroll-edge hairline instead of being fixed with hysteresis | Compaction moves content under the pointer mid-scroll to save about 34 pt; the hairline is the macOS scroll-edge pattern and changes no layout |
| 9 hover | Tilt and scale cut. Hover exists only as `ButtonStyle`s; non-interactive rows get none | Focus parity is real only where `isFocused` is readable; highlighting rows that do nothing suggests they are clickable |
| 10 scroll reveal | Cut everywhere | As reviewed |
| 12, 13 hero | Sidebar and fan-list glyphs cut; four explicit hero states including fanless and still air | As reviewed |
| 15 aurora | Hysteresis added; per-page anchor, grain and `MeshGradient` all cut | With a fixed heat field the mesh adds a second code path for no visible gain at 5 to 14% opacity |
| 18 free space | Rolls from the previous drive's value; no count-up | As reviewed |
| 20 connectivity strip | Keyed by probe date; only probes newer than the strip's appearance grow | Avoids 120 bars growing on first show |
| 21 packets and dash | Stateless, 20 fps, 1 W floor | As reviewed |
| 22 widget | Open and close are pure AppKit (alpha plus a 4 pt frame move) | No dependence on `onAppear` timing in a freshly created hosting view |
| 23 menu-bar fan | Gates applied. The draft's angular-velocity easing is dropped | A speed step on a 16 pt icon is invisible; the gates are what matter |
| 26 count-up | Only speed test and receipt, final value for VoiceOver | As reviewed |
| 28 segmented picker | Stricter: the custom control is cut on every OS; `Picker(.segmented)` stays | A custom control only for macOS 14 and 15 is a second path to keep accessible; `BreezeSwitcher` already shows which way content moves |
| 29 gaps | Applied: `BreezeDelayedProgress`, fade-only empty states, system sheets, resize rule | As reviewed |
| 30 `system.md` | Five rules written in section 1 for the Motion section; `exitFactor` removed | As reviewed |
| Not verified in review: `chartXSelection` hover | Scrubbing uses `chartOverlay` + `onContinuousHover` instead | Hover behaviour is deterministic; no reliance on an undocumented default gesture |
| Optional: status title interpolate, receipt hold, 10 fps inactive level, drop grain | Taken | |
| Optional: synchronized chart focus | Taken as one shared scrub date per Statistics tab; the "Show values" menu command is not added | One focus stop and a real reading gain; a menu command needs an unowned file |
| Optional: battery vessel thermal tint | Declined | The vessel's colour already means low charge; a second meaning on the same channel is ambiguous |

Items 4, 11, 14, 16, 17, 24 and 27 are applied exactly as reviewed (see the matching rows in section 6).
