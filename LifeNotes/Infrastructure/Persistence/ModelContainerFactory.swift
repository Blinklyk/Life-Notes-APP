import Foundation
import SwiftData

enum ModelContainerFactory {
    static func make(
        isStoredInMemoryOnly: Bool = false,
        configurationName: String? = nil,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema([
            EntryRecord.self,
            PhotoAttachmentRecord.self,
            VoiceAttachmentRecord.self,
            DayRecord.self,
            JournalRecord.self,
            JournalVersionRecord.self
        ])
        let configuration: ModelConfiguration

        if let storeURL {
            configuration = ModelConfiguration(
                configurationName,
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else if let configurationName {
            configuration = ModelConfiguration(
                configurationName,
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
