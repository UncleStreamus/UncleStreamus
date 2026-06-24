import Foundation
import SwiftData

@Model
final class FZShowsPageRecord {
    var filename: String = ""
    var lastFetchedAt: Date = Date()
    var showCount: Int = 0

    init(filename: String, lastFetchedAt: Date = Date(), showCount: Int = 0) {
        self.filename = filename
        self.lastFetchedAt = lastFetchedAt
        self.showCount = showCount
    }
}
