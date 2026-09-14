# Image handling

A remote image over https, which the preview loads normally:

![Swift logo](https://raw.githubusercontent.com/apple/swift/main/docs/assets/swift-logo.png)

A sibling image referenced with a relative path:

![blue square](badge.png)

The sibling image renders as its alt text in a dashed box rather than as a
picture. That is expected on an ad hoc signed build: Quick Look grants the
sandboxed extension access to the previewed file and nothing else. See the
comment in `PreviewExtension.entitlements` for what it takes to change that.

Running the same file through `./Tools/render.sh` embeds the image properly,
because the command line tool is not sandboxed.
