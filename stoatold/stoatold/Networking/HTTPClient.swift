import Foundation
import UIKit

// iOS 6-safe HTTP client using NSURLConnection delegate.
// NSURLConnection.sendAsynchronousRequest silently hangs on iOS 6/7 — never use it.
// Must schedule on .common so it fires during UITracking (scroll) run loop mode too.
class HTTPClient: NSObject, NSURLConnectionDelegate, NSURLConnectionDataDelegate {

    typealias Completion = (Data?, Int, Error?) -> Void

    private var connection: NSURLConnection?
    private var responseData = NSMutableData()
    private var statusCode   = 0
    private var completion:  Completion
    private var timer:       Timer?
    private var progress: ((Int, Int) -> Void)?

    // Retain active instances — NSURLConnection delegate is unretained
    static var active: [HTTPClient] = []

    private init(completion: @escaping Completion) {
        self.completion = completion
    }


    // Multipart form-data upload — used for image attachments (CDN endpoint)
    static func upload(_ urlString: String,
                       fileData: Data,
                       filename: String,
                       mimeType: String,
                       headers: [String: String] = [:],
                       progress: ((Int, Int) -> Void)? = nil,
                       completion: @escaping Completion) {
        let boundary = "StoatBoundary\(UInt32(arc4random()))"
        var body = Data()
        func ap(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        ap("--\(boundary)\r\n")
        ap("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        ap("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        ap("\r\n--\(boundary)--\r\n")

        guard let url = URL(string: urlString) else {
            completion(nil, 0, NSError(domain: "HTTPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body

        let client = HTTPClient(completion: completion)
        client.progress = progress
        active.append(client)
        let conn = NSURLConnection(request: req, delegate: client, startImmediately: false)
        client.connection = conn
        conn?.schedule(in: .main, forMode: .common)
        conn?.start()
        // 60s timeout for uploads
        let t = Timer(timeInterval: 60, target: client,
                      selector: #selector(timedOut), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        client.timer = t
    }

    static func request(_ urlString: String,
                        method: String = "GET",
                        headers: [String: String] = [:],
                        body: Data? = nil,
                        completion: @escaping Completion) {
        guard let url = URL(string: urlString) else {
            completion(nil, 0, NSError(domain: "HTTPClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // Only set Content-Type for requests with a body
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body

        let client = HTTPClient(completion: completion)
        active.append(client)

        let conn = NSURLConnection(request: req, delegate: client, startImmediately: false)
        client.connection = conn
        conn?.schedule(in: .main, forMode: .common)
        conn?.start()

        // 20-second timeout — also on .common so it fires during UITracking
        let t = Timer(timeInterval: 20, target: client,
                      selector: #selector(timedOut), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        client.timer = t
    }

    @objc private func timedOut() {
        connection?.cancel()
        done(nil, 0, NSError(domain: "HTTPClient", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
    }

    private func done(_ data: Data?, _ status: Int, _ error: Error?) {
        timer?.invalidate()
        timer = nil
        HTTPClient.active.removeAll { $0 === self }
        completion(data, status, error)
    }

    // MARK: NSURLConnectionDelegate

    // Follow HTTP redirects (CDN may 302 to S3/CloudFront)
    func connection(_ connection: NSURLConnection,
                    willSend request: URLRequest,
                    redirectResponse: URLResponse?) -> URLRequest? {
        return request
    }

    func connection(_ connection: NSURLConnection,
                    willSendRequestFor challenge: URLAuthenticationChallenge) {
        guard let sender = challenge.sender else { return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            sender.use(URLCredential(trust: trust), for: challenge)
        } else {
            sender.performDefaultHandling?(for: challenge)
        }
    }

    func connection(_ connection: NSURLConnection, didFailWithError error: Error) {
        done(nil, 0, error)
    }

    // MARK: NSURLConnectionDataDelegate

    func connection(_ connection: NSURLConnection, didReceive response: URLResponse) {
        statusCode   = (response as? HTTPURLResponse)?.statusCode ?? 0
        responseData = NSMutableData()
    }

    func connection(_ connection: NSURLConnection, didReceive data: Data) {
        responseData.append(data)
    }

    func connection(_ connection: NSURLConnection, didSendBodyData bytesWritten: Int,
                    totalBytesWritten: Int, totalBytesExpectedToWrite: Int) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func connectionDidFinishLoading(_ connection: NSURLConnection) {
        done(responseData as Data, statusCode, nil)
    }
}


// CDNImage — HTTPS image loader over the OpenSSL bridge (owsl).
// iOS 6 Secure Transport only negotiates CBC ciphers, but the stoat CDN requires
// GCM, so NSURLConnection fails the TLS handshake before any data flows. We reuse
// the owsl bridge (OpenSSL, same one VortexSignaling uses) to do a plain HTTPS GET
// and decode the body into a UIImage. The GET request is written by us; the bridge
// only does TCP + TLS.
final class CDNImage: NSObject {

    typealias Completion = (UIImage?) -> Void

    private static let cache  = NSCache<NSString, UIImage>()
    private static var active: [CDNImage] = []

    private var owslCtx:    OpaquePointer? = nil
    private var buffer      = Data()
    private var done        = false
    private let cacheKey:   String
    private let redirectsLeft: Int
    private let completion: Completion

    private init(cacheKey: String, redirectsLeft: Int, completion: @escaping Completion) {
        self.cacheKey      = cacheKey
        self.redirectsLeft = redirectsLeft
        self.completion    = completion
    }

    // MARK: Public

    static func load(_ urlString: String, completion: @escaping Completion) {
        if let cached = cache.object(forKey: urlString as NSString) {
            completion(cached); return
        }
        fetch(urlString, cacheKey: urlString, redirectsLeft: 4, completion: completion)
    }

    private static func fetch(_ urlString: String, cacheKey: String,
                              redirectsLeft: Int, completion: @escaping Completion) {
        guard let url = URL(string: urlString), let host = url.host else {
            completion(nil); return
        }
        let port = url.port ?? (url.scheme == "http" ? 80 : 443)
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?\(q)" }

        let client = CDNImage(cacheKey: cacheKey, redirectsLeft: redirectsLeft,
                              completion: completion)
        active.append(client)

        let selfPtr = Unmanaged.passUnretained(client).toOpaque()
        guard let ctx = owsl_create(host, CInt(port),
                                    CDNImage.readCb, CDNImage.eventCb, selfPtr) else {
            client.finish(nil); return
        }
        client.owslCtx = ctx

        let req = "GET \(path) HTTP/1.1\r\n"
                + "Host: \(host)\r\n"
                + "User-Agent: stoatold/1.0\r\n"
                + "Accept: */*\r\n"
                + "Connection: close\r\n\r\n"

        DispatchQueue(label: "com.stoatold.cdnimg.connect").async {
            let ret = owsl_connect(ctx)
            DispatchQueue.main.async {
                guard client.owslCtx != nil else { return }
                if ret != 0 { client.finish(nil); return }
                owsl_start_reading(ctx)
                client.write(req.data(using: .utf8)!)
            }
        }
    }

    // MARK: C callbacks (fire on bg thread -> hop to main)

    private static let readCb: OWSL_read_cb = { buf, len, ud in
        guard let ud = ud, let buf = buf else { return }
        let c = Unmanaged<CDNImage>.fromOpaque(ud).takeUnretainedValue()
        let data = Data(bytes: buf, count: len)
        DispatchQueue.main.async { c.buffer.append(data) }
    }

    private static let eventCb: OWSL_event_cb = { kind, _, ud in
        guard let ud = ud else { return }
        let c = Unmanaged<CDNImage>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async {
            if kind == 1 { c.handleResponse() }   // EOF — full body received
            else         { c.finish(nil) }        // error
        }
    }

    // MARK: Helpers (all on main thread)

    private func write(_ data: Data) {
        guard let ctx = owslCtx else { return }
        data.withUnsafeBytes { ptr in
            _ = owsl_write(ctx, ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count)
        }
    }

    private func handleResponse() {
        guard owslCtx != nil, !done else { return }
        let sepData = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let r = buffer.range(of: sepData) else { finish(nil); return }
        let headerData = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
        var body       = buffer.subdata(in: r.upperBound..<buffer.endIndex)

        let headerStr  = String(data: headerData, encoding: .isoLatin1) ?? ""
        let lines      = headerStr.components(separatedBy: "\r\n")
        let statusLine = lines.first ?? ""
        let sp         = statusLine.components(separatedBy: " ")
        let status     = sp.count >= 2 ? (Int(sp[1]) ?? 0) : 0

        var headers = [String: String]()
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        // Follow CDN redirects (e.g. 302 to S3/CloudFront) — may change host.
        if status >= 300 && status < 400, let loc = headers["location"], redirectsLeft > 0 {
            let key = cacheKey, left = redirectsLeft - 1, comp = completion
            done = true
            cleanup()
            CDNImage.fetch(loc, cacheKey: key, redirectsLeft: left, completion: comp)
            return
        }

        guard status == 200 else { finish(nil); return }

        if (headers["transfer-encoding"]?.lowercased().contains("chunked")) == true {
            body = CDNImage.dechunk(body)
        }

        // The stoat CDN re-encodes everything to WebP, which UIImage cannot decode on
        // iOS 6/7. Fall back to the bundled libwebp decoder.
        let img = UIImage(data: body) ?? CDNImage.decodeWebP(body)
        if let img = img { CDNImage.cache.setObject(img, forKey: cacheKey as NSString) }
        finish(img)
    }

    // WebP -> UIImage via libwebp (WebPDecodeRGBA gives straight-alpha RGBA8888).
    private static func decodeWebP(_ data: Data) -> UIImage? {
        var width:  Int32 = 0
        var height: Int32 = 0
        let decoded: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return WebPDecodeRGBA(base, data.count, &width, &height)
        }
        guard let rgba = decoded, width > 0, height > 0 else { return nil }
        let w = Int(width), h = Int(height)
        let size = w * h * 4

        // Premultiply alpha in place (CoreGraphics needs premultiplied for rendering).
        var i = 0
        while i < size {
            let a = UInt32(rgba[i + 3])
            if a < 255 {
                rgba[i]     = UInt8(UInt32(rgba[i])     * a / 255)
                rgba[i + 1] = UInt8(UInt32(rgba[i + 1]) * a / 255)
                rgba[i + 2] = UInt8(UInt32(rgba[i + 2]) * a / 255)
            }
            i += 4
        }

        guard let provider = CGDataProvider(
            dataInfo: rgba, data: rgba, size: size,
            releaseData: { info, _, _ in if let info = info { WebPFree(info) } }
        ) else { WebPFree(rgba); return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data([0x0D, 0x0A])
        while i < data.endIndex {
            guard let r = data.range(of: crlf, in: i..<data.endIndex) else { break }
            let sizeLine = String(data: data.subdata(in: i..<r.lowerBound), encoding: .ascii) ?? ""
            let hex = sizeLine.components(separatedBy: ";").first ?? sizeLine
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            if size == 0 { break }
            let start = r.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data.subdata(in: start..<end))
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    private func finish(_ img: UIImage?) {
        if done { return }
        done = true
        cleanup()
        completion(img)
    }

    // Keep self in `active` until owsl_destroy has joined the read thread, so no
    // callback fires into a deallocated instance.
    private func cleanup() {
        guard let ctx = owslCtx else { return }
        owslCtx = nil
        owsl_close(ctx)
        DispatchQueue(label: "com.stoatold.cdnimg.destroy").async {
            owsl_destroy(ctx)
            DispatchQueue.main.async { CDNImage.active.removeAll { $0 === self } }
        }
    }
}
