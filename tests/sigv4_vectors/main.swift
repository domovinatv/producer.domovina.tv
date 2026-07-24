import Foundation

// AWS's published S3 SigV4 examples. Note the secret in these examples is
// ...MDENG/bPxRfi... with a SLASH, not the '+' used in most other AWS samples.
let credentials = SigV4.Credentials(
    accessKeyID: "AKIAIOSFODNN7EXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
)
var components = DateComponents()
components.year = 2013; components.month = 5; components.day = 24
components.hour = 0; components.minute = 0; components.second = 0
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
let date = calendar.date(from: components)!

var failures = 0

func check(_ name: String, _ urlString: String, headers: [String: String], expected: String) {
    var request = URLRequest(url: URL(string: urlString)!)
    request.httpMethod = "GET"
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    SigV4.sign(request: &request, payload: Data(), credentials: credentials,
               date: date, region: "us-east-1", service: "s3")
    let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
    if authorization.contains("Signature=\(expected)") {
        print("✅ \(name)")
    } else {
        print("❌ \(name)\n   dobiveno: \(authorization)\n   očekivano Signature=\(expected)")
        failures += 1
    }
}

// example2: GET Object with a Range header
check("GET Object (Range header)",
      "https://examplebucket.s3.amazonaws.com/test.txt",
      headers: ["Range": "bytes=0-9"],
      expected: "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")

// example4: GET Bucket Lifecycle — a valueless query parameter
check("GET Bucket Lifecycle (?lifecycle=)",
      "https://examplebucket.s3.amazonaws.com/?lifecycle=",
      headers: [:],
      expected: "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")

// example5: List Objects — two query parameters, which must be sorted by name
check("List Objects (?prefix=J&max-keys=2)",
      "https://examplebucket.s3.amazonaws.com/?prefix=J&max-keys=2",
      headers: [:],
      expected: "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")

// URI encoding: unreserved characters stay literal, everything else is escaped.
for (input, encodeSlash, want) in [
    ("a b", true, "a%20b"),
    ("audio/mic-1.wav", false, "audio/mic-1.wav"),
    ("audio/mic-1.wav", true, "audio%2Fmic-1.wav"),
    ("Epizoda~42_final.mov", true, "Epizoda~42_final.mov"),
    ("č", true, "%C4%8D"),
] {
    let got = SigV4.uriEncode(input, encodeSlash: encodeSlash)
    if got != want {
        print("❌ uriEncode(\"\(input)\") = \"\(got)\", očekivano \"\(want)\"")
        failures += 1
    }
}
if failures == 0 { print("✅ URI encoding") }

print("")
print(failures == 0 ? "🏁 Svi SigV4 testovi prošli." : "🛑 \(failures) neuspješnih.")
exit(failures == 0 ? 0 : 1)
