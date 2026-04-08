import AppKit
import Foundation
import Security
import Sparkle

@MainActor
protocol UpdateControlling: AnyObject {
    var isAvailable: Bool { get }
    func checkForUpdates(_ sender: Any?)
}

@MainActor
final class DisabledUpdateController: UpdateControlling {
    let isAvailable = false

    func checkForUpdates(_ sender: Any?) {}
}

@MainActor
final class SparkleUpdateController: NSObject, UpdateControlling {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    let isAvailable = true

    func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}

@MainActor
func makeUpdateController() -> UpdateControlling {
    let bundle = Bundle.main
    guard bundle.bundleURL.pathExtension == "app",
          isDeveloperIDSigned(bundleURL: bundle.bundleURL),
          hasSparkleFeedConfiguration(bundle: bundle)
    else {
        return DisabledUpdateController()
    }
    return SparkleUpdateController()
}

private func hasSparkleFeedConfiguration(bundle: Bundle) -> Bool {
    let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    return !(feedURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        && !(publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
}

private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode
    else {
        return false
    }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first,
          let summary = SecCertificateCopySubjectSummary(leaf) as String?
    else {
        return false
    }

    return summary.hasPrefix("Developer ID Application:")
}
