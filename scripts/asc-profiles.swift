// Creates Developer ID provisioning profiles for both MacNTFS bundle IDs via
// the App Store Connect API and writes them to build/profiles/.
//
// Run through scripts/create-dev-id-profiles.sh, which requires:
//   ASC_KEY_PATH    path to the App Store Connect API key (.p8)
//   ASC_KEY_ID      the key's identifier
//   ASC_ISSUER_ID   the key's issuer identifier
//
// Developer ID profiles require no device registration, so the same profiles
// work on every machine and in CI. Existing profiles with the same names are
// downloaded instead of re-created.

import CryptoKit
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let keyPath = environment["ASC_KEY_PATH"], !keyPath.isEmpty,
      let keyID = environment["ASC_KEY_ID"], !keyID.isEmpty,
      let issuerID = environment["ASC_ISSUER_ID"], !issuerID.isEmpty else {
    FileHandle.standardError.write(Data("error: ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID must be set\n".utf8))
    exit(2)
}

let teamID = environment["DEVELOPMENT_TEAM"] ?? "D8UFJKPSQP"
let outputDirectory = URL(fileURLWithPath: environment["PROFILE_DIR"] ?? "build/profiles", isDirectory: true)

struct Targets {
    let appBundleID = "com.github.alvarolorentedev.macntfs"
    let extensionBundleID = "com.github.alvarolorentedev.macntfs.ntfsmodule"
    let appProfileName = "MacNTFS App Developer ID"
    let extensionProfileName = "MacNTFS Extension Developer ID"
}
let targets = Targets()

// MARK: - JWT

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

// MARK: - API client

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

func findCertificateIDs() throws -> [String] {
    let json = try apiRequest("GET", "/v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION&limit=200")
    guard let items = json["data"] as? [[String: Any]] else { try fail("no certificate list in response") }
    print("Developer ID Application certificates in account: \(items.count)")
    for item in items {
        let attributes = item["attributes"] as? [String: Any]
        let name = attributes?["displayName"] as? String ?? attributes?["name"] as? String ?? "(unnamed)"
        print("  - \(name) [\(item["id"] as? String ?? "?")]")
    }
    let ids = items.compactMap { $0["id"] as? String }
    guard !ids.isEmpty else {
        try fail("no Developer ID Application certificate found for team \(teamID) in the account")
    }
    return ids
}

func findBundleID(_ identifier: String) throws -> String {
    let json = try apiRequest("GET", "/v1/bundleIds?filter[identifier]=\(identifier)&limit=10")
    guard let items = json["data"] as? [[String: Any]], let bundle = items.first, let id = bundle["id"] as? String else {
        try fail("bundle ID \(identifier) is not registered in this account")
    }
    return id
}

func findExistingProfileIDs(named name: String) throws -> [String] {
    let json = try apiRequest("GET", "/v1/profiles?limit=200")
    guard let items = json["data"] as? [[String: Any]] else { return [] }
    return items.compactMap { item in
        guard (item["attributes"] as? [String: Any])?["name"] as? String == name,
              let id = item["id"] as? String else { return nil }
        return id
    }
}

func deleteProfile(id: String) throws {
    _ = try apiRequest("DELETE", "/v1/profiles/\(id)")
}

func createProfile(name: String, bundleID: String, certificateIDs: [String]) throws -> Data {
    let body: [String: Any] = [
        "data": [
            "type": "profiles",
            "attributes": [
                "name": name,
                "profileType": "MAC_APP_DIRECT",
            ],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": bundleID]],
                "certificates": ["data": certificateIDs.map { ["type": "certificates", "id": $0] }],
            ],
        ],
    ]
    let json = try apiRequest("POST", "/v1/profiles", body: body)
    guard let attributes = (json["data"] as? [String: Any])?["attributes"] as? [String: Any],
          let content = attributes["profileContent"] as? String,
          let data = Data(base64Encoded: content) else {
        try fail("created profile \(name) has no content")
    }
    print("profile: \(name) (created)")
    return data
}

func fail(_ message: String) throws -> Never {
    throw NSError(domain: "asc", code: -4, userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - Run

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let certificateIDs = try findCertificateIDs()
for (bundleID, profileName, fileName) in [
    (targets.appBundleID, targets.appProfileName, "MacNTFS-App.provisionprofile"),
    (targets.extensionBundleID, targets.extensionProfileName, "MacNTFS-Extension.provisionprofile"),
] {
    let bundleResourceID = try findBundleID(bundleID)
    for existingID in try findExistingProfileIDs(named: profileName) {
        print("profile: \(profileName) (removing existing \(existingID))")
        try deleteProfile(id: existingID)
    }
    let content = try createProfile(name: profileName, bundleID: bundleResourceID, certificateIDs: certificateIDs)
    let destination = outputDirectory.appendingPathComponent(fileName)
    try content.write(to: destination)
    print("written: \(destination.path)")
}
print("done")
