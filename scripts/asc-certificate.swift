// Creates a Developer ID Application certificate from a CSR via the App Store
// Connect API.
//
// Run through scripts/create-dev-id-certificate.sh, which fills in:
//   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID   API key credentials
//   CSR_PATH                                   PEM certificate signing request
//   CERT_DER_PATH                              where the DER certificate is written

import CryptoKit
import Foundation

do {
    let environment = ProcessInfo.processInfo.environment
    guard let keyPath = environment["ASC_KEY_PATH"], !keyPath.isEmpty,
          let keyID = environment["ASC_KEY_ID"], !keyID.isEmpty,
          let issuerID = environment["ASC_ISSUER_ID"], !issuerID.isEmpty,
          let csrPath = environment["CSR_PATH"], !csrPath.isEmpty,
          let certPath = environment["CERT_DER_PATH"], !certPath.isEmpty else {
        FileHandle.standardError.write(Data("error: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, CSR_PATH and CERT_DER_PATH must be set\n".utf8))
        exit(2)
    }

    func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func makeToken() throws -> String {
        let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
        let now = Int(Date().timeIntervalSince1970)
        let payload = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 1200),"aud":"appstoreconnect-v1"}"#
        let signingInput = "\(base64URL(Data(header.utf8))).\(base64URL(Data(payload.utf8)))"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    let token = try makeToken()
    let session = URLSession.shared

    func apiRequest(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error>?
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let message: String
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let detail = (json["errors"] as? [[String: Any]])?.first?["detail"] as? String {
                    message = detail
                } else {
                    message = "HTTP \(http.statusCode)"
                }
                result = .failure(NSError(domain: "asc", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
                return
            }
            guard let data, !data.isEmpty else {
                result = .success([:])
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(NSError(domain: "asc", code: -1, userInfo: [NSLocalizedDescriptionKey: "unreadable response"]))
                return
            }
            result = .success(json)
        }.resume()
        semaphore.wait()
        switch result {
        case .success(let json): return json
        case .failure(let error): throw error
        case nil: throw NSError(domain: "asc", code: -2, userInfo: [NSLocalizedDescriptionKey: "no response"])
        }
    }

    let csr = try String(contentsOfFile: csrPath, encoding: .utf8)
    let body: [String: Any] = [
        "data": [
            "type": "certificates",
            "attributes": [
                "csrContent": csr,
                "certificateType": "DEVELOPER_ID_APPLICATION",
            ],
        ],
    ]
    let response = try apiRequest("POST", "/v1/certificates", body: body)
    guard let attributes = (response["data"] as? [String: Any])?["attributes"] as? [String: Any],
          let content = attributes["certificateContent"] as? String,
          let der = Data(base64Encoded: content) else {
        FileHandle.standardError.write(Data("error: certificate creation returned no content\n".utf8))
        exit(1)
    }
    try der.write(to: URL(fileURLWithPath: certPath))
    print("certificate created")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
