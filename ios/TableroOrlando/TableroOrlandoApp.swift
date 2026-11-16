import SwiftUI
import UIKit

/// Tablero Orlando: el tablero web corriendo como app de iPad,
/// con radio en segundo plano, GPS y escáner OBD nativos.
@main
struct TableroOrlandoApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
                .onAppear {
                    // La pantalla no se apaga mientras el tablero está abierto.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

struct DashboardView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController()
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) {}
}
