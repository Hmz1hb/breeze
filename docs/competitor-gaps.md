# Breeze: feature inventory and competitor gaps (November 2026)

## Part 1: What Breeze does today

**Fan control** (root helper through SMAppService, authenticated socket)
- Modes: Automatic, Maximum, Fixed %, Custom curve (2–12 points), Target temperature (feedback controller)
- Presets: Quiet, Balanced and Performance. Up to 24 saved profiles. The last applied profile can be applied at launch.
- Timed boost for 1, 5, 10, 15 or 30 minutes, from Overview, Cooling and the menu bar
- Automatic switching rules (up to 24): by running app, on battery, on AC, or a time window (can cross midnight)
- Heat boost to 100% at a threshold, under serious/critical thermal pressure, or on sensor loss. Firmware readback is verified. Automatic is restored on quit, disconnect or watchdog timeout. Resumes after wake.
- Thermal history for 2, 5 or 10 minutes, with CSV export

**Statistics:** CPU (user/system/idle, per core, load averages, E/P cluster frequency and residency, power); GPU (each accelerator, utilization, power, frequency); CPU/ANE/DRAM power through the helper; memory composition, pressure and swap; process table (sort and search); thermal sensors and raw SMC keys; Pause/Resume.

**Menu bar and widgets**
- Menu bar readings: temperature, fan RPM, CPU, GPU and memory, or the fan icon alone
- Menu widget in Simple or Detailed layout, with each section switchable and a live preview
- WidgetKit desktop widgets: small and medium

**Battery:** health, capacity, cycles, identity, temperature/voltage/current/power; charger details; power flow (adapter input vs battery). Charge limit 50–100% with a sailing range and heat protection. Bluetooth device batteries, including AirPods left/right/case and Logitech HID++.

**Network:** live rates and traces; full interface and Wi-Fi details; `networkQuality` speed test; TCP latency ribbon with jitter; public IP and country; per-app traffic (current session); LAN device discovery (ICMP, ARP, Bonjour, categories, custom names).

**Storage**
- Disk overview: volumes, read/write activity, APFS details, NVMe SMART
- Folder explorer: thumbnails, Quick Look and media player, treemap, SHA-256 duplicate finder, "worth reviewing" cues
- Cleanup catalog (Scan → Choose → Review → Finish), Trash only: developer caches (around 25 tools), project build folders, Xcode, Android AVDs and images, Downloads installers and duplicates, AI models (Ollama, Hugging Face, LM Studio), app uninstaller with leftovers, Docker images and build cache
- Detects blocking processes and quits them gracefully
- AI cleanup through the user's own Claude Code or Codex CLI, using the bundled BreezeMCP server

**Other:** Checkup health report (Markdown export); alerts (sustained temperature, low disk, battery temperature, SSD wear, network down); This Mac hardware page; Liquid Glass UI; ⌘1–9 navigation; launch flags.

**Not present in the code** (checked by grep): Shortcuts/App Intents, AppleScript, iCloud sync, an auto-updater, localization (English only), and choosing which sensor drives a fan (curves follow the hottest die only).

---

## Part 2: Competitor gaps

Apps reviewed:
- Fan/monitor: Macs Fan Control, TG Pro, iStat Menus 7, Stats, iStatistica Pro, Sensei, MenuMeters, Hot
- Storage/cleanup: CleanMyMac, DaisyDisk, OnyX, Pearcleaner, AppCleaner, DevCleaner, GrandPerspective, Nektony MacCleaner/App Cleaner, Mole, Gemini 2
- Battery/network: AlDente, Battery Toolkit, batt, coconutBattery, Battery Monitor, Little Snitch, TripMode, Fing, LanScan, WiFi Explorer, NetSpot, Radio Silence

The number after each gap is how many of those apps have it.

### A. Cooling and monitoring
| Gap | Who has it | # |
|---|---|---|
| Fan follows a **chosen sensor** (GPU, SSD, external drive), or per-sensor boost rules | Macs Fan Control, TG Pro, iStat | 3 |
| **History saved to disk** (24 hours to 28 days, or continuous CSV logging) | iStat, Stats, TG Pro | 3 |
| **Separate menu bar item per module**, or a combined item, plus **network and battery readings in the menu bar** | iStat, Stats, MenuMeters, Sensei | 4 |
| **Alerts on more metrics** (CPU %, memory, network, public IP change), plus alert actions (email, run a script) | iStat, iStatistica, TG Pro | 3 |
| **Localized UI** (Stats supports 37 languages) | Macs Fan Control, Stats | 2 |
| Remote monitoring (web dashboard or REST API) | iStatistica, Stats | 2 |
| External/third-party drive temperatures (SMART) | Macs Fan Control, TG Pro | 2 |
| Clock/world-time, weather and calendar modules | iStat, Stats | 2 |
| Disk I/O per app; CPU/memory history per app | iStat, iStatistica | 2 |
| Menu themes, widget editor | iStat, Sensei | 2 |
| Last shutdown/sleep cause, maximum recorded value per sensor | TG Pro | 1 |
| Command-line/MDM deployment, Homebrew cask | TG Pro | 1 |
| Disk speed benchmark, TRIM switch | Sensei | 1 |
| Intel / Boot Camp support | 7 apps | Out of scope (Apple silicon only) |

