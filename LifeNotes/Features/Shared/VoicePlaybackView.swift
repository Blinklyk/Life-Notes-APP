import SwiftUI

struct VoicePlaybackView: View {
    @ObservedObject var appModel: AppModel
    let voiceID: UUID
    let relativePath: String
    let durationMilliseconds: Int

    private var isCurrentVoice: Bool {
        appModel.playbackVoiceID == voiceID
    }

    private var isPlaying: Bool {
        isCurrentVoice && appModel.isVoicePlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await appModel.toggleVoicePlayback(
                        id: voiceID,
                        relativePath: relativePath
                    )
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!appModel.canUseVoicePlayback)
            .accessibilityLabel(isPlaying ? "暂停录音" : "播放录音")
            .accessibilityValue(
                VoiceFormatting.accessibleDuration(
                    milliseconds: durationMilliseconds
                )
            )
            .help(isPlaying ? "暂停" : "播放")

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(
                    value: isCurrentVoice ? appModel.voicePlaybackProgress : 0
                )
                .tint(AppTheme.accent)

                Text(VoiceFormatting.duration(milliseconds: durationMilliseconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
