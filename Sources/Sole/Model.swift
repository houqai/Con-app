import Combine
import SoleLogic
import SwiftUI

@MainActor final class SoleModel: AppModel, @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let remotePlay: RemotePlay
    let focus = ControllerFocus()
    private(set) lazy var library: LibraryScreen = {
        let library = LibraryScreen(model: self, focus: focus)
        library.willChange = { [unowned self] in self.objectWillChange.send() }
        return library
    }()
    init(defaults: UserDefaults = .standard) {
        let remotePlay = RemotePlay(defaults: defaults)
        self.remotePlay = remotePlay
        super.init(store: KeychainCredentials(), website: SonyWebsiteLogin(), player: remotePlay, defaults: defaults)
        willChange = { [unowned self] in self.objectWillChange.send() }
    }
}
