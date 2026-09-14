#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates QuickMark.xcodeproj from the sources on disk.
#
# The project file is derived, not hand edited, so adding a source file means
# dropping it in Sources/ and running this again. Invoke it through the wrapper
# so it picks up the xcodeproj gem that ships with the Homebrew CocoaPods:
#
#   ./generate_project.sh

require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path(__dir__)
PROJECT_PATH = File.join(ROOT, 'QuickMark.xcodeproj')

APP_NAME = 'QuickMark'
EXT_NAME = 'PreviewExtension'
CLI_NAME = 'qm-render'

# Renderer sources shared by the extension and the command line tool. Anything
# here must stay free of Quartz and WebKit so the tool keeps building.
SHARED_RENDERER_SOURCES = %w[
  HTMLRenderer.swift
  MarkdownDocument.swift
  HTMLPage.swift
  ImageInliner.swift
  TextPreview.swift
  JSONValue.swift
  JSONRenderer.swift
  ZIPArchive.swift
  EPUBDocument.swift
  EPUBRenderer.swift
].freeze
BUNDLE_ID = 'com.puiwaifu.QuickMark'
DEPLOYMENT_TARGET = '14.0'
MARKETING_VERSION = '1.0'
BUILD_VERSION = '1'
SWIFT_MARKDOWN_VERSION = '0.8.0'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '2660'
project.root_object.attributes['BuildIndependentTargetsInParallel'] = 'YES'
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en Base]

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

app_target = project.new_target(:application, APP_NAME, :osx, DEPLOYMENT_TARGET)
ext_target = project.new_target(:app_extension, EXT_NAME, :osx, DEPLOYMENT_TARGET)

# A command line build of the same renderer, so style.css can be iterated on
# without reinstalling the app and restarting Quick Look every time.
cli_target = project.new_target(:command_line_tool, CLI_NAME, :osx, DEPLOYMENT_TARGET)

# ---------------------------------------------------------------------------
# File references
# ---------------------------------------------------------------------------

sources_group = project.new_group('Sources', 'Sources')
app_group = sources_group.new_group('App', 'App')
ext_group = sources_group.new_group(EXT_NAME, EXT_NAME)
resources_group = ext_group.new_group('Resources', 'Resources')
tools_group = project.new_group('Tools', 'Tools')

def add_swift_sources(group, target, directory)
  Dir.glob(File.join(directory, '*.swift')).sort.map do |path|
    reference = group.new_file(File.basename(path))
    target.add_file_references([reference])
    [File.basename(path), reference]
  end.to_h
end

add_swift_sources(app_group, app_target, File.join(ROOT, 'Sources/App'))
ext_references = add_swift_sources(ext_group, ext_target, File.join(ROOT, 'Sources', EXT_NAME))

# The tool compiles the same renderer files, referenced once and built twice.
SHARED_RENDERER_SOURCES.each do |name|
  reference = ext_references.fetch(name)
  cli_target.add_file_references([reference])
end
cli_target.add_file_references([tools_group.new_file('render-main.swift')])

# Info.plist and entitlements are referenced by build settings, so they only
# need to appear in the navigator, not in a build phase.
app_group.new_file('Info.plist')
app_group.new_file("#{APP_NAME}.entitlements")
ext_group.new_file('Info.plist')
ext_group.new_file("#{EXT_NAME}.entitlements")

Dir.glob(File.join(ROOT, 'Sources', EXT_NAME, 'Resources', '*')).sort.each do |path|
  reference = resources_group.new_file(File.basename(path))
  ext_target.add_resources([reference])
end

# ---------------------------------------------------------------------------
# System frameworks
#
# Swift autolinking usually covers these, but naming them explicitly keeps the
# link deterministic and makes the dependency obvious in Xcode.
# ---------------------------------------------------------------------------

def link_system_framework(project, target, name)
  path = "System/Library/Frameworks/#{name}.framework"
  reference = project.frameworks_group.files.find { |file| file.path == path }
  unless reference
    reference = project.frameworks_group.new_file(path, :sdk_root)
    reference.name = "#{name}.framework"
  end
  target.frameworks_build_phase.add_file_reference(reference)
end

%w[Quartz WebKit AppKit].each { |name| link_system_framework(project, ext_target, name) }
link_system_framework(project, app_target, 'SwiftUI')

# ---------------------------------------------------------------------------
# swift-markdown, consumed by the extension
# ---------------------------------------------------------------------------

package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://github.com/apple/swift-markdown.git'
package.requirement = {
  'kind' => 'upToNextMajorVersion',
  'minimumVersion' => SWIFT_MARKDOWN_VERSION
}
project.root_object.package_references << package

# Each target gets its own product dependency object; Xcode does not share one
# across targets.
[ext_target, cli_target].each do |target|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = 'Markdown'
  target.package_product_dependencies << product

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

