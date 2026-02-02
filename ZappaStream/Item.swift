//
//  Item.swift
//  ZappaStream
//
//  Created by Darcy Taranto on 02/02/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
