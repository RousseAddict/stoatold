import Foundation

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
