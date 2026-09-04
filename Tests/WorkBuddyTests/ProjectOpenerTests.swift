import Foundation
import Testing

@testable import WorkBuddy

@MainActor
struct ProjectOpenerTests {
    private var request: LocalBranchCheckout.Request {
        .init(pullRequestID: "PR_42", url: URL(string: "https://github.com/org/repo/pull/42")!,
              repository: "org/repo", branch: "feature/test", folder: URL(fileURLWithPath: "/tmp/project"))
    }

    @Test("A successful checkout opens the configured folder automatically")
    func success() async {
        let opener = ProjectOpener(checkout: { _ in })
        var opened: [URL] = []
        await opener.open(request) { opened.append($0) }
        #expect(opened == [request.folder])
        #expect(opener.warning == nil)
        #expect(opener.error == nil)
        #expect(!opener.isOpening)
    }

    @Test("A failed checkout waits for the fallback button and never retries Git")
    func fallback() async {
        let attempts = Attempts()
        let opener = ProjectOpener(checkout: { _ in
            await attempts.increment()
            throw LocalBranchCheckout.Failure(exitCode: 1, stderr: "Local changes would be overwritten")
        })
        var opened: [URL] = []
        await opener.open(request) { opened.append($0) }
        #expect(opened.isEmpty)
        #expect(opener.warning?.request.branch == "feature/test")
        #expect(opener.warning?.text.contains("feature/test") == true)
        #expect(!opener.isOpening)
        await opener.openWithoutBranch { opened.append($0) }
        await opener.openWithoutBranch { opened.append($0) }
        #expect(opened == [request.folder])
        #expect(opener.warning == nil)
        #expect(await attempts.count == 1)
    }

    @Test("Dismissing the warning cancels the fallback")
    func dismiss() async {
        let opener = ProjectOpener(checkout: { _ in
            throw LocalBranchCheckout.Failure(exitCode: 1, stderr: "Local changes would be overwritten")
        })
        await opener.open(request) { _ in Issue.record("Must not launch") }
        opener.dismissNotice()
        await opener.openWithoutBranch { _ in Issue.record("Must not launch after cancellation") }
        #expect(opener.warning == nil)
    }

    @Test("Editor launch failures use the inline error state", arguments: [false, true])
    func launchError(fallback: Bool) async {
        let opener = ProjectOpener(checkout: { _ in
            if fallback { throw LocalBranchCheckout.Failure(exitCode: 1, stderr: "Local changes would be overwritten") }
        })
        await opener.open(request) { _ in throw EditorStore.EditorError.missingApplication }
        if fallback {
            await opener.openWithoutBranch { _ in throw EditorStore.EditorError.missingApplication }
        }
        #expect(opener.error is EditorStore.EditorError)
        #expect(opener.warning == nil)
        #expect(!opener.isOpening)
    }

    @Test("Overlapping requests cannot switch the folder while it is being opened")
    func concurrentRequest() async {
        let opener = ProjectOpener(checkout: { _ in })
        await opener.open(request) { _ in
            #expect(opener.isOpening)
            await opener.open(request) { _ in Issue.record("Overlapping launch") }
        }
        #expect(!opener.isOpening)
    }
}

private actor Attempts {
    private(set) var count = 0
    func increment() { count += 1 }
}
