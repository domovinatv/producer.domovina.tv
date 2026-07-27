import Foundation

//
// main.swift — provjera R2 veze protiv stvarnog bucketa.
//
// Za razliku od `test_sigv4.sh`, koji potpisuje protiv AWS-ovih test vektora i ne
// dira mrežu, ovaj napravi pravi krug: PUT, GET, usporedba bajtova, DELETE. To je
// jedina provjera koja pokriva i potpis, i endpoint, i dopuštenja tokena
// odjednom — a upravo ta kombinacija pukne u praksi.
//
// Čita istu konfiguraciju koju čita i aplikacija, pa provjerava ono što će
// snimanje stvarno koristiti, a ne zasebnu kopiju postavki.
//

let appDomain = "tv.domovina.studio"

func fail(_ message: String) -> Never {
    print("❌ \(message)")
    exit(1)
}

// UserDefaults.standard ovdje pripada ovom programu, ne aplikaciji — zato
// eksplicitno njezina domena.
guard let defaults = UserDefaults(suiteName: appDomain) else {
    fail("Ne mogu otvoriti postavke domene \(appDomain).")
}
guard let data = defaults.data(forKey: "r2.configuration") else {
    fail("Nema R2 konfiguracije u \(appDomain). Pokreni prvo scripts/setup_r2.sh.")
}
guard let configuration = try? JSONDecoder().decode(R2Configuration.self, from: data) else {
    fail("R2 konfiguracija u \(appDomain) se ne može dekodirati.")
}

print("")
print("🔍 Provjera R2 veze")
print("   account:  \(configuration.accountID)")
print("   bucket:   \(configuration.bucket)")
print("   prefix:   \(configuration.prefix)")
print("   endpoint: \(configuration.endpoint?.absoluteString ?? "—")")
print("   key ID:   \(configuration.accessKeyID)")
print("   uključen: \(configuration.isEnabled), tijekom snimanja: \(configuration.uploadDuringRecording), masteri: \(configuration.uploadMastersAfterStop)")
print("")

guard configuration.isUsable else {
    fail("Konfiguracija nije potpuna (isEnabled/accountID/bucket/accessKeyID).")
}
guard R2ConfigurationStore.hasSecret(forAccessKeyID: configuration.accessKeyID) else {
    fail("Secret access key nije u Keychainu za \(configuration.accessKeyID).")
}

let client: R2Client
do {
    client = try R2Client(configuration: configuration)
} catch {
    fail(error.localizedDescription)
}

// Ključ ide pod prefiks koji koriste i sesije, pa provjera ujedno dokazuje da
// token smije pisati točno tamo gdje će snimanje pisati.
let key = "\(configuration.prefix)/_provjera/\(UUID().uuidString).txt"
let payload = Data("domovina studio — provjera veze \(Date())".utf8)

func signedRequest(method: String, url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    SigV4.sign(request: &request, payload: Data(), credentials: client.credentials)
    return request
}

func objectURL() -> URL {
    var components = URLComponents(url: configuration.endpoint!, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = "/" + configuration.bucket + "/" + key
        .split(separator: "/", omittingEmptySubsequences: false)
        .map { SigV4.uriEncode(String($0), encodeSlash: true) }
        .joined(separator: "/")
    return components.url!
}

do {
    try await client.verifyAccess()
    print("  ✅ LIST — token vidi bucket")

    try await client.putObject(data: payload, key: key, contentType: "text/plain")
    print("  ✅ PUT  — \(key)")

    let (fetched, response) = try await URLSession.shared.data(for: signedRequest(method: "GET", url: objectURL()))
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        fail("GET nije uspio: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
    }
    guard fetched == payload else {
        fail("GET je vratio \(fetched.count) B, poslano je \(payload.count) B — sadržaj se ne poklapa.")
    }
    print("  ✅ GET  — \(fetched.count) B, bajt u bajt isto")

    let (_, deleteResponse) = try await URLSession.shared.data(for: signedRequest(method: "DELETE", url: objectURL()))
    let deleteCode = (deleteResponse as? HTTPURLResponse)?.statusCode ?? -1
    guard deleteCode == 204 || deleteCode == 200 else {
        fail("DELETE nije uspio: HTTP \(deleteCode) — provjera je ostavila smeće u bucketu.")
    }
    print("  ✅ DELETE — počišćeno")
} catch {
    fail(error.localizedDescription)
}

print("")
print("✅ R2 je spreman. Snimanje će slati segmente u \(configuration.bucket)/\(configuration.prefix)/.")
print("")
exit(0)
