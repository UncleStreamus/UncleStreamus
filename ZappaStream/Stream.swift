//
//  Stream.swift
//  ZappaStream
//
//  Created by Datisit on 04/02/2026.
//

import Foundation

struct Stream: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: String
    let format: String
}
