import Foundation

struct LocalJournalGenerator: JournalGenerator {
    let identifier = "local.rule-based.v1"

    func generate(_ request: JournalGenerationRequest) async throws -> GeneratedJournalDraft {
        guard !request.entries.isEmpty else {
            throw JournalGenerationError.emptyEntries
        }

        let entries = JournalSourceOrdering.entries(request.entries)
        let photos = entries.flatMap { JournalSourceOrdering.photos($0.photos) }
        let voices = entries.flatMap { JournalSourceOrdering.voices($0.voices) }
        let snippets = sourceSnippets(from: entries)
        let text = generatedText(
            style: request.style,
            entryCount: entries.count,
            photoCount: photos.count,
            voiceCount: voices.count,
            snippets: snippets
        )
        let blocks = [JournalBlock(text: text)] + photos.map {
            JournalBlock(photo: $0, caption: $0.annotationText)
        }

        return GeneratedJournalDraft(
            title: "\(request.dayKey.month) 月 \(request.dayKey.day) 日随心日记",
            blocks: blocks,
            sourceFingerprint: try JournalSourceFingerprint.make(entries: entries),
            sourceEntryCount: entries.count,
            generatorIdentifier: identifier
        )
    }

    private func sourceSnippets(from entries: [Entry]) -> [String] {
        entries.flatMap { entry in
            var snippets: [String] = []
            appendIfPresent(entry.text, to: &snippets)

            for photo in JournalSourceOrdering.photos(entry.photos) {
                appendIfPresent(photo.annotationText, to: &snippets)
            }
            for voice in JournalSourceOrdering.voices(entry.voices) {
                appendIfPresent(voice.transcriptText, to: &snippets)
            }
            return snippets
        }
    }

    private func appendIfPresent(_ text: String, to snippets: inout [String]) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            snippets.append(normalized)
        }
    }

    private func generatedText(
        style: WritingStyle,
        entryCount: Int,
        photoCount: Int,
        voiceCount: Int,
        snippets: [String]
    ) -> String {
        let counts = "\(entryCount) 条随心记录、\(photoCount) 张照片、\(voiceCount) 段语音"

        switch style {
        case .natural:
            return join(
                introduction: "这一天留下了 \(counts)。",
                snippets: snippets,
                separator: "\n\n"
            )
        case .concise:
            return join(
                introduction: "\(counts)。",
                snippets: snippets,
                separator: "\n"
            )
        case .delicate:
            return join(
                introduction: "这一天的片段按时间留在这里：\(counts)。",
                snippets: snippets,
                separator: "\n\n"
            )
        }
    }

    private func join(
        introduction: String,
        snippets: [String],
        separator: String
    ) -> String {
        ([introduction] + snippets).joined(separator: separator)
    }
}
