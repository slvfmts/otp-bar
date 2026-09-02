import SwiftUI

struct OTPBarApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra("OTP", systemImage: "lock.shield.fill") {
            MenuContentView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
