import AppKit
import AVFoundation
import AVKit
import Observation
import StorageCore
import SwiftUI

@MainActor @Observable
final class StorageMediaPlayback {
    let player = AVPlayer()
    private(set) var loading = false
    private(set) var error: String?
    private var asset: AVURLAsset?
    private var statusObservation: NSKeyValueObservation?
    private var loadID = UUID()

    func load(_ url: URL) async {
        stop()
        let id = loadID
        loading = true
        let asset = AVURLAsset(url: url)
        self.asset = asset
        do {
            let playable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard id == loadID else { return }
            guard playable else { throw StorageError("This file's media format isn't supported by macOS playback.") }
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.loadID == id, self.player.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay: self.loading = false
                    case .failed:
                        self.loading = false
                        self.error = item.error?.localizedDescription ?? "This file couldn't be played."
                    default: break
                    }
                }
            }
        } catch is CancellationError {
            if id == loadID { stop() }
        } catch {
            guard id == loadID, !Task.isCancelled else { return }
            loading = false
            self.error = error.localizedDescription
        }
    }

    func stop() {
        loadID = UUID()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        asset?.cancelLoading()
        asset = nil
        loading = false
        error = nil
    }
}

struct StorageContentPreview: View {
    let file: StorageFile

    var body: some View {
        if file.category == .video || file.category == .audio {
            StorageMediaPreview(url: file.url)
        } else {
            StorageQuickLook(url: file.url)
        }
    }
}

private struct StorageMediaPreview: View {
    let url: URL
    @State private var playback = StorageMediaPlayback()

    var body: some View {
        ZStack {
            Color.black
            StoragePlayerView(player: playback.player)
            if let error = playback.error {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash").font(.largeTitle)
                    Text("Unable to play this file").font(.headline)
                    Text(error).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                    Button("Open in default app") { NSWorkspace.shared.open(url) }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            } else if playback.loading {
                ProgressView("Loading media…").padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task(id: url) { await playback.load(url) }
        .onDisappear { playback.stop() }
    }
}

private struct StoragePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
