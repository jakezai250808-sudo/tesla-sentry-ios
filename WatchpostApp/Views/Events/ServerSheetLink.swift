import SwiftUI

extension View {
    func serversSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { ServersSheet() }
    }
}