### B. Battery
| Gap | Who has it | # |
|---|---|---|
| **Force discharge while plugged in** (turn off the adapter) | AlDente, Battery Toolkit, batt | 3 |
| **Top Up / charge once to 100%** without changing the limit | AlDente, Battery Toolkit, batt | 3 |
| **Sleep handling:** stop charging before sleep, block sleep until the limit is reached | AlDente, Battery Toolkit, batt | 3 |
| Limit keeps working **after the app quits** (daemon or firmware) ⚠️ | AlDente, Battery Toolkit, batt | 3 |
| **Battery health history** (capacity and cycles over months) | coconutBattery, Battery Monitor, AlDente | 3 |
| Calibration mode (charge → discharge → charge), can be scheduled | AlDente, batt | 2 |
| MagSafe LED shows charge state | AlDente, batt | 2 |
| Battery level alerts (percentage or time left) | coconutBattery, Battery Monitor | 2 |
| Low Power Mode switched by power source; Shortcuts actions; apps using significant energy | AlDente | 1 |
| iPhone/iPad battery health over USB or Wi-Fi | coconutBattery | 1 |

⚠️ Breeze deliberately turns charging back on when its session ends, as a safety guarantee. A persistent limit would change that guarantee. Also, macOS 26.4+ has its own 80–100% limit, so the 50–79% range, discharge and sleep handling are where Breeze can stand out.

### C. Network
| Gap | Who has it | # |
|---|---|---|
| **Per-app firewall / block** | Little Snitch, TripMode, Radio Silence | 3 |
| **Saved usage history** (per app, by day, month or year) | Little Snitch, TripMode, iStat | 3 |
| **Nearby Wi-Fi scanner** and channel congestion graph | WiFi Explorer, NetSpot, Wireless Diagnostics | 3 |
| Speed-test history, or scheduled tests | Fing, NetSpot | 2 |
| New-device / intruder alerts, device join/leave timeline | Fing | 1 |
| Open-port scan of a LAN device; MAC vendor lookup | Fing, LanScan | 1–2 |
| Data caps for metered or hotspot networks | TripMode | 1 |
| Public IP change alert | iStat | 1 |
| Traceroute and DNS check | Fing | 1 |

### D. Storage and cleanup
| Gap | Who has it | # |
|---|---|---|
| **Login items / launch agents / daemons manager** | CleanMyMac, Nektony, Pearcleaner, Mole, Sensei | 5 |
| **App updater** (App Store, Sparkle, Homebrew) | CleanMyMac, Nektony, Pearcleaner, Mole | 4 |
| **Leftovers of apps already deleted** | Nektony, Pearcleaner, Mole, CleanMyMac | 4 |
| **Maintenance actions** (reindex Spotlight, flush DNS, rebuild LaunchServices, reset Quick Look) | CleanMyMac, OnyX, Mole, Nektony | 4 |
| **Time Machine local / APFS snapshot management** (purgeable space) | DaisyDisk, Mole, CleanMyMac | 3 |
| Whole-disk scan with admin rights and a **System Data breakdown** | DaisyDisk, CleanMyMac, Gemini | 3 |
| **Similar (not identical) photos** | CleanMyMac, Gemini, Nektony | 3 |
| Unused language/localization removal | CleanMyMac, Nektony, Pearcleaner | 3 |
| App permission review | CleanMyMac, Nektony, Mole | 3 |
| Saved scans / growth since last scan / cleanup history | GrandPerspective, Mole, CleanMyMac | 3 |
| Strip unneeded architectures from universal apps (lipo) | Pearcleaner, Mole | 2 |
| Mail attachments, Trash on external drives | CleanMyMac, Nektony | 2 |
| Extensions, plugins and default-app manager | Nektony, Pearcleaner | 2 |
| Auto-uninstall when an app is dropped in the Trash; background duplicate watcher | Pearcleaner, Gemini | 2 |
| CLI / JSON / dry-run automation | Mole, Pearcleaner | 2 |
| Cloud drive analysis (iCloud, Dropbox and others) | CleanMyMac, DaisyDisk | 2 |
| Xcode documentation cache, old simulator and device logs | DevCleaner | 1 |
| Old macOS installers, Parallels disk reclaim | Mole | 1 |
| Malware scan, browser privacy cleanup | CleanMyMac | 1 |

---

## Part 3: Suggested shortlist (best fit for Breeze's current architecture)

These reuse what Breeze already has, ranked by competitor coverage relative to effort:
1. **Fan source by sensor:** extend `Cooling` and its profiles in FanCore to pick a sensor, which the helper already reads.
2. **Network and battery in the menu bar, plus a separate menu bar item per module:** extend `BreezeMenuBarController` and `WidgetPreferences`.
3. **Leftovers of deleted apps, Xcode docs/logs, old macOS installers, Time Machine local snapshots:** new categories in the StorageCore `Cleanup*` catalog. They fit Scan→Choose→Review→Finish.
4. **Login items / launch agents viewer** (read-only first): a new StorageCore inventory.
5. **Persistent history** (thermal, battery capacity, network usage per day): small on-disk rollups. Today all history is in memory for the session only.
6. **Battery: Top Up, force discharge, stop charging during sleep:** helper `.charge` command extensions (SMC keys such as `CH0I`/`CHIE`). Requires deciding how this fits the "re-enable on session end" guarantee.
7. **Shortcuts (App Intents):** apply profile, timed boost, charge limit. No competitor in cooling has these, so they would set Breeze apart.
8. **Localization:** English only today.

Probably not worth chasing: Intel support (contradicts the product scope), a malware scanner, a full firewall (needs a Network Extension), weather or calendar modules, and Wi-Fi heatmaps.

## Report notes
- Competitor claims are marked verified (official page) or inferred in the agent notes. Re-check prices before quoting: the official pages for Macs Fan Control, iStat Menus, Sensei and NetSpot don't show them.
- The Breeze feature list comes from `README.md` and a grep for Shortcuts, iCloud, updater, localization and sensor-selection code. It was not checked at runtime.
