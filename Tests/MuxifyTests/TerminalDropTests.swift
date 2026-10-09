import AppKit
import XCTest

final class TerminalDropTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testDroppedScreenshotPasteIsAnEscapedPath() {
        let url = URL(fileURLWithPath: "/var/folders/T/NSIRD_screencaptureui_x/Screenshot 2026-10-09 at 10.00.00 (2).png")
        pasteboard.writeObjects([url as NSURL])
        XCTAssertEqual(
            GhosttyInput.dropText(pasteboard),
            #"/var/folders/T/NSIRD_screencaptureui_x/Screenshot\ 2026-10-09\ at\ 10.00.00\ \(2\).png"#
        )
    }

    func testPromisedFileIsStagedWhereTmuxProgramsCanReadIt() throws {
        let source = try TestDirectory(), staging = try TestDirectory()
        let screenshot = source.url.appendingPathComponent("Screenshot 1.png")
        try Data("png".utf8).write(to: screenshot)
        let item = NSPasteboardItem()
        item.setString(screenshot.absoluteString, forType: .fileURL)
        item.setString(screenshot.absoluteString, forType: .init("com.apple.pasteboard.promised-file-url"))
        pasteboard.writeObjects([item])

        let text = try XCTUnwrap(GhosttyInput.dropText(pasteboard, stagingDirectory: staging.url))
        let staged = text.replacingOccurrences(of: "\\ ", with: " ")
        XCTAssertTrue(staged.hasPrefix(staging.url.path + "/"), text)
        XCTAssertTrue(staged.hasSuffix("/Screenshot 1.png"), text)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staged)), Data("png".utf8))
    }

    func testPlainFileIsNotStaged() throws {
        let staging = try TestDirectory()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/c.png") as NSURL])
        XCTAssertEqual(GhosttyInput.dropText(pasteboard, stagingDirectory: staging.url), "/tmp/c.png")
    }

    func testMultipleFilesAreSpaceSeparated() {
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a b.png") as NSURL, URL(fileURLWithPath: "/tmp/c.png") as NSURL])
        XCTAssertEqual(GhosttyInput.dropText(pasteboard), #"/tmp/a\ b.png /tmp/c.png"#)
    }

    func testDroppedTextIsPastedVerbatim() {
        pasteboard.writeObjects(["echo $HOME && ls" as NSString])
        XCTAssertEqual(GhosttyInput.dropText(pasteboard), "echo $HOME && ls")
    }

    func testEmptyDropHasNoText() {
        pasteboard.clearContents()
        XCTAssertNil(GhosttyInput.dropText(pasteboard))
    }

    func testShellEscapeMatchesGhostty() {
        XCTAssertEqual(GhosttyInput.shellEscape(##"a\b c'd"$e&f|g;h*i?j!k#l`m<n>o{p}q[r]"##),
                       ##"a\\b\ c\'d\"\$e\&f\|g\;h\*i\?j\!k\#l\`m\<n\>o\{p\}q\[r\]"##)
        XCTAssertEqual(GhosttyInput.shellEscape("tab\there"), "tab\\\there")
        XCTAssertEqual(GhosttyInput.shellEscape("plain/path-1.png"), "plain/path-1.png")
    }
}
