import Foundation
import Testing
@testable import DownloadModels

/// Expiry detection across the pre-signed / tokened URL formats the major object stores and CDNs
/// actually emit. Epochs are chosen inside the detector's plausible window (2000–2100):
/// `1_600_000_000` = 2020 (past), `2_000_000_000` = 2033 (future), with `now` at 2023.
@Suite("Link expiry detection")
struct LinkExpiryTests {

    private let past = 1_600_000_000.0        // 2020-09-13Z
    private let future = 2_000_000_000.0      // 2033-05-18Z
    private let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14Z

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (y, mo, d, h, mi, s)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private func base64url(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: AWS / S3-compatible

    @Test("AWS S3 SigV4 presigned URL: X-Amz-Date + X-Amz-Expires")
    func awsSigV4() {
        let link = url("https://bucket.s3.amazonaws.com/f.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Date=20231114T220000Z&X-Amz-Expires=3600&X-Amz-Signature=abc")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .awsSignedV4)
        #expect(expiry?.expiresAt == utc(2023, 11, 14, 22, 0, 0).addingTimeInterval(3600))
    }

    @Test("Works on any S3-compatible host (R2 / Spaces / B2 / MinIO), not just amazonaws.com")
    func s3Compatible() {
        for host in ["account.r2.cloudflarestorage.com", "nyc3.digitaloceanspaces.com", "minio.local:9000"] {
            let link = url("https://\(host)/bucket/f.bin?X-Amz-Date=20231114T220000Z&X-Amz-Expires=600&X-Amz-Signature=x")
            #expect(LinkExpiryDetector.detect(in: link)?.source == .awsSignedV4)
        }
    }

