import FanCore
import SwiftUI

/// The Overview hero: Live Airflow (motion.md section 2) in four designed states.
struct OverviewSummaryView: View {
    @Bindable var model: AppModel
    @State private var boosts = 0

    private enum HeroState { case noReading, passive, still, moving }

    var body: some View {
        let state = heroState
        let heat = BreezeMotion.heat(temperature: model.snapshot?.hottest, boost: model.configuration.boostTemperature)
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                ring(state, heat: heat)
                VStack(alignment: .leading, spacing: 9) {
                    Label(eyebrow(state), systemImage: "waveform.path")
                        .font(BreezeStyle.Typography.eyebrow).tracking(BreezeStyle.Typography.eyebrowTracking)
                        .foregroundStyle(state == .noReading ? Color.secondary : BreezeStyle.mint)
                    Text(model.statusTitle).font(.system(size: 27, weight: .semibold, design: .rounded))
                        .contentTransition(.interpolate)
                        .breezeAnimation(.settle, value: model.statusTitle)
                    Text(model.statusDetail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .breezeAnimation(.settle, value: model.statusDetail)
                    HStack(spacing: 10) {
                        Button("Tune cooling", systemImage: "slider.horizontal.3") { model.page = .cooling }
                            .breezeAction(prominent: true)
                        Menu {
                            ForEach([1, 5, 10, 15, 30], id: \.self) { minutes in
                                Button("\(minutes) minute\(minutes == 1 ? "" : "s")") {
                                    Task {
                                        await model.startTimedBoost(minutes: minutes)
                                        BoostSpan.record(model.boostEndsAt, minutes: minutes)
                                    }
                                }
                            }
                        } label: { Label("Timed boost", systemImage: "timer") }
                            .fixedSize().breezeAction().disabled(model.busy || model.snapshot?.canControl != true)
                    }.padding(.top, 3)
                    if let remaining = model.boostRemaining {
                        Text("Boost ends in \(remaining) · then macOS takes over").font(.caption).foregroundStyle(BreezeStyle.mint)
                            .breezeLive()
                            .transition(.breezeDrop)
                    }
                }
                .breezeAnimation(.settle, value: model.boostEndsAt != nil)
                Spacer(minLength: 0)
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                fact("THERMAL PRESSURE", value: model.snapshot?.thermalPressure.capitalized ?? "Unavailable", symbol: "thermometer.medium")
                fact("DIE SENSORS", value: model.snapshot.map { "\($0.temperatures.count) reporting" } ?? "Unavailable", symbol: "sensor")
                fact("HEAT BOOST", value: "\(Int(model.configuration.boostTemperature))°C in editor", symbol: "bolt.shield")
            }
        }
        .padding(24)
        .background { backdrop(state, heat: heat) }
        .breezeSurface()
        .onChange(of: model.boosted) { _, boosted in if boosted { boosts += 1 } }
    }

    private var heroState: HeroState {
        guard let snapshot = model.snapshot else { return .noReading }
        if snapshot.fans.isEmpty { return .passive }
        return fastestRPM < 1 ? .still : .moving
    }
    private var fastestRPM: Double { model.snapshot?.fans.map(\.current).max() ?? 0 }
    private var fanFraction: Double {
        guard let fans = model.snapshot?.fans, let fan = fans.max(by: { $0.current < $1.current }), fan.maximum > 0 else { return 0 }
        return min(1, max(0, fan.current / fan.maximum))
    }
    private func eyebrow(_ state: HeroState) -> String {
        switch state {
        case .passive: "PASSIVE COOLING · NO FANS"
        case .still: "STILL AIR · FANS AT REST"
        case .noReading, .moving: "LIVE FROM YOUR MAC"
        }
    }

    private func ring(_ state: HeroState, heat: Double) -> some View {
        let thermal = BreezeMotion.thermalColor(heat)
        let hottest = model.snapshot?.hottest
        let numeral = Font.system(size: 22, weight: .medium, design: .rounded)
        let caption = Font.system(size: 9, weight: .medium)
        return ZStack {
            BreezeRing(fraction: state == .passive ? heat : state == .moving ? fanFraction : 0,
                       tint: state == .passive ? thermal : BreezeStyle.mint, endTint: thermal)
            VStack(spacing: 6) {
                switch state {
                case .noReading:
                    Text("—").font(numeral).foregroundStyle(.secondary)
                case .passive:
                    Image(systemName: "thermometer.medium").font(.system(size: 28, weight: .light)).foregroundStyle(thermal)
                    Text(hottest.map { "\(Int($0))°C" } ?? "—").font(numeral).breezeLive()
                    Text("HOTTEST").font(caption).foregroundStyle(.secondary)
                case .still, .moving:
                    BreezeFanGlyph(rpm: fastestRPM, size: 28)
                    Text(model.rpmLabel).font(numeral).breezeNumeric(fastestRPM)
                    Text("RPM").font(caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 124, height: 124)
        .breezePulse(trigger: boosts, tint: .orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state == .passive
            ? "Hottest sensor \(Int(hottest ?? 0))°C, \(Int(heat * 100)) percent of the way to heat boost"
            : "Fastest fan \(model.rpmLabel) RPM")
    }

    /// Airflow (moving, or frozen when still) masked from the ring edge, or a thermal wash on a fanless Mac.
    private func backdrop(_ state: HeroState, heat: Double) -> some View {
        GeometryReader { geo in
            // 24 pt card padding + 124 pt ring; the ring's centre sits at (86, 86).
            let edge = min(148 / max(geo.size.width, 1), 0.6)
            switch state {
            case .moving, .still:
                BreezeAirflow(speed: state == .moving ? fanFraction : 0, heat: heat)
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: edge),
                        .init(color: .black.opacity(0.5), location: min(edge + 0.12, 0.7)),
                        .init(color: .clear, location: 0.72)
                    ], startPoint: .leading, endPoint: .trailing))
            case .passive:
                RadialGradient(colors: [BreezeMotion.thermalColor(heat).opacity(0.08), .clear],
                               center: UnitPoint(x: 86 / max(geo.size.width, 1), y: 86 / max(geo.size.height, 1)),
                               startRadius: 0, endRadius: 180)
            case .noReading:
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fact(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
            Label(value, systemImage: symbol).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
