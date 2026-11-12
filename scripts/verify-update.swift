// Verify against the public key embedded in the app, not merely the signing key.
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 4,
      let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fatalError("Usage: verify-update.swift PUBLIC_KEY ARCHIVE SIGNATURE")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard key.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the app's public key.\n", stderr)
    exit(1)
}
print("Update signature verified against the app's public key.")