# ---------------------------------------------------------------------------
# Embed the extension in the app
# ---------------------------------------------------------------------------

embed_phase = app_target.new_copy_files_build_phase('Embed Foundation Extensions')
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_phase.dst_path = ''
embedded = embed_phase.add_file_reference(ext_target.product_reference)
embedded.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
app_target.add_dependency(ext_target)

# The embed phase has to run after the extension is copied in, and Xcode puts
# new copy phases last by default, which is what we want here.

# ---------------------------------------------------------------------------
# Build settings
# ---------------------------------------------------------------------------

COMMON_SETTINGS = {
  'ALWAYS_SEARCH_USER_PATHS' => 'NO',
  'CLANG_ENABLE_MODULES' => 'YES',
  'CLANG_ENABLE_OBJC_ARC' => 'YES',
  'CODE_SIGN_IDENTITY' => '-',
  'CODE_SIGN_STYLE' => 'Manual',
  'COMBINE_HIDPI_IMAGES' => 'YES',
  'CURRENT_PROJECT_VERSION' => BUILD_VERSION,
  'DEVELOPMENT_TEAM' => '',
  'ENABLE_HARDENED_RUNTIME' => 'NO',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'MACOSX_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
  'MARKETING_VERSION' => MARKETING_VERSION,
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'PROVISIONING_PROFILE_SPECIFIER' => '',
  'SDKROOT' => 'macosx',
  'SWIFT_EMIT_LOC_STRINGS' => 'NO',
  'SWIFT_VERSION' => '5.0'
}.freeze

DEBUG_SETTINGS = {
  'DEBUG_INFORMATION_FORMAT' => 'dwarf',
  'GCC_OPTIMIZATION_LEVEL' => '0',
  'ONLY_ACTIVE_ARCH' => 'YES',
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'DEBUG',
  'SWIFT_OPTIMIZATION_LEVEL' => '-Onone'
}.freeze

RELEASE_SETTINGS = {
  'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
  'ONLY_ACTIVE_ARCH' => 'NO',
  'SWIFT_COMPILATION_MODE' => 'wholemodule',
  'SWIFT_OPTIMIZATION_LEVEL' => '-O'
}.freeze

APP_SETTINGS = {
  'CODE_SIGN_ENTITLEMENTS' => "Sources/App/#{APP_NAME}.entitlements",
  'ENABLE_PREVIEWS' => 'YES',
  'INFOPLIST_FILE' => 'Sources/App/Info.plist',
  'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
  'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
  'SKIP_INSTALL' => 'NO'
}.freeze

EXT_SETTINGS = {
  'CODE_SIGN_ENTITLEMENTS' => "Sources/#{EXT_NAME}/#{EXT_NAME}.entitlements",
  'INFOPLIST_FILE' => "Sources/#{EXT_NAME}/Info.plist",
  'LD_RUNPATH_SEARCH_PATHS' => [
    '$(inherited)',
    '@executable_path/../Frameworks',
    '@executable_path/../../../../Frameworks'
  ],
  'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}.#{EXT_NAME}",
  'PRODUCT_MODULE_NAME' => EXT_NAME,
  'SKIP_INSTALL' => 'YES'
}.freeze

project.build_configurations.each do |configuration|
  configuration.build_settings.merge!(COMMON_SETTINGS)
  extra = configuration.name == 'Debug' ? DEBUG_SETTINGS : RELEASE_SETTINGS
  configuration.build_settings.merge!(extra)
end

CLI_SETTINGS = {
  'CODE_SIGN_ENTITLEMENTS' => '',
  'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}.render",
  'SKIP_INSTALL' => 'YES',
  'SWIFT_INSTALL_OBJC_HEADER' => 'NO'
}.freeze

[[app_target, APP_SETTINGS], [ext_target, EXT_SETTINGS], [cli_target, CLI_SETTINGS]].each do |target, settings|
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!(COMMON_SETTINGS)
    extra = configuration.name == 'Debug' ? DEBUG_SETTINGS : RELEASE_SETTINGS
    configuration.build_settings.merge!(extra)
    configuration.build_settings.merge!(settings)
  end
end

# ---------------------------------------------------------------------------
# Scheme, so `xcodebuild -scheme QuickMark` works without opening Xcode
# ---------------------------------------------------------------------------

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.set_launch_target(app_target)
scheme.save_as(PROJECT_PATH, APP_NAME, true)

cli_scheme = Xcodeproj::XCScheme.new
cli_scheme.add_build_target(cli_target)
cli_scheme.save_as(PROJECT_PATH, CLI_NAME, true)

puts "Wrote #{PROJECT_PATH}"
puts "  #{APP_NAME}         application        #{BUNDLE_ID}"
puts "  #{EXT_NAME} app extension      #{BUNDLE_ID}.#{EXT_NAME}"
puts "  #{CLI_NAME}        command line tool  renders Markdown to HTML"
