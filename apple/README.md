# Apple native shell

The macOS app keeps the upstream React interface and replaces Electron with a
small SwiftUI/WKWebView host. `window.dyaNative` is the only interface between
the web application and Apple APIs.

The bundled React files are served on the fixed loopback origin
`http://127.0.0.1:28741`. Keeping this origin stable is required so WebKit's
local storage (including the connection-notice preference) survives app
restarts. The listener is restricted to the loopback interface.

The first bridge transport is native USB serial. React still consumes the same
`RpcTransport` streams, keeping native details out of the application pages.
Future CoreBluetooth support should be added behind the same bridge rather than
inside React.

The DMG is intentionally built by GitHub Actions. Pushes to
`codex/swiftui-native-bridge` produce an unsigned, ad-hoc-signed Apple Silicon
artifact. A `swift-v*` tag also creates a GitHub Release without generated
release notes.
