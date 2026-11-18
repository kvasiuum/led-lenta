import Foundation
import UIKit

/// Проверка обновлений: читает источник SideStore (apps.json из репозитория)
/// и сравнивает номер сборки с установленным.
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: String?
    @Published private(set) var notes = ""
    @Published var dismissed = false
    private var lastCheck = Date.distantPast

    static var sourceURL: String {
        Bundle.main.object(forInfoDictionaryKey: "LentaSourceURL") as? String ?? ""
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    /// Не чаще раза в 30 минут
    func check(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 1800,
              let url = URL(string: Self.sourceURL) else { return }
        lastCheck = Date()
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = j["apps"] as? [[String: Any]], let app = apps.first,
                  let versions = app["versions"] as? [[String: Any]], let v = versions.first,
                  let build = Int(v["buildVersion"] as? String ?? "") else { return }
            let version = v["version"] as? String ?? ""
            let text = v["localizedDescription"] as? String ?? ""
            DispatchQueue.main.async {
                if build > self.currentBuild {
                    if self.available != version { self.dismissed = false }
                    self.available = version
                    self.notes = text
                } else {
                    self.available = nil
                }
            }
        }.resume()
    }

    /// Открыть SideStore (там кнопка «Обновить»)
    func openSideStore() {
        for s in ["sidestore://", "altstore://"] {
            if let u = URL(string: s), UIApplication.shared.canOpenURL(u) {
                UIApplication.shared.open(u)
                return
            }
        }
        Services.shared.app.showToast("SideStore не найден на этом iPhone")
    }

    /// Добавить источник в SideStore одной кнопкой (и скопировать ссылку на всякий случай)
    func addSource() {
        UIPasteboard.general.string = Self.sourceURL
        let enc = Self.sourceURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        for s in ["sidestore://source?url=", "altstore://source?url="] {
            if let u = URL(string: s + enc), let probe = URL(string: s.components(separatedBy: "source").first ?? s),
               UIApplication.shared.canOpenURL(probe) {
                UIApplication.shared.open(u)
                Services.shared.app.showToast("Ссылка на источник скопирована")
                return
            }
        }
        Services.shared.app.showToast("Ссылка скопирована. Вставь её в SideStore → Источники → +")
    }
}
