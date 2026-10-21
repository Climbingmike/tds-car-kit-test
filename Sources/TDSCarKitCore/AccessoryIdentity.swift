import Foundation
import Security

/// Uses an X9.63 EC private-key representation and RFC4754 signatures.
/// Keys are supplied locally; no identity is embedded in this source file.
public final class AccessoryIdentity {
    public let certificateChain: Data
    private let key: SecKey
    private let publicKey: SecKey

    public init(certificateChain: Data, leafCertificate: Data, privateKeyX963: Data) throws {
        guard certificateChain.count <= 65536, privateKeyX963.count == 97,
              let certificate = SecCertificateCreateWithData(nil, leafCertificate as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else {
            throw ProtocolError.malformed("accessory identity encoding")
        }
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256
        ]
        guard let key = SecKeyCreateWithData(privateKeyX963 as CFData, attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw ProtocolError.malformed("EC private key")
        }
        self.key = key; self.publicKey = publicKey; self.certificateChain = certificateChain
        let challenge = Data(repeating: 0x5a, count: 32)
        let signature = try sign(challenge: challenge)
        guard SecKeyVerifySignature(publicKey, .ecdsaSignatureRFC4754, challenge as CFData, signature as CFData, &error) else {
            throw ProtocolError.malformed("certificate does not match private key")
        }
    }
    public func sign(challenge: Data) throws -> Data {
        guard challenge.count == 32 else { throw ProtocolError.malformed("MFi v3 challenge must be 32 bytes") }
        var error: Unmanaged<CFError>?
        guard let result = SecKeyCreateSignature(key, .ecdsaSignatureRFC4754, challenge as CFData, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw ProtocolError.malformed("ECDSA signing failed")
        }
        return result as Data
    }
}
