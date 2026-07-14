import SwiftUI
import UIKit

struct VoiceCaptureSection: View {
    enum Style {
        case entry
        case photoAnnotation
    }

    @ObservedObject var appModel: AppModel
    let targetPhotoID: UUID?
    let style: Style

    init(
        appModel: AppModel,
        targetPhotoID: UUID? = nil,
        style: Style = .entry
    ) {
        self.appModel = appModel
        self.targetPhotoID = targetPhotoID
        self.style = style
    }

    var body: some View {
        Group {
            if let draftVoice = appModel.draftVoice(forPhotoID: targetPhotoID) {
                voiceCard(draftVoice)
            } else {
                addVoiceButton
            }
        }
        .padding(.top, style == .entry ? 12 : 4)
        .onChange(
            of: appModel.draftVoice(forPhotoID: targetPhotoID)?.capturePhase
        ) { oldPhase, newPhase in
            announceRecordingTransition(from: oldPhase, to: newPhase)
        }
    }

    private var addVoiceButton: some View {
        Button {
            Task {
                await appModel.startVoiceRecording(targetPhotoID: targetPhotoID)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(style == .entry ? .title3.weight(.semibold) : .callout.weight(.semibold))
                    .accessibilityHidden(true)
                Text(style == .entry ? "录一段语音" : "添加语音批注")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 12)
                Image(systemName: "plus")
                    .font(.callout.bold())
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: style == .entry ? 48 : 44)
            .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!appModel.canAddVoice(targetPhotoID: targetPhotoID))
        .accessibilityLabel(style == .entry ? "开始录音" : "添加语音批注")
    }

    @ViewBuilder
    private func voiceCard(_ voice: AppModel.DraftVoice) -> some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(
                    style == .entry ? "语音" : "语音批注",
                    systemImage: "waveform"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.sage)
                Spacer(minLength: 12)
                Button {
                    appModel.removeDraftVoice(id: voice.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedInk)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(isFinalizing(voice))
                .accessibilityLabel("移除语音")
                .help("移除语音")
            }

            captureContent(voice)
        }

        if style == .entry {
            content
                .padding(14)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.divider.opacity(0.55), lineWidth: 1)
                }
                .accessibilityElement(children: .contain)
        } else {
            content
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func captureContent(_ voice: AppModel.DraftVoice) -> some View {
        switch voice.capturePhase {
        case .preparing:
            ProgressView("正在准备麦克风")
                .frame(maxWidth: .infinity, alignment: .leading)

        case .recording:
            recordingControls(voiceID: voice.id, isPaused: false)

        case .paused:
            recordingControls(voiceID: voice.id, isPaused: true)

        case .finalizing:
            ProgressView("正在保存录音")
                .frame(maxWidth: .infinity, alignment: .leading)

        case .failed:
            Label("录音文件无法读取，请移除后重新录制", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(AppTheme.mutedInk)

        case let .ready(audio):
            readyContent(voice: voice, audio: audio)
        }
    }

    private func recordingControls(voiceID: UUID, isPaused: Bool) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isPaused ? AppTheme.sage : Color.red)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(isPaused ? "已暂停" : "录音中")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPaused ? AppTheme.sage : Color.red)

                Text(
                    VoiceFormatting.duration(
                        milliseconds: appModel.voiceElapsedMilliseconds
                    )
                )
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(isPaused ? "录音已暂停" : "正在录音")，\(VoiceFormatting.accessibleDuration(milliseconds: appModel.voiceElapsedMilliseconds))"
            )

            Spacer(minLength: 12)

            Button {
                if isPaused {
                    appModel.resumeVoiceRecording(id: voiceID)
                } else {
                    appModel.pauseVoiceRecording(id: voiceID)
                }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "继续录音" : "暂停录音")
            .help(isPaused ? "继续录音" : "暂停录音")

            Button {
                Task {
                    await appModel.finishVoiceRecording(id: voiceID)
                }
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("结束录音")
            .help("结束录音")
        }
    }

    private func readyContent(
        voice: AppModel.DraftVoice,
        audio: ImportedAudio
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VoicePlaybackView(
                appModel: appModel,
                voiceID: voice.id,
                relativePath: audio.relativePath,
                durationMilliseconds: audio.durationMilliseconds
            )

            transcriptionStatus(voice)

            TextField(
                "语音转写",
                text: Binding(
                    get: {
                        appModel.draftVoice(forPhotoID: targetPhotoID)?.transcriptText ?? ""
                    },
                    set: {
                        appModel.updateDraftVoiceTranscript(id: voice.id, text: $0)
                    }
                ),
                prompt: Text("转写文字可在这里修正"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(2...8)
            .padding(12)
            .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.divider, lineWidth: 1)
            }
            .disabled(appModel.isTranscribingDraftVoice(id: voice.id))
            .accessibilityLabel("语音转写文字")

            Toggle(
                "保留原始录音",
                isOn: Binding(
                    get: {
                        appModel.draftVoice(forPhotoID: targetPhotoID)?.keepOriginalAudio ?? true
                    },
                    set: {
                        appModel.setKeepOriginalAudio(
                            id: voice.id,
                            shouldKeep: $0
                        )
                    }
                )
            )
            .tint(AppTheme.accent)

            if !voice.keepOriginalAudio,
               voice.transcriptText.trimmingCharacters(
                   in: .whitespacesAndNewlines
               ).isEmpty {
                Label(
                    "仅保留转写时，转写文字不能为空",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(AppTheme.mutedInk)
            }
        }
    }

    @ViewBuilder
    private func transcriptionStatus(_ voice: AppModel.DraftVoice) -> some View {
        if appModel.isTranscribingDraftVoice(id: voice.id) {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在转写")
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedInk)
                Spacer(minLength: 12)
                Button("跳过") {
                    appModel.skipDraftVoiceTranscription(id: voice.id)
                }
                .font(.callout.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
            }
        } else {
            HStack(spacing: 10) {
                Label(
                    transcriptionLabel(voice),
                    systemImage: transcriptionIcon(voice.transcriptionStatus)
                )
                .font(.callout)
                .foregroundStyle(AppTheme.mutedInk)
                Spacer(minLength: 12)
                if voice.transcriptionStatus != .completed,
                   !voice.isTranscriptUserEdited {
                    Button {
                        appModel.retryDraftVoiceTranscription(id: voice.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appModel.canRetryDraftVoiceTranscription(id: voice.id))
                    .accessibilityLabel("重试语音转写")
                    .help("重试转写")
                }
            }
        }
    }

    private func transcriptionLabel(_ voice: AppModel.DraftVoice) -> String {
        switch voice.transcriptionStatus {
        case .notRequested:
            return "尚未转写"
        case .pending:
            return "等待转写"
        case .completed:
            switch voice.transcriptionSource {
            case .onDevice:
                return "设备内转写完成"
            case .appleNetwork:
                return "Apple 网络转写完成"
            case .manual:
                return "转写已编辑"
            case nil:
                return "转写完成"
            }
        case .failed:
            return "转写失败"
        case .permissionDenied:
            return "未授权语音识别"
        }
    }

    private func transcriptionIcon(_ status: VoiceTranscriptionStatus) -> String {
        switch status {
        case .completed:
            return "checkmark.circle"
        case .failed, .permissionDenied:
            return "exclamationmark.circle"
        case .notRequested, .pending:
            return "text.bubble"
        }
    }

    private func isFinalizing(_ voice: AppModel.DraftVoice) -> Bool {
        if case .finalizing = voice.capturePhase {
            return true
        }
        return false
    }

    private func announceRecordingTransition(
        from oldPhase: AppModel.DraftVoice.CapturePhase?,
        to newPhase: AppModel.DraftVoice.CapturePhase?
    ) {
        guard case .finalizing = newPhase else {
            return
        }
        switch oldPhase {
        case .recording, .paused:
            UIAccessibility.post(
                notification: .announcement,
                argument: "录音已结束，正在保存"
            )
        case .preparing, .finalizing, .ready, .failed, nil:
            break
        }
    }
}
