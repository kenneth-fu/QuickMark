# QuickMark

Press Space on a `.md`, `.json`, `.epub` or `.env` file in Finder and read the
file, instead of its raw source.

## Why this exists

Quick Look is one of the best things about the Mac. Select a file, tap Space,
see the file. It is instant, it needs no app, and for images, PDFs and video it
is perfect.

Then you tap Space on the files you actually work in all day:

* **Markdown** comes back as raw source. Every `#`, every `*`, every `|`, with
  tables as unaligned pipe soup and links as bracket noise. A README is a
  document, and Quick Look hands you the markup instead of the document.
* **JSON** comes back with no structure at all. No collapsing, no colour, no
  way to see the shape of a document at a glance, and a minified file is just a
  wall of text.
* **`.env`, `Dockerfile`, `.gitignore`** and friends get no useful preview at
  all, because a name with no extension is a type macOS does not recognise.

The workaround is to open a real editor, which is a heavy thing to do when the
question was only ever "what is in this file". That small friction, dozens of
times a day, is the entire reason this project exists.

QuickMark closes it. One preview extension that renders all of these, in one
theme that follows light and dark mode, with no JavaScript anywhere in it.

### Compared with QLMarkdown

[QLMarkdown](https://github.com/sbarex/QLMarkdown) is the established Markdown
previewer and it is actively maintained. For Markdown alone it goes deeper than
this does: syntax highlighted code, wikilinks, definition lists, configurable
themes, and 17 claimed content types covering the dialects, from Typora to
Quarto to R Markdown.

QuickMark covers more formats rather than more Markdown. Its six claimed types
span four file formats plus every extension-less text file on the system:

| | QuickMark | QLMarkdown |
| --- | --- | --- |
| Markdown | yes | yes, more dialects and features |
| JSON | yes | no |
| EPUB | yes | no |
| dotenv | yes | no |
| `Dockerfile`, `.gitignore`, extension-less text | yes | no |

Both can be installed at once, but only one can own Markdown: when two
extensions claim a content type, macOS picks one of them. If Markdown previews
stop coming from QuickMark, that is why. Choose between them in System Settings,
under General, Login Items & Extensions, Quick Look.

## Install

```bash
./install.sh
```

Then select a `.md`, `.json`, `.epub` or `.env` file in Finder and press Space.

## What it renders

Parsing is Apple's [swift-markdown](https://github.com/apple/swift-markdown)
(cmark-gfm underneath), so CommonMark plus the GitHub extensions:

* Headings, emphasis, strikethrough, inline and fenced code
* Tables, including per column alignment
* Task lists, rendered as disabled checkboxes
* Blockquotes, and GitHub alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`)
* YAML front matter, shown as a header block instead of leaking into the body
* Bare URLs, linkified (cmark's autolink extension is off in swift-markdown, so
  QuickMark does this itself)
* Light and dark appearance, following the system

Not yet: syntax highlighting, Mermaid diagrams, KaTeX math. All three need
JavaScript in the preview, which is deliberately switched off today (see
Security below).

## EPUB

`.epub` renders as the book's cover, its metadata, its table of contents, and as
much of the text as the budget allows.

* The archive is read **entirely in memory**. Nothing is unpacked to disk, so
  there is no temporary directory to be denied by the sandbox and nothing to
  clean up. `ZIPArchive.swift` is a small read only ZIP reader over Apple's
  `Compression` framework; only stored and deflate entries are supported, which
  is all EPUB uses.
* Both EPUB 2 and EPUB 3 are handled: the table of contents comes from an EPUB 3
  `nav` document or an EPUB 2 NCX, and the cover from either a manifest
  `cover-image` property or the older `<meta name="cover">`.
* The book's own CSS is stripped and QuickMark's theme applied, so every book
  looks the same rather than each one bringing its own fonts and colours.
* Chapter markup is **sanitised by removal**, not by escaping: scripts, styles,
  frames, embedded media, event handlers and `javascript:` URLs are deleted.
  Images inside the archive are embedded as data URIs, since the web view cannot
  reach inside the zip.
* Capped at 30 documents or 300,000 characters of chapter HTML, whichever comes
  first, and it says how many of the book's documents it showed.

`org.idpf.epub-container` is an Apple defined type and nothing else on this
system claims it. Parsing reads only the `.epub` file itself, which Quick Look
already grants, so **no new entitlement is involved**.

## JSON

`.json` renders as a syntax coloured, collapsible tree. Collapsing uses native
`<details>` elements, so the disclosure triangles work with JavaScript off,
which it is everywhere in this preview.

* **Member order is preserved**, and numbers and strings keep their original
  source text. `JSONSerialization` would reorder keys, turn `1.50` into `1.5`
  and `6.02e23` into `6.02e+23`, so `JSONValue.swift` parses by hand instead.
* Documents up to 400 values open fully expanded; larger ones keep the first two
  levels open and collapse the rest, so a big file lands on something readable.
  A collapsed node shows what it is hiding, for example `{ 3 keys }`.
* Array elements are numbered when they are objects or arrays, so a long list
  does not read as `{ 3 keys }` two hundred times. Arrays of plain strings stay
  unnumbered.
* Rendering stops at 20000 values and says so, rather than building a DOM large
  enough to hit the preview timeout.
* A file that does not parse shows the reason with line and column, for example
  `Trailing comma in array at line 3, column 21`, and then renders the raw text
  underneath so the problem can be found by eye.

`public.json` is a real Apple defined type, so this claim is exact and takes
nothing else with it. Add `public.geojson` alongside it in
`Sources/PreviewExtension/Info.plist` for `.geojson` files.

## .env and other extension-less files

`.env` files render as a key and value table, with comments, `export` prefixes,
quoted values and inline comments handled. Any other extension-less text file
(`Dockerfile`, `.gitignore`, `.bashrc`, `Procfile`) renders as plain text with
line numbers, capped at 5000 lines.

**Values are shown in full, not masked.** A `.env` usually holds live API keys
and database passwords, and pressing Space in Finder puts them straight on
screen, including during a screen share. That is a deliberate choice; masking
sensitive looking values is a small change in `DotEnvRenderer`.

Two different mechanisms are needed, because macOS types these files two
different ways:

| file | type | reached by |
| --- | --- | --- |
| `.env`, `.gitignore`, `Dockerfile` | `public.data` | the `public.data` claim |
| `.env.local`, `.env.production`, `config.env` | `com.puiwaifu.quickmark.dotenv` | the exported type in the app's `Info.plist` |

A leading dot name has no extension macOS recognises, so `.env` is typed as
plain data. A name like `.env.local` does have an extension, gets a synthesized
`dyn.*` type, and a `public.data` claim does **not** match it even though it
conforms. Hence the exported type, which claims `env`, `local`, `production`,
`development` and `staging` system-wide. `.env.example` is deliberately not
claimed, since `.example` collides more widely; add it to the list if you want
it.

Consequences of the `public.data` claim:

* Quick Look prefers the most specific match, so images, PDFs and anything else
  with a real type still go to their own handlers. QuickMark only picks up files
  nothing else claims.
* Files that are not text do reach the extension. It samples the first 8 KB, and
  anything with a NUL byte or undecodable bytes gets a short "not a text file"
  panel instead of a screen of mojibake.

To go back to Markdown only, delete `public.data` and
`com.puiwaifu.quickmark.dotenv` from `QLSupportedContentTypes` in
`Sources/PreviewExtension/Info.plist`, drop `UTExportedTypeDeclarations` from
`Sources/App/Info.plist`, and reinstall.

## Local images

Local images do not render. They fall back to their alt text in a dashed box.

Quick Look hands a sandboxed preview extension access to the previewed file and
nothing else, so `![](diagram.png)` sitting next to the document is unreadable.
Remote `https:` images do load.

The fix is a read only sandbox temporary exception, and it needs a real signing
identity. On an ad hoc signed build the entitlement does not just fail to grant
access, it gets the extension killed the moment it touches a sibling file, with
no error logged and no crash report. Details are in
`Sources/PreviewExtension/PreviewExtension.entitlements`. The image code is
already in place, so adding Developer ID signing turns images on with no code
change.

## Design notes

[DESIGN.md](DESIGN.md) covers the internals: process model, UTI routing, the
rendering pipeline, the security model, measured performance, and the macOS
specifics that are easy to lose a day to.

## Layout

```
Sources/App/                 host app: registration status and instructions
Sources/PreviewExtension/    the Quick Look extension
  HTMLRenderer.swift         MarkupVisitor that emits HTML
  MarkdownDocument.swift     file loading, encoding fallback, front matter
  HTMLPage.swift             assembles the page, inlines the stylesheet
  ImageInliner.swift         embeds readable images as data URIs
  PreviewViewController.swift  QLPreviewingController hosting a WKWebView
  Resources/style.css        the theme
Tools/                       qm-render, the command line renderer
Samples/                     test documents
generate_project.rb          writes QuickMark.xcodeproj
install.sh                   build, install, re-register
```

`QuickMark.xcodeproj` is generated, not checked in. Add a source file to
`Sources/` and run `./generate_project.sh` to pick it up.

## Working on the theme

Reinstalling the extension and restarting Quick Look on every CSS tweak is slow.
The same renderer is also built as a command line tool:

```bash
./Tools/render.sh Samples/kitchen-sink.md /tmp/preview.html
```

Open that in a browser and iterate. `Samples/kitchen-sink.md` exercises every
construct the renderer handles.

To see why a block rendered the way it did, dump the parse tree with source
locations:

```bash
./Tools/render.sh --tree Samples/kitchen-sink.md
```

## Security

A preview runs against files that arrive from anywhere, including email
attachments and downloads, so the preview is a renderer and not a browser:

* JavaScript is disabled in the web view
* A restrictive Content Security Policy allows `data:` and `https:` images and
  nothing else, no scripts, no fonts, no frames
* Raw HTML in the Markdown is passed through, except that `script`, `iframe`,
  `object`, `embed`, `form`, `style` and friends, `javascript:` URLs, and inline
  `on*=` handlers are escaped into visible text
* URL schemes outside `http`, `https`, `mailto`, `file` and `data` are dropped
* Navigation is cancelled, so a document cannot move the panel elsewhere

Enabling JavaScript for Mermaid or KaTeX means revisiting all of this.

## Notes for future work

Things worth knowing before changing the plumbing, each of which cost real time
to find:

* **WKWebView needs `com.apple.security.network.client`**, even though the page
  is loaded from memory and fetches nothing. Without it WebKit's content process
  fails to launch (`WebProcessProxy::didFinishLaunching: Invalid connection
  identifier`), and the panel is blank. Everything upstream looks healthy: the
  extension registers, the HTML is generated, no error is raised. Only
  `didFinish` never fires, which is why the delegate logs when it does.
* **Generating HTML is not evidence the preview works.** The blank panel failure
  above is invisible to any check that stops at `loadHTMLString`. The signal to
  look for is the `web view painted` log line.
* **`log show` does not reliably capture a short lived extension.** It returned
  zero lines for the extension process while `log stream` running across the
  same preview captured everything. Use `log stream` and start it before the
  preview:
  `log stream --level debug --predicate 'subsystem == "com.puiwaifu.QuickMark"'`
* **Never leave a second copy of the app registered.** Launch Services will
  happily register the build output under `.build/`, two bundles then claim the
  same identifier, and Quick Look may resolve the one you are not updating.
  `install.sh` unregisters and deletes the build copy for this reason. After a
  clean install the app also has to be launched once before `pluginkit` lists
  the extension.
* **The extension must be sandboxed.** Without `com.apple.security.app-sandbox`
  the appex has no container identity, and `ExtensionFoundation` throws
  `key cannot be nil` building the XPC connection before any of this code runs.
  Quick Look shows nothing and `pluginkit` never lists the extension.
* **`pluginkit -m` is the registration check**, not `qlmanage -m plugins`. The
  latter only lists legacy generators and will never show a modern extension,
  which makes a perfectly healthy install look broken.
* **`qlmanage -p -o <dir>` cannot serialise a view based preview** and reports
  "did not produce any preview" even when the extension works. Use `qlmanage -p`
  and watch the window, or check the log.
* **`log show --start` interprets local time.** Passing a UTC timestamp there
  silently matches nothing, which looks exactly like an extension that never
  ran.
* **Quick Look caches the extension binary.** `install.sh` kills `pkd`,
  `quicklookd` and `QuickLookUIService`; skip that and you will keep testing the
  previous build.
* **Fire the completion handler from `didFinish`**, not from
  `preparePreviewOfFile`. Calling it early snapshots a blank web view.

## License

MIT, see [LICENSE](LICENSE).

The one runtime dependency, Apple's
[swift-markdown](https://github.com/apple/swift-markdown), is Apache 2.0, which
is compatible. It is fetched by Swift Package Manager rather than vendored, so
no third party source is redistributed in this repository.
