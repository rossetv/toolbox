// Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

import CoreGraphics
import Foundation
import PDFKit

/// A headless self-test that runs the **real** compress path — bundled gs via `Bundle.main`,
/// inside the seatbelt sandbox — from the **actual app process** (not xctest). This is the M1
/// proof that app-spawns-gs works (xctest launches gs from a different context) and the CI
/// smoke (plan S.5). Triggered by `TOOLBOX_SMOKE=compress`; prints a one-line result and
/// exits. The input is synthetic, in the app's temp dir (never a TCC-scoped user folder).
enum CompressSmoke {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["TOOLBOX_SMOKE"] == "compress" else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1
        Task.detached {
            exitCode = await run()
            semaphore.signal()
        }
        // Bounded: a hung smoke must fail the gate, not park it forever. Twice the gs
        // wall-clock timeout leaves the engine's own 300 s watchdog room to fire first.
        if semaphore.wait(timeout: .now() + 600) == .timedOut {
            FileHandle.standardError.write(Data("SMOKE TIMEOUT\n".utf8))
            exit(1)
        }
        exit(exitCode)
    }

    private static func run() async -> Int32 {
        do {
            let runner = try GhostscriptRunner()
            let engine = CompressEngine(runner: runner)

            let input = try syntheticImagePDF()
            let output = input.deletingLastPathComponent().appendingPathComponent("smoke-compressed.pdf")

            let before = fileSize(input)
            let outcome = try await engine.compress(input, preset: .balanced, to: output) { _ in }

            switch outcome {
            case .compressed(let b, let a):
                let inPages = PDFDocument(url: input)?.pageCount ?? -1
                let outPages = PDFDocument(url: output)?.pageCount ?? -2
                guard a < b, inPages == outPages, outPages > 0 else {
                    FileHandle.standardError.write(Data("SMOKE FAIL: bad result \(b)->\(a) pages \(inPages)/\(outPages)\n".utf8))
                    return 1
                }
                print("SMOKE PASS: app-spawned gs under sandbox compressed \(b) -> \(a) bytes, \(outPages) page(s) preserved")
                return 0
            // `.compressedHeavy` is not compiler-forced here (this `default:` already absorbs it),
            // but the smoke's synthetic gradient input is Rung-1-only, so the engine's Task-4
            // pass-through body never produces it — the smoke deliberately treats it as the same
            // unexpected-outcome failure as any other case it doesn't test for.
            default:
                FileHandle.standardError.write(Data("SMOKE FAIL: unexpected outcome \(outcome) (input was \(before) bytes)\n".utf8))
                return 1
            }
        } catch {
            FileHandle.standardError.write(Data("SMOKE FAIL: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// A compact high-DPI gradient image PDF (temp dir) — genuinely shrinks under `/ebook`.
    private static func syntheticImagePDF() throws -> URL {
        let pxW = 1600, pxH = 2100
        let bytesPerRow = pxW * 4
        let byteCount = bytesPerRow * pxH
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        defer { buffer.deallocate() }
        memset(buffer, 0, byteCount)

        let colourSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(data: buffer, width: pxW, height: pxH, bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow, space: colourSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CompressError.validationFailed
        }
        for row in 0..<pxH {
            let t = Double(row) / Double(pxH)
            bitmap.setFillColor(CGColor(red: CGFloat(0.2 + 0.6 * t), green: CGFloat(0.4 + 0.3 * t),
                                        blue: CGFloat(0.7 - 0.4 * t), alpha: 1))
            bitmap.fill(CGRect(x: 0, y: row, width: pxW, height: 1))
        }
        // Deterministic grain so the original doesn't trivially compress.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < byteCount {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            bytes[i] = UInt8(seed & 0xFF)
            i += 7
        }
        guard let image = bitmap.makeImage() else { throw CompressError.validationFailed }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("smoke-input.pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw CompressError.validationFailed
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: CGRect(x: 18, y: 18, width: 576, height: 756))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
