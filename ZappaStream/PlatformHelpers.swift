//
//  PlatformHelpers.swift
//  ZappaStream
//
//  Cross-platform utilities for iOS and macOS
//

import SwiftUI

// MARK: - Constants

enum AppConstants {
    static let supportEmail = "zappastreamapp@gmail.com"
}

// MARK: - System Colors

extension Color {
    /// Background color for windows/screens
    static var systemBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    /// Background color for controls/cards
    static var controlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.systemGray6)
        #endif
    }

    /// Background color for section headers (sticky headers in lists)
    static var sectionHeaderBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.tertiarySystemBackground)
        #endif
    }
}

// MARK: - Bug Report Data (shared)

/// Common bug report data used by both platforms
struct BugReportData {
    let showDate: String
    let venue: String
    let url: String
    let rawMetadata: String?
    let trackName: String?
    let source: String?
    let streamFormat: String?

    var subject: String {
        "ZappaStream Bug Report - \(showDate) \(venue)"
    }

    var body: String {
        let platform: String
        #if os(macOS)
        platform = "macOS"
        #else
        platform = "iOS"
        #endif

        return """
        Show Information:
        Date: \(showDate)
        Venue: \(venue)
        URL: \(url)

        Stream Metadata:
        Raw: \(rawMetadata ?? "N/A")
        Track: \(trackName ?? "N/A")
        Source: \(source ?? "N/A")
        Stream Format: \(streamFormat ?? "N/A")

        Issue Description:
        [Please describe the issue here]

        ---
        Platform: \(platform)
        """
    }
}

// MARK: - Safari View & Mail Composer (iOS only)

#if os(iOS)
import SafariServices
import MessageUI

extension BugReportData: Identifiable {
    var id: String { "\(showDate)-\(venue)" }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct MailComposerView: UIViewControllerRepresentable {
    let data: BugReportData
    @Environment(\.dismiss) var dismiss

    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([AppConstants.supportEmail])
        mail.setSubject(data.subject)
        mail.setMessageBody(data.body, isHTML: false)
        return mail
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}
#endif

// MARK: - Bug Report Email (macOS)

#if os(macOS)
import AppKit

extension BugReportData {
    func openMailClient() {
        let subjectEncoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let bodyEncoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let mailURL = URL(string: "mailto:\(AppConstants.supportEmail)?subject=\(subjectEncoded)&body=\(bodyEncoded)") {
            NSWorkspace.shared.open(mailURL)
        }
    }
}
#endif
