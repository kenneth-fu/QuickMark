# QuickMark technical design

How QuickMark is put together, why it is put together that way, and what to know
before changing it. The README covers installing and using it; this covers the
internals.

Written against macOS 26.5.2 (Tahoe), Xcode 26.6, Swift 6.3.3, swift-markdown
0.8.0.

## Contents

1. [What it is](#what-it-is)
2. [Process model](#process-model)
3. [Repository layout](#repository-layout)
4. [Build system](#build-system)
5. [Type resolution and routing](#type-resolution-and-routing)
6. [The rendering pipeline](#the-rendering-pipeline)
7. [Renderers](#renderers)
8. [Data structures](#data-structures)
9. [Layout and styling](#layout-and-styling)
10. [Security model](#security-model)
11. [Sandbox and entitlements](#sandbox-and-entitlements)
12. [Performance](#performance)
13. [Diagnostics](#diagnostics)
14. [Things to be aware of](#things-to-be-aware-of)
15. [Adding a new file type](#adding-a-new-file-type)

## What it is

A macOS Quick Look Preview Extension that renders Markdown, EPUB, JSON, dotenv
and plain text in the Finder preview panel, plus a small host app whose job is
to exist so macOS has somewhere to find the extension.

It was written to replace QLMarkdown, which was not previewing Markdown on this
machine. **That original diagnosis was wrong in one respect and it is worth
recording:** QLMarkdown 1.5.2 is not a retired `.qlgenerator` plugin. It ships a
modern preview extension of exactly the same kind as this one, and once
registered it claims `net.daringfireball.markdown` and wins Markdown previews
over QuickMark. See [Things to be aware of](#things-to-be-aware-of).

Around 2948 lines of Swift, 743 lines of CSS, no third party runtime code
other than Apple's swift-markdown.

### Supported documents

| Kind | Extensions / names | Renderer | Reached via |
| --- | --- | --- | --- |
| Markdown | `.md` `.markdown` `.mdown` `.mkd` `.mkdn` `.mdwn` `.qmd` `.rmd` | `HTMLRenderer` | `net.daringfireball.markdown` |
| EPUB | `.epub` | `EPUBRenderer` | `org.idpf.epub-container` |
| JSON | `.json` `.geojson` `.jsonc` `.webmanifest` | `JSONRenderer` | `public.json` |
| dotenv | `.env` `.env.*` `*.env` `env.*` | `DotEnvRenderer` | `public.data`, `com.puiwaifu.quickmark.dotenv` |
| Plain text | any extension-less text file | `PlainTextRenderer` | `public.data` |
| Binary | anything else that reaches us | error panel | `public.data` |

Of the JSON extensions only `.json` is actually *claimed*, via `public.json`.
`.geojson`, `.jsonc` and `.webmanifest` are recognised by the detector, so they
render correctly through `qm-render` and would render correctly in a preview,
but macOS routes them to other handlers until their types are added to
`QLSupportedContentTypes`. The claimed set is exactly:

```
net.daringfireball.markdown  public.markdown  public.data
com.puiwaifu.quickmark.dotenv  public.json  org.idpf.epub-container
```

See [Type resolution and routing](#type-resolution-and-routing).

Markdown coverage is CommonMark plus the GitHub extensions swift-markdown
enables: tables with alignment, strikethrough, task lists. On top of that
QuickMark adds YAML front matter, GitHub alerts (`> [!NOTE]`), heading anchors,
and autolinking of bare URLs (swift-markdown leaves cmark's autolink extension
off, so a bare URL arrives as plain text).

Not supported: syntax highlighting, Mermaid, KaTeX, footnotes. The first three
need JavaScript, which is off by design.

## Process model

A preview involves four processes:

```
Finder / qlmanage
      │  (1) preview request
      ▼
quicklookd ── selects an extension by content type
      │  (2) launch via PlugInKit / ExtensionFoundation
      ▼
PreviewExtension.appex          ← our code, sandboxed
      │  (3) WKWebView
      ▼
com.apple.WebKit.WebContent     ← separate XPC service, renders the HTML
```

Each hop has bitten this project at least once:

* Step 2 fails silently if the appex is not sandboxed.
* Step 3 fails silently without `com.apple.security.network.client`, and the
  panel is blank while every upstream signal looks healthy.
* The host app must have been launched at least once before PlugInKit will list
  the extension at all.

The extension is short lived. It is spawned per preview, lingers briefly, and is
torn down. It has no persistent state and writes nothing.

## Repository layout

```
QuickMark/
├── DESIGN.md                    this document
├── README.md                    install and use
├── generate_project.rb          writes QuickMark.xcodeproj (258 lines)
├── generate_project.sh          runs the above with the right Ruby
├── install.sh                   build, install, register, verify (74 lines)
├── Samples/                     test corpus
│   ├── kitchen-sink.md          every Markdown construct the renderer handles
│   ├── sample.json  sample.env  Dockerfile  with-image.md  badge.png
├── Sources/
│   ├── App/
│   │   ├── QuickMarkApp.swift       SwiftUI entry point (14 lines)
│   │   ├── ContentView.swift        registration status UI (190 lines)
│   │   ├── Info.plist               exported dotenv UTI declaration
│   │   └── QuickMark.entitlements   unsandboxed, so it can run pluginkit
│   └── PreviewExtension/
│       ├── PreviewViewController.swift   QLPreviewingController (153)
│       ├── TextPreview.swift             kind detection, loading, text + env (267)
│       ├── HTMLRenderer.swift            Markdown MarkupVisitor (472)
│       ├── JSONValue.swift               JSON model and parser (295)
│       ├── JSONRenderer.swift            JSON tree HTML (196)
│       ├── ZIPArchive.swift              in-memory ZIP reader (235)
│       ├── EPUBDocument.swift            container, OPF, spine, TOC (376)
│       ├── EPUBRenderer.swift            EPUB HTML and sanitiser (263)
│       ├── HTMLPage.swift                page shell, CSP, dispatch (141)
│       ├── MarkdownDocument.swift        decoding and front matter (109)
│       ├── ImageInliner.swift            local images as data URIs (102)
│       ├── Info.plist                    QLSupportedContentTypes
│       ├── PreviewExtension.entitlements sandbox + network client
│       └── Resources/style.css           the theme (604 lines)
└── Tools/
    ├── render-main.swift        qm-render CLI (90 lines)
    └── render.sh                build and run it
```

### Module boundaries

`HTMLRenderer`, `MarkdownDocument`, `HTMLPage`, `ImageInliner`, `TextPreview`,
`JSONValue`, `JSONRenderer`, `ZIPArchive`, `EPUBDocument` and `EPUBRenderer`
are compiled into **both** the extension and the
`qm-render` CLI. They must therefore stay free of Quartz, WebKit and AppKit.
Only `PreviewViewController.swift` imports those, and only it is in the
extension target alone.

That boundary is what makes the CLI possible, and the CLI is what makes it
practical to iterate on rendering without reinstalling and restarting Quick Look
on every change.

## Build system

### The project file is generated

`QuickMark.xcodeproj` is not checked in. `generate_project.rb` writes it using
the `xcodeproj` Ruby gem that ships inside Homebrew's CocoaPods, which is why
`generate_project.sh` sets `GEM_HOME` rather than relying on whichever Ruby is
on `PATH`.

Add a source file to `Sources/` and run `./generate_project.sh` to pick it up.
The shared renderer files are listed explicitly in `SHARED_RENDERER_SOURCES` so
they get added to the CLI target as well; forgetting to add a new shared file
there produces a CLI-only build failure.

Rationale: a hand maintained `project.pbxproj` is a large opaque blob that
conflicts badly and hides its own settings. A 258 line script that states every
build setting is easier to read and to change.

### Targets

| Target | Type | Bundle id | Notes |
| --- | --- | --- | --- |
| `QuickMark` | Application | `com.puiwaifu.QuickMark` | Host, unsandboxed |
| `PreviewExtension` | App extension | `…QuickMark.PreviewExtension` | Sandboxed, embedded in PlugIns |
| `qm-render` | Command line tool | `…QuickMark.render` | Dev tool, not installed |

Deployment target macOS 14.0, Swift language mode 5, ad hoc signed
(`CODE_SIGN_IDENTITY = "-"`), hardened runtime off. There are no signing
identities on the development machine, which constrains what entitlements can be
used; see [Sandbox and entitlements](#sandbox-and-entitlements).

### Dependency

swift-markdown 0.8.0 from `github.com/apple/swift-markdown`, consumed as an
`XCRemoteSwiftPackageReference`. Each target that needs it gets its own
`XCSwiftPackageProductDependency`; Xcode does not share one across targets. It
pulls in swift-cmark transitively and links statically, so nothing needs
embedding.

### install.sh

```
generate project if missing
  → xcodebuild Release
  → lsregister -u the build copy, then delete it      ← see below
  → cp to ~/Applications
  → lsregister -f the installed copy
  → killall pkd quicklookd QuickLookUIService         ← Quick Look caches binaries
  → open -g the app                                   ← PlugInKit needs it seen running
  → poll pluginkit for up to 15s
```

Two of those steps exist because of specific failures:

* **Retiring the build copy.** Launch Services registers the app sitting in
  `.build/`, so two bundles claim the same identifier and Quick Look may resolve
  the one you are not updating. This produced a genuinely confusing session
  where a rebuilt extension kept serving old behaviour.
* **Killing the daemons.** Without it, a rebuilt extension keeps serving the
  previous binary.

## Type resolution and routing

This is the least obvious part of the system and the source of most of its
surprises. Quick Look matches on Uniform Type Identifiers, never on filenames.

### How macOS types the files we care about

| File | UTI | Why |
| --- | --- | --- |
| `README.md` | `net.daringfireball.markdown` | declared by some installed app |
| `test.json` | `public.json` | Apple defined |
| `.env` | `public.data` | leading dot name, **no extension recognised** |
| `.gitignore`, `.bashrc`, `Dockerfile` | `public.data` | no extension |
| `.env.local` | `com.puiwaifu.quickmark.dotenv` | our exported type claims `local` |
| `foo.env` | `com.puiwaifu.quickmark.dotenv` | our exported type claims `env` |
| `LICENSE` | `public.plain-text` | special cased by macOS |
| `Makefile` | `public.make-source` | ditto |
| an unknown `.xyz` | `dyn.ah62d4…` | synthesized from the extension |

### The two mechanisms

**`public.data`** reaches `.env` and every other extension-less file. Quick Look
prefers the most specific match, so images, PDFs and anything with a real type
still go to their own handlers. QuickMark only picks up what nothing else
claims.

**An exported UTI** reaches `.env.local` and `config.env`. This is necessary
because of a rule that is easy to get wrong:

> A file with an unrecognised extension gets a synthesized `dyn.*` type. That
> type **conforms to** `public.data`, but Quick Look does **not** resolve it
> against a `public.data` claim.

Verified directly: with only the `public.data` claim, `.env` and `Dockerfile`
previewed while `.env.local` and `sample.env` did not, despite
`kMDItemContentTypeTree` listing `public.data` for all of them. So conformance
is not sufficient; the type has to be claimed.

`Sources/App/Info.plist` therefore exports `com.puiwaifu.quickmark.dotenv`,
conforming to `public.plain-text`, claiming the extensions `env`, `local`,
`production`, `development`, `staging`.

**Consequence:** any `notes.local` or `deploy.staging` file on the system is now
an "Environment File" and previews through QuickMark as plain text. That is the
price of reaching `.env.local`. `.example` was deliberately left out because it
collides more widely.

### Where each claim lives

* `QLSupportedContentTypes` in `Sources/PreviewExtension/Info.plist` lists what
  the extension handles.
* `UTExportedTypeDeclarations` in `Sources/App/Info.plist` defines the dotenv
  type. UTI declarations come from the **app** bundle, not the appex.

## The rendering pipeline

```
preparePreviewOfFile(at:completionHandler:)
   │
   ├─ PreviewSource.load(contentsOf:)
   │     ├─ Data(contentsOf:, .mappedIfSafe)
   │     ├─ PreviewKind.detect(fileName:sample:)   ← first 8 KB
   │     └─ MarkdownDocument.decodeText            ← UTF-8, detected, Latin-1
   │
   ├─ switch kind
   │     ├─ .markdown  → HTMLPage.render(MarkdownDocument, baseURL:)
   │     ├─ .json      → HTMLPage.render(text:kind:)  → JSONParser → JSONRenderer
   │     ├─ .dotenv    → HTMLPage.render(text:kind:)  → DotEnvRenderer
   │     ├─ .plainText → HTMLPage.render(text:kind:)  → PlainTextRenderer
   │     └─ .binary    → HTMLPage.errorPage
   │
   ├─ webView.loadHTMLString(html, baseURL: nil)
   │
   └─ completion fires in webView(_:didFinish:)     ← NOT here
```

### Kind detection

`PreviewKind.detect` takes the filename and the first 8 KB:

1. Binary check first. A NUL byte, or bytes that decode as neither UTF-8 nor
   Latin-1, means binary.
2. Markdown extension set.
3. JSON extension set.
4. dotenv name patterns (`.env`, `.env.*`, `env.*`, `*.env`).
5. Otherwise plain text.

Filename is authoritative rather than the content type, because the
`public.data` claim delivers files of every shape and the UTI says nothing
useful about them.

### Completion handler timing

The completion handler is stored and fired from `webView(_:didFinish:)`, never
from `preparePreviewOfFile`. Quick Look snapshots the view once the handler
fires; calling it early yields a blank preview.

A 5 second timer fires the handler as a backstop so a wedged web view cannot
leave the panel spinning forever. `finish(with:)` nils the stored handler, so it
runs at most once.

## Renderers

### Markdown, `HTMLRenderer`

A `MarkupVisitor` over the swift-markdown tree, emitting HTML. swift-markdown
ships a Markdown formatter but no HTML one, so this is the piece we own.

Notable pieces:

* **List looseness.** CommonMark spaces a list differently when its items are
  separated by blank lines. swift-markdown does not expose cmark's tightness
  flag, so it is reconstructed from source ranges: cmark stretches a separated
  item's range over the blank line that follows it, so a loose item ends further
  down than its own content does. The last item always absorbs the list's
  trailing newline and is skipped. Verified against tight, loose, nested and
  mixed lists.
* **Autolinking.** swift-markdown leaves cmark's autolink extension off.
  `linkify` finds bare `http(s)://` runs, trims trailing sentence punctuation,
  balances parentheses, and skips work entirely when already inside a `Link`
  (`linkDepth`), since nested anchors are invalid.
* **Heading anchors.** Slugified, de-duplicated via `usedAnchors`.
* **GitHub alerts.** A blockquote opening with `[!NOTE]` and friends becomes a
  styled callout.
* **Raw HTML.** Passed through, except a deny list (`script`, `iframe`,
  `object`, `embed`, `form`, `style`, `link`, `meta`, `input`, `base`),
  `javascript:` URLs and inline `on*=` handlers, which are escaped to visible
  text instead.

### JSON, `JSONValue` + `JSONRenderer`

**Parsed by hand, not by `JSONSerialization`.** That is a deliberate call:
`JSONSerialization` returns dictionaries, which lose member order, and routes
numbers through `Double`. A preview should show the file as written. In the
sample file, `JSONSerialization` would have reordered every key, turned `1.50`
into `1.5` and `6.02e23` into `6.02e+23`.

So `JSONValue` keeps objects as an ordered `[(key, value)]`, and stores numbers
and strings as their **raw source text**. Strings are not unescaped, which also
sidesteps surrogate pair handling; a preview showing `é` as written is
faithful.

The parser tracks line and column, so a malformed document reports
`Trailing comma in array at line 3, column 21` rather than failing opaquely. On
a parse error the raw text is rendered underneath the message, so the file stays
readable.

`JSONRenderer` emits a tree of native `<details>` / `<summary>` elements.
Collapsing therefore works with **JavaScript disabled**, which it is. A closed
node shows what it hides (`{ 3 keys }`) via a CSS rule that hides the hint when
`[open]`.

Expansion policy:

* Documents of 400 values or fewer open fully expanded.
* Larger documents keep depth 0 and 1 open and collapse the rest.
* Array elements are numbered only when they are objects or arrays. A 200
  element array of objects otherwise reads as `{ 3 keys }` two hundred times
  with no way to tell position; an array of plain strings stays clean.

### EPUB, `ZIPArchive` + `EPUBDocument` + `EPUBRenderer`

An EPUB is a ZIP holding XHTML. Three pieces handle it.

`ZIPArchive` is a read only ZIP reader that works **entirely in memory**. It
finds the End of Central Directory record by scanning backwards, walks the
central directory, and inflates entries with Apple's `Compression` framework.
`COMPRESSION_ZLIB` is raw DEFLATE despite the name, which is exactly what ZIP
stores. Only stored and deflate are supported; Zip64 and encrypted entries are
reported rather than mis-read.

Staying in memory is deliberate. Unpacking to a temporary directory would add a
filesystem dependency to a sandboxed process, and the sandbox is precisely where
this project has been bitten before. Reading the `.epub` itself needs nothing
beyond what Quick Look already grants, so **EPUB support adds no entitlement**.

`EPUBDocument` follows the format's chain: `META-INF/container.xml` names the
package document, which carries the Dublin Core metadata, the manifest and the
spine. The table of contents comes from an EPUB 3 `nav` document or an EPUB 2
NCX, and the cover from a manifest `cover-image` property, an EPUB 2
`<meta name="cover">`, or failing both an image whose name says cover. Parsing
uses `XMLDocument` with `local-name()` XPath, which sidesteps namespace
registration entirely. Hrefs resolve against the package directory, collapsing
the `..` segments EPUBs use to climb out of `OEBPS/`.

`EPUBRenderer` emits the cover, metadata, contents and chapters. Two details
matter:

* **Sanitising strips rather than escapes.** The whole-document escape used for
  inline HTML in Markdown would turn a single `<style>` block into a screen of
  visible tag soup. Chapters instead have `script`, `style`, `iframe`, `object`,
  `embed`, `form`, `svg`, `video` and `audio` removed with their contents, void
  elements like `link` and `base` removed, and `on*=` handlers and `javascript:`
  stripped.
* **The book's own CSS is discarded**, so every book gets QuickMark's theme
  rather than bringing its own fonts and colours into the panel.

Images inside the archive are rewritten to data URIs, since the web view has no
way to reach inside the zip. An image that cannot be embedded gets an empty
`src`, which CSS hides, rather than a broken image icon.

### dotenv, `DotEnvRenderer`

A line parser producing `comment`, `variable`, `blank` or `other` entries.
Handles `export` prefixes, single and double quoted values with backslash
escapes, and trailing `# comment` on unquoted values. A `#` inside quotes stays
part of the value. Keys are validated as letters, digits, underscore and dot, so
a stray prose line renders as `other` rather than as a bogus variable.

**Values are rendered in full and not masked.** A `.env` normally holds live API
keys and database passwords, and pressing Space in Finder puts them on screen,
including during a screen share. This is a chosen tradeoff, not an oversight;
masking is a small change local to this renderer.

### Plain text, `PlainTextRenderer`

Each line becomes a `<span class="ln">`, numbered with a CSS counter. Empty
lines carry a zero width space so they keep their height. Capped at 5,000 lines
with a note, because a web view holding a hundred thousand line elements is slow
enough to matter.

### Images, `ImageInliner`

Local images are read in Swift and embedded as `data:` URIs rather than left as
`file://` subresources, so rendering does not depend on WebKit's file access
policy. Caps: 8 MB per image, 24 MB per document. Unreadable images fall back to
their alt text in a dashed box.

In practice local images do not load at all on an ad hoc signed build; see
[Sandbox and entitlements](#sandbox-and-entitlements). The code is in place so
that adding a real signing identity turns them on with no code change.

## Data structures

```swift
enum PreviewKind { case markdown, dotenv, json, plainText, binary }

struct PreviewSource { let kind: PreviewKind; let text: String; let fileName: String }

struct MarkdownDocument { let frontMatter: String?; let body: String }

indirect enum JSONValue {
    case object([(key: String, value: JSONValue)])   // order preserved
    case array([JSONValue])
    case string(String)   // raw source text
    case number(String)   // raw source text
    case bool(Bool)
    case null
}

enum DotEnvRenderer.Entry { case comment, variable, blank, other }
```

`JSONRenderer.RenderState` carries the expand-all decision and a remaining node
budget through the recursion, flipping `truncated` when the budget runs out.

## Layout and styling

One stylesheet, `Resources/style.css`, inlined into every page rather than
linked. Inlining keeps the document's base URL free and means the page has no
subresources at all.

### Theme tokens

CSS custom properties on `:root`, redefined under
`@media (prefers-color-scheme: dark)`. Everything else refers to tokens, so
adding a light or dark variant never means touching a rule:

```
--text --text-muted --text-faint
--background --surface --surface-strong
--border --border-subtle
--accent
--alert-note --alert-tip --alert-important --alert-warning --alert-caution
--font-body --font-mono
```

The alert colours double as the JSON syntax palette (strings green, numbers
purple, booleans amber), which keeps the two views visually consistent without a
second set of tokens.

### Two body layouts

| Class | Used by | Width | Character |
| --- | --- | --- | --- |
| `.markdown-body` | Markdown | 46rem | prose measure, system font |
| `.text-body` | JSON, dotenv, plain text | 60rem | wider, monospace |

Both centre with `margin: 0 auto`. The wider column suits code-shaped content
where wrapping is more disruptive than a long line.

### Structural techniques

* **Tight and loose lists.** The renderer tags each list `tight` or `loose` and
  CSS removes the paragraph margin inside tight items. cmark wraps list item
  content in a paragraph either way, so the spacing has to come off in CSS.
* **JSON disclosure triangles.** The native marker is hidden
  (`list-style: none` plus `::-webkit-details-marker { display: none }`) and
  replaced by a CSS border triangle that rotates on `[open]`, so it sits on the
  text baseline.
* **Indent guides.** `.json-children` carries a left border, giving a hairline
  per nesting level.
* **Line numbers.** A CSS counter on `pre.plain`, incremented per `.ln`, drawn
  in `::before` with `user-select: none`.
* **Language tags.** Fenced code blocks carry `data-lang`, surfaced by
  `pre[data-lang]::after` in the corner.
* **Wide content.** Tables sit in an `.table-wrap` with `overflow-x: auto`, and
  long unbroken strings use `overflow-wrap: anywhere`, so the page body never
  scrolls sideways.

## Security model

A preview runs against files that arrive from anywhere, including mail
attachments and downloads. It is a renderer, not a browser.

| Control | Where | Effect |
| --- | --- | --- |
| JavaScript disabled | `allowsContentJavaScript = false` | no script execution at all |
| Content Security Policy | `HTMLPage.contentSecurityPolicy` | `default-src 'none'`, images only from `data:` and `https:`, no scripts, fonts or frames |
| Raw HTML deny list | `HTMLRenderer.sanitizeRawHTML` | dangerous tags, `javascript:` URLs and `on*=` handlers escaped to text |
| URL scheme allow list | `HTMLRenderer.safeURL` | only `http`, `https`, `mailto`, `file`, `data` |
| Navigation cancelled | `decidePolicyFor` | only the initial in-memory load proceeds |
| No base URL | `loadHTMLString(_, baseURL: nil)` | the page cannot reference the filesystem |
| Binary refusal | `PreviewKind.detect` | non-text gets a panel, not mojibake |

The controls are layered deliberately. The CSP alone would stop scripts, but the
deny list means a malicious document does not even get to test it, and JS being
off means neither has to hold.

The one deliberate exposure is dotenv values, rendered in full. See
[dotenv](#dotenv-dotenvrenderer).

Enabling JavaScript, which Mermaid or KaTeX would require, means revisiting
every row of that table.

## Performance

Measured on this machine, Release build. `qm-render` timings are the mean of
three runs and include roughly 10 ms of process startup.

### Parse and render

| Input | Size | HTML out | Ratio | Time |
| --- | --- | --- | --- | --- |
| `sample.env` | 358 B | 13 KB | — | 10 ms |
| Markdown | 2.8 KB | 17 KB | 6× | 15 ms |
| Markdown | 57 KB | 120 KB | 2.1× | 23 ms |
| Markdown | 575 KB | 1.1 MB | 1.9× | 160 ms |
| JSON | 8 KB | 106 KB | 12.9× | 10 ms |
| JSON | 339 KB | 3.8 MB | 11.2× | 30 ms |
| JSON | 3.4 MB | 4.2 MB | capped | 78 ms |
| EPUB | 168 KB | 435 KB | 2.6× | 170 ms |
| EPUB | 181 KB | 450 KB | 2.5× | 158 ms |
| EPUB | 768 KB | 825 KB | capped | 284 ms |

Two things to read off this:

* **There is an 11 KB floor.** The stylesheet is inlined into every page, so
  even a 358 byte `.env` produces 13 KB of HTML. Irrelevant at preview sizes,
  but it is why small files never report small numbers.
* **JSON expands about 12×**, because every value carries its own element and
  classes. This is what the node cap is protecting against: the 3.4 MB input
  above stops at 20,000 values, which is why its output is barely larger than
  the 339 KB input's.

### End to end in Quick Look

Time from the extension finishing HTML generation to `didFinish`:

| Document | HTML | Render to paint |
| --- | --- | --- |
| `small.json` | 106 KB | 147 ms |
| `medium.json` | 3.8 MB | 265 ms |
| `large.json` | 4.2 MB | 297 ms |
| `large.md` | 1.1 MB | 260 ms |

Comfortably inside the 5 second backstop, with the worst case an order of
magnitude clear. Paint cost grows far more slowly than document size, so the
caps below are about memory and DOM size rather than about hitting the timeout.

The dominant fixed cost is not our code at all: it is spawning the extension and
its WebKit content process, which is why the first preview after a Quick Look
restart feels slower than subsequent ones.

### Caps and thresholds

| Constant | Value | Where | Why |
| --- | --- | --- | --- |
| Binary sniff sample | 8 KB | `PreviewSource.sampleSize` | enough to catch a header |
| Plain text lines | 5,000 | `PlainTextRenderer.maximumLines` | DOM size |
| JSON values rendered | 20,000 | `JSONRenderer.maximumNodes` | DOM size |
| JSON expand-all below | 400 values | `JSONRenderer.expandEverythingBelow` | readable first screen |
| JSON default open depth | 2 | `JSONRenderer.defaultOpenDepth` | ditto |
| Image, per file | 8 MB | `ImageInliner.maximumFileSize` | base64 is 4/3 of source |
| Image, per document | 24 MB | `ImageInliner.totalBudget` | ditto |
| EPUB chapter HTML | 300,000 chars | `EPUBRenderer.contentBudget` | a preview is a glance |
| EPUB documents | 30 | `EPUBRenderer.maximumChapters` | ditto |
| EPUB cover | 4 MB | `EPUBRenderer.maximumCoverBytes` | base64 is 4/3 of source |
| Preview timeout | 5 s | `PreviewViewController.loadTimeout` | never leave the panel spinning |

Every cap that truncates says so in the output rather than silently showing
less than the file contains.

File reads use `Data(contentsOf:, .mappedIfSafe)`, so a large file is mapped
rather than copied.

## Diagnostics

### The extension logs

```bash
log stream --level debug --predicate 'subsystem == "com.puiwaifu.QuickMark"'
```

Start it **before** triggering the preview. Two lines matter:
`rendered <file>: N characters` and `web view painted`.

`web view painted` is the only proof the preview actually worked. Generating
HTML is not evidence: the blank panel bug produced correct HTML every time.

### log show does not work here

`log show` returned **zero** lines for the extension process while `log stream`
across the same preview captured everything. The extension is too short lived.
Related trap: `log show --start` interprets **local** time, so passing a UTC
timestamp silently matches nothing, which looks exactly like code that never
ran.

### Registration

```bash
pluginkit -mAD -v -i com.puiwaifu.QuickMark.PreviewExtension
```

This is the check, **not** `qlmanage -m plugins`. The latter only lists legacy
`.qlgenerator` plugins and will never show a modern extension, which makes a
healthy install look broken. Expect exactly one entry, pointing at
`~/Applications`. Two entries means the build copy got registered too.

### Rendering, without reinstalling

```bash
./Tools/render.sh Samples/kitchen-sink.md /tmp/preview.html
./Tools/render.sh --tree Samples/kitchen-sink.md      # parse tree with source locations
```

The `--tree` dump is how the list looseness rule was worked out; it prints every
node with its line and column range.

### qlmanage

`qlmanage -p file` shows a real preview window. `qlmanage -p -o dir` does
**not** work for a view based extension: it cannot serialise an `NSView` and
reports "did not produce any preview" even when everything is fine.

## Things to be aware of

Ordered roughly by how much time they can cost.

1. **The extension must be sandboxed.** Without
   `com.apple.security.app-sandbox` the appex has no container identity and
   `ExtensionFoundation` throws `key cannot be nil` building the XPC connection,
   before any of this code runs. Nothing renders and `pluginkit` never lists it.
2. **WKWebView needs `com.apple.security.network.client`**, even though the page
   is loaded from memory and fetches nothing. Without it the WebKit content
   process fails to launch (`WebProcessProxy::didFinishLaunching: Invalid
   connection identifier`) and the panel is blank while every other signal looks
   healthy.
3. **Generating HTML proves nothing.** Any check that stops at `loadHTMLString`
   passes with a permanently blank panel. Watch for `web view painted`.
4. **Never leave a second copy of the app registered.** Launch Services will
   register the build output under `.build/`, two bundles claim the same
   identifier, and Quick Look may resolve the one you are not updating.
5. **Quick Look caches the extension binary.** `install.sh` kills `pkd`,
   `quicklookd` and `QuickLookUIService`; skip that and you keep testing the
   previous build.
6. **The host app must be launched once** after a clean install before PlugInKit
   lists the extension. `install.sh` does this and polls for 15 seconds.
7. **`dyn.*` types do not match a `public.data` claim** despite conforming to
   it. This is why `.env.local` needs an exported UTI.
8. **Restricted entitlements need a real signing identity.** Adding a sandbox
   temporary exception to an ad hoc build does not fail gracefully; it gets the
   extension killed the moment it touches the file, with no error logged and no
   crash report written.
9. **Fire the completion handler from `didFinish`**, not from
   `preparePreviewOfFile`.
10. **Claiming `public.data` has reach.** Any extension-less file previews
    through QuickMark, and the exported dotenv type claims `.local`,
    `.production`, `.development` and `.staging` system-wide.

### Known limitations

* Local images do not render on an ad hoc signed build. Quick Look grants access
  to the previewed file alone, and the fix is a restricted entitlement. Remote
  `https:` images work.
* No syntax highlighting, Mermaid or KaTeX; all three need JavaScript.
* No Markdown footnotes; swift-markdown does not parse them.
* JSON strings show escapes as written (`é`, not `é`).
* `.env.example` is not claimed.
* EPUB: Zip64 and encrypted (DRM) archives are reported as unsupported rather
  than parsed. Embedded fonts are not used, since `font-src` is `'none'`.
* **Another app can take Markdown away.** QLMarkdown 1.5.2 is installed in
  `/Applications` and ships its own modern preview extension claiming
  `net.daringfireball.markdown`. When two extensions claim a type, macOS picks
  one, and it currently picks QLMarkdown. Choose between them in System Settings
  under General, Login Items & Extensions, Quick Look.
* Files with a specific UTI that has no better handler, such as an extension-less
  binary, reach the extension and get a "not a text file" panel rather than
  falling back to the system preview.

## Adding a new file type

1. **Decide how macOS types it.** `mdls -name kMDItemContentType <file>`. If it
   is a real type, claim it. If it is `dyn.*`, an exported UTI is needed. If it
   is `public.data`, it is already reaching the extension.
2. **Claim it** in `QLSupportedContentTypes`, plus
   `UTExportedTypeDeclarations` in the app's Info.plist if you had to invent a
   type.
3. **Add a case** to `PreviewKind` and a branch in `PreviewKind.detect`.
4. **Write the renderer** in a file free of Quartz, WebKit and AppKit, emitting
   an HTML fragment. Escape everything through `HTMLRenderer.escape`.
5. **Dispatch** to it in `HTMLPage.render(text:kind:…)`, and add the case to the
   switches in `PreviewViewController` and `Tools/render-main.swift`.
6. **Register the file** in `SHARED_RENDERER_SOURCES` in `generate_project.rb`,
   then run `./generate_project.sh`.
7. **Style it** with the existing theme tokens rather than literal colours.
8. **Add a sample** under `Samples/` covering the awkward cases.
9. **Verify** with `./Tools/render.sh` for looks, then `./install.sh` and a real
   preview, watching for `web view painted`.
