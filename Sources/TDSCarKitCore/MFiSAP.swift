// SPDX-License-Identifier: GPL-3.0-or-later
// Native Swift adaptation of the MFiSAP message construction described by
// PlayPort / DiPlay / xcertplay's MfiSapAuthSetup.kt. See THIRD_PARTY_NOTICES.txt.
import Foundation
import CryptoKit
#if SWIFT_PACKAGE
import CTDSCarKitCrypto
#endif

public enum MFiSAP {
    public static func respond(to request: Data, identity: AccessoryIdentity) throws -> Data {
        guard request.count == 33, request.first == 1 else { throw ProtocolError.malformed("MFiSAP version/public key") }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.dropFirst())
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer)
        let secret = shared.withUnsafeBytes { Data($0) }
        guard secret.contains(where: { $0 != 0 }) else { throw ProtocolError.malformed("MFiSAP zero shared secret") }
        let publicKey = ephemeral.publicKey.rawRepresentation
        let key = Data(Insecure.SHA1.hash(data: Data("AES-KEY".utf8) + secret).prefix(16))
        let iv = Data(Insecure.SHA1.hash(data: Data("AES-IV".utf8) + secret).prefix(16))
        let digest = Data(SHA256.hash(data: publicKey + peer.rawRepresentation))
        let signature = try identity.sign(challenge: digest)
        let encrypted = try aesCTR(key: key, iv: iv, data: signature)
        var response = publicKey
        response.putBE32(UInt32(identity.certificateChain.count)); response.append(identity.certificateChain)
        response.putBE32(UInt32(encrypted.count)); response.append(encrypted)
        return response
    }
    static func aesCTR(key: Data, iv: Data, data: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw ProtocolError.malformed("AES dimensions") }
        if data.isEmpty { return Data() }
        var output = Data(count: data.count)
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in data.withUnsafeBytes { d in
            output.withUnsafeMutableBytes { o in
                tds_car_kit_aes_ctr(k.bindMemory(to: UInt8.self).baseAddress!, v.bindMemory(to: UInt8.self).baseAddress!,
                    d.bindMemory(to: UInt8.self).baseAddress!, data.count, o.bindMemory(to: UInt8.self).baseAddress!)
            }
        } } }
        guard status == 0 else { throw ProtocolError.malformed("AES-CTR failure \(status)") }
        return output
    }
}
