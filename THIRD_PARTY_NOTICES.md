# Third-party software

Hearth IDE bundles or links the following open-source components.

| Component | Use | License |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | terminal emulator | MIT |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown parser | Apache-2.0 |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) (cmark-gfm) | via swift-markdown | BSD-2-Clause and others, see its COPYING |
| [nono](https://github.com/nolabs-ai/nono) v0.80.0 (`Contents/Helpers/nono`, unverändert) | Sandbox | Apache-2.0 |
| [monaco-editor](https://github.com/microsoft/monaco-editor) 0.52.2 (`Resources/monaco`, fetched by `scripts/fetch-monaco.sh`, unverändert und auf die genutzten Sprachen gekürzt) | code editor (VS Code) | MIT; includes the TypeScript language service (Apache-2.0), see `Resources/monaco/ThirdPartyNotices.txt` |
| [mermaid](https://github.com/mermaid-js/mermaid) 11.17.2 (`Resources/mermaid.min.js`) | offline diagram rendering | MIT |

Indirect build dependencies resolved by SwiftPM (swift-argument-parser, swift-png, …)
are licensed under Apache-2.0. The full license texts ship with each package.
