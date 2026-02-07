import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MergeView()
                .tabItem { Text("Merge") }

            OCRView()
                .tabItem { Text("OCR") }

            PageToolsView()
                .tabItem { Text("Seiten") }
        }
        .frame(minWidth: 900, minHeight: 600)
        .padding()
    }
}
