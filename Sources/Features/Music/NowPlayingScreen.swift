import SwiftUI
import MusicKit

/// Classic Now Playing: big artwork, track info, progress bar; wheel adjusts
/// volume (with a transient volume bar), center toggles play/pause. Transport
/// buttons are handled globally.
struct NowPlayingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var volumeFlash = false

    private var player: PlayerModel { model.player }
    private var song: Song? { player.currentSong }

    var body: some View {
        VStack(spacing: 0) {
            artwork
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

            VStack(spacing: 2) {
                Text(song?.title ?? "Not Playing")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(song?.artistName ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
                    .lineLimit(1)
                Text(song?.albumTitle ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.inkDim.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.top, 4)

            Spacer(minLength: 0)

            if volumeFlash {
                volumeBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else {
                progressBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .onWheel { handle($0) }
    }

    // MARK: Pieces

    @ViewBuilder
    private var artwork: some View {
        if let aw = song?.artwork {
            ArtworkView(artwork: aw, width: 260, height: 260)
                .frame(width: screenArtSize, height: screenArtSize)
                .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.85))
                .frame(width: screenArtSize, height: screenArtSize)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.inkDim)
                )
        }
    }

    private var screenArtSize: CGFloat { 118 }

    private var progressBar: some View {
        GeometryReader { geo in
            let progress = player.duration > 0 ? player.playbackTime / player.duration : 0
            VStack(spacing: 1) {
                HStack {
                    Text(TimeFormat.mss(player.playbackTime))
                        .monospacedDigit()
                    Spacer()
                    Text(player.isPlaying ? "-\(TimeFormat.mss(max(0, player.duration - player.playbackTime)))" : TimeFormat.mss(player.duration))
                        .monospacedDigit()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.inkDim)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.22))
                        .frame(height: 7)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.selMid, Theme.selTop],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * progress), height: 7)
                }
            }
        }
        .frame(height: 26)
    }

    private var volumeBar: some View {
        GeometryReader { geo in
            VStack(spacing: 1) {
                HStack {
                    Image(systemName: "speaker.fill").font(.system(size: 10))
                    Spacer()
                    Text("\(Int(player.volume * 100))")
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.inkDim)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.22))
                        .frame(height: 7)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.selMid, Theme.selTop],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * player.volume), height: 7)
                }
            }
        }
        .frame(height: 26)
    }

    // MARK: Input

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            player.bumpVolume(Double(d) * model.settings.volumeStep)
            withAnimation(.easeOut(duration: 0.15)) { volumeFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeIn(duration: 0.3)) { volumeFlash = false }
            }
        case .select:
            player.togglePlayPause()
        case .menu:
            model.pop()
        default:
            break
        }
    }
}
