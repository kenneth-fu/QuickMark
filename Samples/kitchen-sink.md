---
title: QuickMark Kitchen Sink
author: Kenneth Fu
status: draft
tags: markdown, quicklook, macos
---

# QuickMark Kitchen Sink

A single file that exercises everything the renderer is supposed to handle.
Press Space on it in Finder and compare against this list.

## Inline formatting

Regular text, **bold**, *italic*, ***both***, ~~struck through~~, `inline code`,
and a [link to Apple](https://www.apple.com). An autolink:
https://github.com/apple/swift-markdown

A hard break at the end of this line,
then the continuation.

## Headings

### Third level

#### Fourth level

##### Fifth level

###### Sixth level

## Lists

Unordered, with nesting:

- First item
- Second item
  - Nested child
  - Another child
    - Deeper still
- Third item

Ordered, starting at 3:

3. Three
4. Four
5. Five

Task list:

- [x] Parse Markdown with swift-markdown
- [x] Emit HTML from a MarkupVisitor
- [ ] Syntax highlighting
- [ ] Mermaid diagrams
- [ ] KaTeX math

Loose list, which should breathe more than a tight one:

- Paragraph one of the first item.

- Paragraph one of the second item.

## Code

Fenced with a language tag:

```swift
struct HTMLRenderer: MarkupVisitor {
    typealias Result = String

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = renderChildren(of: heading)
        return "<h\(heading.level)>\(inner)</h\(heading.level)>"
    }
}
```

Fenced without one:

```
$ xcodebuild -scheme QuickMark -configuration Release build
```

Indented:

    let indented = "four spaces"

## Quotes and alerts

> A plain blockquote.
> It can span several lines and still read as one block.

> [!NOTE]
> Useful information a reader should notice even when skimming.

> [!TIP]
> Optional advice that helps a reader do better.

> [!IMPORTANT]
> Key information a reader needs to get the outcome they want.

> [!WARNING]
> Urgent information that needs immediate attention.

> [!CAUTION]
> Advises about risks or negative outcomes of an action.

## Tables

| Feature | Status | Notes |
| --- | :---: | ---: |
| GFM tables | Done | Including alignment |
| Task lists | Done | Rendered as disabled checkboxes |
| Front matter | Done | Shown as a header block |
| Mermaid | Pending | Needs JavaScript enabled |
| KaTeX | Pending | Needs bundled fonts |

## Escaping

These should render as literal text, not as markup:
`<script>alert(1)</script>`, `&amp;`, `<img src=x onerror=y>`.

Raw HTML that is safe passes through: <kbd>Space</kbd> and <sub>subscript</sub>.

Raw HTML that is not safe gets escaped instead:

<script>alert("this should be visible as text, not run")</script>

## Horizontal rule

---

## Long line handling

Averyveryverylongunbrokenstringofcharactersthatshouldwrapratherthanforcingthepreviewpaneltoscrollsidewaysbecausethatwouldlookwrong.

## Empty edge cases

An empty link: []()

An image with no source: ![alt text]()
