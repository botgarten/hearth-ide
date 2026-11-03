import Foundation
import Testing
@testable import Hearth

/// "Find Usages": who uses a class or function, and where.
struct UsageFinderTests {
    static func project(_ files: [String: String]) throws -> String {
        let root = try temporaryFolder("hearth-usages")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root.path
    }

    @Test func classifiesImportsCommentsDefinitionsAndCode() throws {
        let root = try Self.project([
            "src/UserService.java": """
            package app;

            public class UserService {
                public UserDto find(long id) { return null; }
            }
            """,
            "src/UserController.java": """
            package app;

            import app.UserService;

            // UserService is injected by Spring
            public class UserController {
                private final UserService service;

                public UserController(UserService service) {
                    this.service = service;
                }

                public UserDto get(long id) {
                    if (id > 0) {
                        return service.find(id);
                    }
                    UserService local = new UserService();
                    return local.find(id);
                }
            }
            """,
            "src/Other.java": "class Other { String s = \"UserServiceX\"; int UserServices; }",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = UsageFinder.search(UsageQuery(text: "UserService", sourcePath: "src/UserService.java"), root: root)
        let byLine = Dictionary(grouping: result.usages.filter { $0.path == "src/UserController.java" }, by: \.line)
        #expect(byLine[3]?.first?.kind == .importLine)
        #expect(byLine[5]?.first?.kind == .comment)
        #expect(byLine[7]?.first?.kind == .code)
        #expect(byLine[7]?.first?.container == "UserController")
        // Parameter in the constructor signature: the constructor is the user.
        #expect(byLine[9]?.first?.container == "UserController.UserController")
        // Inside get(), nested in an if / after it.
        let inGet = byLine[17] ?? []
        #expect(inGet.count == 2)
        #expect(inGet.allSatisfy { $0.container == "UserController.get" })
        // Whole words only: UserServiceX and UserServices are not usages.
        #expect(!result.usages.contains { $0.path == "src/Other.java" })
        // The declaration is flagged as such.
        #expect(result.usages.first { $0.path == "src/UserService.java" && $0.line == 3 }?.kind == .definition)
    }

    @Test func matchHighlightPointsAtTheSymbol() throws {
        let root = try Self.project(["a.go": "package a\n\nfunc Run() {\n\t\tclient.Do(Request{})\n}\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = UsageFinder.search(UsageQuery(text: "Request", sourcePath: "a.go"), root: root)
        let u = try #require(result.usages.first)
        #expect(u.line == 4)
        #expect((u.preview as NSString).substring(with: NSRange(location: u.column, length: u.length)) == "Request")
        #expect(u.container == "Run")
    }

    @Test func goMethodsNameTheirReceiver() throws {
        let root = try Self.project(["server.go": """
        package main

        type Server struct{}

        func (s *Server) Handle(w http.ResponseWriter) {
        \tlog := NewLogger()
        \tlog.Print("x")
        }
        """])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = UsageFinder.search(UsageQuery(text: "NewLogger", sourcePath: "server.go"), root: root)
        #expect(result.usages.map(\.container) == ["Server.Handle"])
    }

    @Test func pythonAndRustScopes() throws {
        let root = try Self.project([
            "svc/handlers.py": "from svc.models import User\n\nclass Handler:\n    def create(self, name):\n        # User objects\n        return User(name)\n",
            "src/lib.rs": "struct Repo;\n\nimpl Repo {\n    fn load(&self) -> User {\n        User::default()\n    }\n}\n",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let py = UsageFinder.search(UsageQuery(text: "User", sourcePath: "svc/models.py"), root: root)
        #expect(py.usages.map(\.kind) == [.importLine, .comment, .code])
        #expect(py.usages.last?.container == "Handler.create")
        // Same-language scope never reads Rust files for a Python symbol…
        #expect(!py.usages.contains { $0.path.hasSuffix(".rs") })
        // …unless asked to.
        let all = UsageFinder.search(UsageQuery(text: "User", scope: .allFiles, sourcePath: "svc/models.py"), root: root)
        #expect(all.usages.contains { $0.path == "src/lib.rs" && $0.container == "Repo.load" })
    }

    @Test func unsavedEditsAreSearchedInsteadOfTheDisk() throws {
        let root = try Self.project(["a.ts": "export const a = 1;\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = UsageFinder.search(UsageQuery(text: "helper", sourcePath: "a.ts"), root: root, overrides: ["a.ts": "const x = helper();\n"])
        #expect(result.usages.count == 1)
    }

    @Test func fileNamesBecomeQueries() throws {
        let root = try Self.project(["a/UserService.test.ts": "", "a/user-service.ts": "", "a/pkg/x.go": "", "a/notes.txt": ""])
        defer { try? FileManager.default.removeItem(atPath: root) }
        func q(_ p: String) -> UsageQuery? { UsageQuery.forFile(URL(fileURLWithPath: root).appendingPathComponent(p), root: root) }
        #expect(q("a/UserService.test.ts")?.text == "UserService")
        #expect(q("a/user-service.ts")?.text == "user-service")
        #expect(q("a/user-service.ts")?.isIdentifier == false)
        let folder = try #require(q("a/pkg"))
        #expect(folder.text == "pkg" && folder.importsOnly && folder.scope == .allFiles)
        #expect(q("a/notes.txt")?.scope == .allFiles)
        #expect(q("a/missing.go") == nil)
    }

    @Test func folderUsagesAreItsImports() throws {
        let root = try Self.project([
            "app/main.go": "package main\n\nimport (\n\t\"fmt\"\n\t\"example.com/app/store\"\n)\n\nfunc main() { store.Open(); fmt.Println(\"store\") }\n",
            "store/db.go": "package store\n\nfunc Open() {}\n",
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let query = try #require(UsageQuery.forFile(URL(fileURLWithPath: root).appendingPathComponent("store"), root: root))
        let result = UsageFinder.search(query, root: root)
        #expect(result.usages.map(\.line) == [5])
        #expect(result.usages.first?.kind == .importLine)
    }

    @Test func hyphenatedNamesDoNotMatchInsideLongerNames() throws {
        let root = try Self.project(["a.ts": "import { x } from './user-service';\nimport { y } from './user-service-extra';\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = UsageFinder.search(UsageQuery(text: "user-service", scope: .allFiles, sourcePath: "user-service.ts"), root: root)
        #expect(result.usages.map(\.line) == [1])
    }
}
