import Foundation
import SwiftData

@Model
final class FZShowsPageRecord {
    @Attribute(.unique) var filename: String
    var lastFetchedAt: Date
    var showCount: Int

    init(filename: String, lastFetchedAt: Date = Date(), showCount: Int = 0) {
        self.filename = filename
        self.lastFetchedAt = lastFetchedAt
        self.showCount = showCount
    }
}
