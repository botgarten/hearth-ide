import Foundation
import Testing
@testable import Hearth

struct GitWriteTests {
    @Test func refsAndMessagesAreValidated() {
        for bad in ["", "-D", "--upload-pack=x", "a..b", "a b", "a;b", "x@{1}", "/a", "a/", "a.lock", "a$(x)", "a\nb"] {
            #expect(!SandboxGitOperation.validRef(bad), "accepted \(bad)")
        }
        for good in ["main", "feature/x-1", "release/1.2.3", "user/fix_#12"] {
            #expect(SandboxGitOperation.validRef(good), "rejected \(good)")
        }
        #expect(!SandboxGitOperation.validMessage("  \n"))
        #expect(!SandboxGitOperation.validMessage("a\0b"))
        #expect(SandboxGitOperation.validMessage("Fix 'quotes' and $(subshell)"))
    }

    @Test func localWritesRunWithoutNetworkAndWithoutHooks() throws {
        let ops: [SandboxGitOperation] = [.merge(branch: "feature/x"), .mergeAbort, .stash(message: "wip", includeUntracked: true),
                                          .stashApply(0), .stashPop(1), .stashDrop(2)]
        for op in ops {
            #expect(!op.needsNetwork, "\(op.name) must not get network rights")
            let cmd = try op.command()
            #expect(cmd.contains("core.hooksPath=/dev/null") && cmd.contains("core.fsmonitor=false"), "\(op.name): hooks")
            #expect(cmd.contains("commit.gpgsign=false"))
        }
        #expect(SandboxGitOperation.push(branch: "main", setUpstream: true).needsNetwork)
    }

    @Test func pushIsNeverForcedAndOnlyNamesOneBranch() throws {
        let plain = try SandboxGitOperation.push(branch: "feature/x", setUpstream: false).command()
        #expect(plain.contains("'origin' 'HEAD:refs/heads/feature/x'"))
        let first = try SandboxGitOperation.push(branch: "feature/x", setUpstream: true).command()
        #expect(first.contains("'--set-upstream' 'origin' 'feature/x'"))
        for cmd in [plain, first] {
            #expect(!cmd.contains("force") && !cmd.contains("'--mirror'") && !cmd.contains("'--all'") && !cmd.contains("'--delete'"))
            #expect(cmd.contains("'--no-verify'"))
        }
        #expect(throws: (any Error).self) { try SandboxGitOperation.push(branch: "-f", setUpstream: false).command() }
    }

    @Test func messageStaysOneQuotedArgument() throws {
        guard SandboxGitOperation.globalIdentity.name != nil, SandboxGitOperation.globalIdentity.email != nil else { return }
        let cmd = try SandboxGitOperation.commit(message: "a'; touch /pwned; echo '").command()
        #expect(cmd.hasSuffix("'-m' 'a'\\''; touch /pwned; echo '\\'''"))
        #expect(throws: (any Error).self) { try SandboxGitOperation.commit(message: " ").command() }
        #expect(throws: (any Error).self) { try SandboxGitOperation.merge(branch: "--abort").command() }
        #expect(throws: (any Error).self) { try SandboxGitOperation.stashDrop(-1).command() }
    }

    @Test func statusCodesSplitIntoStagedAndUnstaged() {
        func change(_ code: String) -> GitFileChange { GitFileChange(path: "f", code: code) }
        #expect(change("M ").isStaged && !change("M ").isUnstaged)
        #expect(!change(" M").isStaged && change(" M").isUnstaged)
        #expect(change("MM").isStaged && change("MM").isUnstaged)
        #expect(!change("??").isStaged && change("??").isUnstaged)
        #expect(change("A ").isStaged)
        #expect(change("UU").isConflict && !change("UU").isStaged && change("UU").marker == "!")
    }

    @Test func stashListIsTheOnlyReadableStashCommand() {
        #expect(Git.safeReadArguments(["stash", "list"]) != nil)
        #expect(Git.safeReadArguments(["stash", "pop"]) == nil)
        #expect(Git.safeReadArguments(["stash"]) == nil)
    }

    @Test func changeRequestBranchesAreValidated() {
        #expect(ChangeRequest.valid("feature/x"))
        #expect(!ChangeRequest.valid("--head=evil"))
    }
}
