#!/usr/bin/env swift
// Build script for Filesnake — replaces Makefile
// Usage:
//   swift build.swift              — debug build
//   swift build.swift release      — release build
//   swift build.swift open         — debug build + launch
//   swift build.swift install      — release build + copy to /Applications
//   swift build.swift uninstall    — remove from /Applications
//   swift build.swift release-zip  — release build + zip for GitHub
//   swift build.swift clean        — remove build/

import Foundation

// MARK: - Config

let appName    = "Filesnake"
let bundleID   = "com.filesnake.app"
let buildDir   = "build"
let appBundle  = "\(buildDir)/\(appName).app"
let macosDir   = "\(appBundle)/Contents/MacOS"
let resDir     = "\(appBundle)/Contents/Resources"
let plistSrc   = "Sources/Filesnake/Resources/Info.plist"
let iconSrc    = "Sources/Filesnake/Resources/AppIcon.icns"
let installDir = "/Applications"
let zipName    = "\(buildDir)/\(appName).zip"

// MARK: - Shell helpers

@discardableResult
func run(_ args: String..., allowFailure: Bool = false) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = args
    try? proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 && !allowFailure {
        fputs("Error: \(args.joined(separator: " ")) exited \(proc.terminationStatus)\n", stderr)
        exit(proc.terminationStatus)
    }
    return proc.terminationStatus
}

func shell(_ command: String) {
    run("sh", "-c", command)
}

let fm = FileManager.default

func mkdir(_ path: String) {
    try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func cp(_ src: String, _ dst: String) {
    try? fm.removeItem(atPath: dst)
    try? fm.copyItem(atPath: src, toPath: dst)
}

func rm(_ path: String) {
    try? fm.removeItem(atPath: path)
}

func exists(_ path: String) -> Bool {
    fm.fileExists(atPath: path)
}

// MARK: - Tasks

func bundle(config: String) {
    rm(appBundle)
    mkdir(macosDir)
    mkdir(resDir)
    cp(".build/\(config)/\(appName)", "\(macosDir)/\(appName)")
    cp(plistSrc, "\(appBundle)/Contents/Info.plist")
    if exists(iconSrc) {
        cp(iconSrc, "\(resDir)/AppIcon.icns")
        print("Icon bundled.")
    }

    print("Packaging Finder Sync Extension...")
    let extMacOS = "\(appBundle)/Contents/PlugIns/FilesnakeFinderExtension.appex/Contents/MacOS"
    mkdir(extMacOS)
    cp(".build/\(config)/FilesnakeFinderExtension",
       "\(extMacOS)/FilesnakeFinderExtension")
    cp("Sources/FilesnakeFinderExtension/Resources/Info.plist",
       "\(appBundle)/Contents/PlugIns/FilesnakeFinderExtension.appex/Contents/Info.plist")
    run("codesign", "-s", "-", "-f", "--entitlements", "ext.entitlements",
        "\(appBundle)/Contents/PlugIns/FilesnakeFinderExtension.appex")

    print("Bundle ready: \(appBundle)")
}

func debug() {
    print("Building (debug)...")
    run("swift", "build")
    bundle(config: "debug")
}

func release() {
    print("Building (release)...")
    run("swift", "build", "-c", "release")
    bundle(config: "release")
}

func open() {
    debug()
    print("Launching \(appBundle)...")
    run("open", appBundle)
}

func install() {
    release()
    print("Installing to \(installDir)...")
    rm("\(installDir)/\(appName).app")
    shell("cp -R \(appBundle) \(installDir)/\(appName).app")
    rm(buildDir)
    print("Installed: \(installDir)/\(appName).app")
    print("You can now launch Filesnake from Spotlight or the Dock.")
}

func uninstall() {
    print("Removing \(installDir)/\(appName).app...")
    rm("\(installDir)/\(appName).app")
    print("Uninstalled.")
}

func releaseZip() {
    release()
    print("Packaging for distribution...")
    rm(zipName)
    shell("cd \(buildDir) && zip -r --symlinks \(appName).zip \(appName).app")
    print("Ready for GitHub release: \(zipName)")
}

func clean() {
    rm(buildDir)
    run("swift", "package", "clean")
    print("Cleaned.")
}

// MARK: - Entry point

let command = CommandLine.arguments.dropFirst().first ?? "debug"

switch command {
case "debug":        debug()
case "release":      release()
case "open":         open()
case "install":      install()
case "uninstall":    uninstall()
case "release-zip":  releaseZip()
case "clean":        clean()
default:
    fputs("Unknown command: \(command)\n", stderr)
    fputs("Available: debug, release, open, install, uninstall, release-zip, clean\n", stderr)
    exit(1)
}