    @Test("Google Cloud Storage V4 signed URL: X-Goog-Date + X-Goog-Expires")
    func googleSigV4() {
        let link = url("https://storage.googleapis.com/b/o.pdf?X-Goog-Algorithm=GOOG4-RSA-SHA256"
            + "&X-Goog-Date=20231114T220000Z&X-Goog-Expires=7200&X-Goog-Signature=ff")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .googleSignedV4)
        #expect(expiry?.expiresAt == utc(2023, 11, 14, 22, 0, 0).addingTimeInterval(7200))
    }

    @Test("S3 SigV2 canned URL: absolute Expires epoch beside AWSAccessKeyId + Signature")
    func awsSigV2() {
        let link = url("https://s3.amazonaws.com/b/f.zip?AWSAccessKeyId=AKIA&Expires=\(Int(future))&Signature=zzz")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .awsSignedV2)
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    @Test("CloudFront canned policy: Expires + Signature + Key-Pair-Id")
    func cloudFrontCanned() {
        let link = url("https://d1.cloudfront.net/v.mp4?Expires=\(Int(future))&Signature=sig&Key-Pair-Id=APK")
        #expect(LinkExpiryDetector.detect(in: link)?.source == .awsSignedV2)
    }

    @Test("Alibaba OSS: Expires + OSSAccessKeyId + Signature")
    func alibabaOSS() {
        let link = url("https://b.oss-cn.aliyuncs.com/f?OSSAccessKeyId=LTAI&Expires=\(Int(future))&Signature=s")
        #expect(LinkExpiryDetector.detect(in: link)?.source == .awsSignedV2)
    }

    // MARK: Azure

    @Test("Azure Blob SAS: se (ISO-8601 signed expiry) + sig, with percent-encoded colons")
    func azureSAS() {
        let link = url("https://acct.blob.core.windows.net/c/f.zip?sv=2022-11-02&sr=b"
            + "&se=2033-05-18T03%3A33%3A20Z&sp=r&sig=BASE64SIG%3D")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .azureSAS)
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    @Test("Azure SAS without a signature isn't treated as one")
    func azureNeedsSig() {
        let link = url("https://acct.blob.core.windows.net/c/f?se=2033-05-18T03%3A33%3A20Z")
        #expect(LinkExpiryDetector.detect(in: link) == nil)
    }

    // MARK: CloudFront custom policy, edge tokens, JWT

    @Test("CloudFront custom policy: base64 Policy carrying DateLessThan")
    func cloudFrontPolicy() {
        let json = "{\"Statement\":[{\"Resource\":\"https://d1.cloudfront.net/*\","
            + "\"Condition\":{\"DateLessThan\":{\"AWS:EpochTime\":\(Int(future))}}}]}"
        let policy = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "/", with: "~")
        let link = url("https://d1.cloudfront.net/v.mp4?Policy=\(policy)&Signature=s&Key-Pair-Id=APK")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .cloudFrontPolicy)
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    @Test("Akamai edge token: exp=<epoch> inside a ~-delimited hdnts field")
    func akamaiToken() {
        let link = url("https://cdn.example.com/s/v.m3u8?hdnts=st=1600000000~exp=\(Int(future))~acl=/*~hmac=deadbeef")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .edgeToken)
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    @Test("JWT in a query parameter: exp claim is read without verifying the signature")
    func jwtToken() {
        let token = base64url("{\"alg\":\"HS256\",\"typ\":\"JWT\"}") + "."
            + base64url("{\"sub\":\"1\",\"exp\":\(Int(future))}") + ".sIgNaTuRe"
        let link = url("https://cdn.example.com/video.mp4?token=\(token)")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .jwt)
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    // MARK: Generic + numeric handling

    @Test("Generic expires= epoch parameter")
    func genericEpoch() {
        let expiry = LinkExpiryDetector.detect(in: url("https://ex.com/f.zip?expires=\(Int(future))"))
        #expect(expiry?.source == .generic)
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    @Test("Generic expiration= ISO-8601 parameter")
    func genericISO() {
        let expiry = LinkExpiryDetector.detect(in: url("https://ex.com/f?expiration=2033-05-18T03:33:20Z"))
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    @Test("A millisecond epoch is recognized as milliseconds, not the year 65000")
    func millisecondEpoch() {
        let ms = Int(future) * 1000
        let expiry = LinkExpiryDetector.detect(in: url("https://ex.com/f?expires=\(ms)"))
        #expect(expiry?.expiresAt == Date(timeIntervalSince1970: future))
    }

    @Test("Ordinary URLs and stray numeric params never fabricate a deadline")
    func noFalsePositives() {
        #expect(LinkExpiryDetector.detect(in: url("https://ex.com/file.zip")) == nil)
        #expect(LinkExpiryDetector.detect(in: url("https://ex.com/f?page=2&count=50&id=12345")) == nil)
        #expect(LinkExpiryDetector.detect(in: url("https://ex.com/f?expires=5")) == nil)          // out of range
        #expect(LinkExpiryDetector.detect(in: url("https://ex.com/f?e=1783430400")) == nil)       // 'e' too broad
    }

    @Test("When several deadlines are present, the earliest one wins")
    func earliestWins() {
        // X-Amz deadline (~2023) is far earlier than the JWT's 2033 exp.
        let token = base64url("{\"typ\":\"JWT\"}") + "." + base64url("{\"exp\":\(Int(future))}") + ".s"
        let link = url("https://s3.amazonaws.com/b/f?X-Amz-Date=20231114T220000Z&X-Amz-Expires=3600"
            + "&X-Amz-Signature=x&token=\(token)")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry?.source == .awsSignedV4)
        #expect(expiry?.expiresAt == utc(2023, 11, 14, 22, 0, 0).addingTimeInterval(3600))
    }

    // MARK: The value type

    @Test("isExpired / timeRemaining evaluate against the supplied clock")
    func expiredArithmetic() {
        let dead = LinkExpiry(expiresAt: Date(timeIntervalSince1970: past), source: .generic)
        let live = LinkExpiry(expiresAt: Date(timeIntervalSince1970: future), source: .generic)
        #expect(dead.isExpired(asOf: now))
        #expect(!live.isExpired(asOf: now))
        #expect(dead.timeRemaining(asOf: now) < 0)
        #expect(live.timeRemaining(asOf: now) > 0)
    }

    @Test("An already-expired signed URL is detected and reported expired")
    func expiredSignedURL() {
        let link = url("https://s3.amazonaws.com/b/f.zip?AWSAccessKeyId=AKIA&Expires=\(Int(past))&Signature=z")
        let expiry = LinkExpiryDetector.detect(in: link)
        #expect(expiry != nil)
        #expect(expiry?.isExpired(asOf: now) == true)
    }
}
