@testable import DamonPlatform
import Foundation
import Testing

struct AppInformationTests {
    @Test func formatsVersionAndBuildFromBundleMetadata() throws {
        let info = try AppInformation(info: [
            "CFBundleName": "Example",
            "CFBundleShortVersionString": "2.3.4",
            "CFBundleVersion": "91"
        ])
        #expect(info.versionDescription == "Example 2.3.4 (build 91)")
    }

    @Test func rejectsMissingOrEmptyVersionAndBuild() {
        let valid: [String: Any] = [
            "CFBundleName": "Example",
            "CFBundleShortVersionString": "2.3.4",
            "CFBundleVersion": "91"
        ]
        for key in ["CFBundleName", "CFBundleShortVersionString", "CFBundleVersion"] {
            var info = valid
            info[key] = " "
            #expect(throws: AppInformation.Error.missingMetadata(key)) {
                _ = try AppInformation(info: info)
            }
        }
    }

    @Test func readsBundledCreditsAndReportsMissingCredits() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ratecue-about-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Test.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "org.example.ratecue-test",
            "CFBundleName": "Example",
            "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let notice = resources.appendingPathComponent("NOTICE")
        try "Example contributor\n".write(to: notice, atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: app))
        #expect(try AppInformation.credits(bundle: bundle) == "Example contributor\n")

        try "".write(to: notice, atomically: true, encoding: .utf8)
        #expect(throws: AppInformation.Error.emptyCredits) {
            _ = try AppInformation.credits(bundle: bundle)
        }
        let missingApp = root.appendingPathComponent("Missing.app", isDirectory: true)
        let missingContents = missingApp.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: missingContents.appendingPathComponent("Resources", isDirectory: true),
                               withIntermediateDirectories: true)
        try plist.write(to: missingContents.appendingPathComponent("Info.plist"))
        let missingBundle = try #require(Bundle(url: missingApp))
        #expect(throws: AppInformation.Error.missingCredits) {
            _ = try AppInformation.credits(bundle: missingBundle)
        }
    }
}
