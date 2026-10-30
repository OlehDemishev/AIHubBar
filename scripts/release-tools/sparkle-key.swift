// Ed25519 keys and signatures for Sparkle updates, kept as a file instead of the login keychain.
//   swift sparkle-key.swift keygen          — make the key once (refuses to overwrite) and print the public key
//   swift sparkle-key.swift public          — print the public key (SUPublicEDKey)
//   swift sparkle-key.swift sign <file>     — print the update's signature (sparkle:edSignature)
//   swift sparkle-key.swift verify <file> <signature>
// The key lives in $CLAUDEPULT_RELEASE_DIR (default ~/Library/Application Support/ClaudePult-release). Back it up:
// without it, installed copies can't take updates.
import CryptoKit
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let dir = ProcessInfo.processInfo.environment["CLAUDEPULT_RELEASE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? home.appending(path: "Library/Application Support/ClaudePult-release")
let keyFile = dir.appending(path: "sparkle-ed25519.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("no key at \(keyFile.path) — run keygen") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    guard !FileManager.default.fileExists(atPath: keyFile.path) else { fail("a key already exists at \(keyFile.path); not overwriting") }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: keyFile.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { fail("usage: sign <file>") }
    print(try loadKey().signature(for: data).base64EncodedString())
case "verify":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let data = FileManager.default.contents(atPath: rest[0]), let signature = Data(base64Encoded: rest[1]) else { fail("usage: verify <file> <signature>") }
    print(loadKey().publicKey.isValidSignature(signature, for: data) ? "valid" : "INVALID")
default:
    fail("usage: keygen | public | sign <file> | verify <file> <signature>")
}
