#!/usr/bin/env swift
import AppKit
import CoreImage
import Darwin
import Foundation

_ = umask(0o077)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pairing QR: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: render-pairing-qr.swift OUTPUT.png") }
let output = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let outputParent = output.deletingLastPathComponent().resolvingSymlinksInPath()
let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .resolvingSymlinksInPath()
guard output.pathExtension.lowercased() == "png" else { fail("output must be a PNG file") }
guard output.lastPathComponent != ".", output.lastPathComponent != "..",
      !output.lastPathComponent.contains("/")
else { fail("output filename is invalid") }
guard outputParent.path != repository.path,
      !outputParent.path.hasPrefix(repository.path + "/")
else { fail("pairing artifacts must stay outside the repository") }
let parentFD = open(outputParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
guard parentFD >= 0 else { fail("output parent must be an existing physical directory") }
defer { _ = close(parentFD) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty, input.count <= 4_096,
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      object["version"] as? Int == 1,
      object["base_url"] is String,
      object["spki_sha256"] is String,
      object["pairing_nonce"] is String,
      object["expires_at"] is String
else { fail("stdin is not a bounded v1 pairing payload") }
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(input, forKey: "inputMessage")
filter.setValue("Q", forKey: "inputCorrectionLevel")
guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
    fail("Core Image could not render the QR code")
}
let representation = NSBitmapImageRep(ciImage: image)
guard let png = representation.representation(using: .png, properties: [:]) else {
    fail("could not encode PNG")
}
let filename = output.lastPathComponent
let outputFD = openat(
    parentFD,
    filename,
    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
    mode_t(0o600)
)
guard outputFD >= 0 else { fail("output already exists or cannot be created safely") }
var publicationSucceeded = false
defer {
    _ = close(outputFD)
    if !publicationSucceeded {
        _ = unlinkat(parentFD, filename, 0)
    }
}

let writeSucceeded = png.withUnsafeBytes { rawBuffer -> Bool in
    guard let baseAddress = rawBuffer.baseAddress else { return png.isEmpty }
    var written = 0
    while written < rawBuffer.count {
        let result = Darwin.write(outputFD, baseAddress.advanced(by: written), rawBuffer.count - written)
        if result < 0 {
            if errno == EINTR { continue }
            return false
        }
        written += result
    }
    return true
}
guard writeSucceeded, fsync(outputFD) == 0 else { fail("could not publish output completely") }
publicationSucceeded = true
