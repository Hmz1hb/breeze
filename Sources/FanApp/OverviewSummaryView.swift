import FanCore
import SwiftUI

struct OverviewSummaryView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                ZStack {
                    Circle().stroke(BreezeStyle.mint.opacity(0.12), lineWidth: 9)
                    Circle().trim(from: 0, to: fanFraction)
                        .stroke(BreezeStyle.mint.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 6) {
                        Image(systemName: "fanblades.fill").font(.system(size: 28, weight: .light)).foregroundStyle(BreezeStyle.mint)
                        Text(model.rpmLabel).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("RPM").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    }
                }.frame(width: 124, height: 124)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Fastest fan \(model.rpmLabel) RPM")
                VStack(alignment: .leading, spacing: 9) {
                    Label("LIVE FROM YOUR MAC", systemImage: "waveform.path")
                        .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(BreezeStyle.mint)
                    Text(model.statusTitle).font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text(model.statusDetail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Tune cooling", systemImage: "slider.horizontal.3") { model.page = .cooling }
                            .breezeAction(prominent: true)
                        Menu {
                            ForEach([1, 5, 10, 15, 30], id: \.self) { minutes in
                                Button("\(minutes) minute\(minutes == 1 ? "" : "s")") { Task { await model.startTimedBoost(minutes: minutes) } }
                            }
                        } label: { Label("Timed boost", systemImage: "timer") }
                            .fixedSize().breezeAction().disabled(model.busy || model.snapshot?.canControl != true)
                    }.padding(.top, 3)
                    if let remaining = model.boostRemaining {
                        Text("Boost ends in \(remaining) · then macOS takes over").font(.caption).foregroundStyle(BreezeStyle.mint)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                fact("THERMAL PRESSURE", value: model.snapshot?.thermalPressure.capitalized ?? "Unavailable", symbol: "thermometer.medium")
                fact("DIE SENSORS", value: model.snapshot.map { "\($0.temperatures.count) reporting" } ?? "Unavailable", symbol: "sensor")
                fact("HEAT BOOST", value: "\(Int(model.configuration.boostTemperature))°C in editor", symbol: "bolt.shield")
            }
        }.padding(24).breezeSurface()
    }
    private var fanFraction: Double {
        guard let fans = model.snapshot?.fans, let fan = fans.max(by: { $0.current < $1.current }), fan.maximum > 0 else { return 0 }
        return min(1, max(0, fan.current / fan.maximum))
    }
    private func fact(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
            Label(value, systemImage: symbol).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
