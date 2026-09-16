import Foundation
import WebKit

/// Podaje stronie okładki z pomocnika MediaRemote pod adresem `wokyintosh-art://artwork/<id>`.
/// Dzięki temu co 1,8 s do strony idzie krótki adres zamiast bajtów obrazka.
final class ArtworkSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lookup: (String) -> MRArtwork?

    init(lookup: @escaping (String) -> MRArtwork?) {
        self.lookup = lookup
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard
            let url = urlSchemeTask.request.url,
            let id = ArtworkURL.artworkId(from: url),
            let artwork = lookup(id)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: artwork.mime,
            expectedContentLength: artwork.data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(artwork.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
