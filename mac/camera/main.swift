// Dikiz Kamera — CoreMediaIO Camera Extension giriş noktası.
import Foundation
import CoreMediaIO

let providerSource = DikizProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
