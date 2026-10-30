import SwiftUI
import AppKit

@main
struct KZTelegramAPIUtilityApp: App {
    var body: some Scene {
        WindowGroup("Telegram API Setup") { ContentView() }
            .windowResizability(.contentSize)
    }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var demoMode = true
    @Published var running = false
    @Published var logs: [String] = []
    @Published var country = "—"
    @Published var externalIP = "—"
    @Published var telegramIP = "—"
    @Published var result = "Введите адрес прокси"
    @Published var proxyURL = ""
    @Published var proxyUsername = ""
    @Published var proxyPassword = ""
    @Published var proxyApplied = false
    @Published var proxyTested = false
    @Published var proxyTesting = false
    @Published var proxyStatus = "Прокси не настроен"

    private var hostsBackup: URL?
    private var proxyBackup: String?
    private let logFile: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TelePrep", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        logFile = base.appendingPathComponent("last-run.log")
    }

    func run() {
        guard !running else { return }
        running = true
        logs.removeAll()
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
        result = demoMode ? "Демо-режим" : "Рабочий режим"
        Task { await execute() }
    }

    private func log(_ value: String) {
        logs.append(value)
        let text = logs.joined(separator: "\n") + "\n"
        try? text.write(to: logFile, atomically: true, encoding: .utf8)
    }

    private func execute() async {
        defer { running = false }
        log("1. Выполняю nslookup my.telegram.org")
        let lookup = shell("nslookup my.telegram.org")
        telegramIP = String(lookup.output.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .last(where: { $0.contains(".") }) ?? "—")
        if telegramIP != "—" {
            log("DNS: адрес my.telegram.org получен — \(telegramIP)")
        } else {
            log("DNS: не удалось получить адрес my.telegram.org")
            result = "Остановлено: DNS-адрес не найден"
            return
        }

        if demoMode {
            externalIP = "198.51.100.10"
            country = "KZ"
            log("ДЕМО: внешний IP 198.51.100.10, страна KZ")
        } else {
            log("Проверьте прокси и нажмите «Прокси подключён — продолжить проверку».")
            await waitForUser()
            guard let proxyOptions = proxyCurlOptions() else {
                log("Проверка остановлена: параметры прокси недоступны")
                result = "Остановлено: прокси не найден"
                return
            }
            externalIP = shell("curl -fsS \(proxyOptions) --connect-timeout 5 https://api.ipify.org").output.trimmingCharacters(in: .whitespacesAndNewlines)
            country = cleanCountry(shell("curl -fsS \(proxyOptions) --connect-timeout 5 https://ipinfo.io/country 2>/dev/null").output)
            log("Внешний IP: \(externalIP)")
            log("Страна: \(country)")
            if country != "KZ" { log("Предупреждение: IP не определяется как KZ; продолжаю, так как проверка IP информационная") }
        }

        log("2. Проверяю HTTPS-доступ к my.telegram.org через IP")
        let proxyOptions = demoMode ? "" : (proxyCurlOptions() ?? "")
        let check = shell("curl -sv \(proxyOptions) --connect-timeout 5 -m 15 --resolve my.telegram.org:443:\(telegramIP) https://my.telegram.org -o /dev/null")
        if demoMode {
            log("ДЕМО: HTTP/2 200")
        } else if check.status == 0 {
            if let statusLine = httpStatusLine(from: check.output) {
                log("Успешно: \(statusLine) через IP \(telegramIP)")
            } else {
                log("Успешное соединение через IP \(telegramIP)")
            }
        } else {
            log("Неуспешное соединение: \(connectionFailure(from: check.output))")
            result = "Остановлено: Telegram недоступен"
            return
        }

        log("3. Готовлю временную запись hosts")
        if demoMode {
            log("ДЕМО: hosts не изменён")
        } else {
            hostsBackup = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("telegram-hosts-backup")
            _ = shell("cp /etc/hosts \(hostsBackup!.path)")
            _ = shell("printf '\(telegramIP) my.telegram.org\\n' | sudo tee -a /etc/hosts >/dev/null")
            _ = shell("sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder")
            log("hosts обновлён и DNS-кэш очищен")
        }

        log("4. Открываю приватное окно Safari")
        if !demoMode && (!proxyApplied || !proxyTested) {
            log("Safari не открыт: прокси не применён или не прошёл проверку")
            result = "Остановлено: нужен рабочий прокси"
            return
        }
        if !demoMode { log("Прокси применён и проверен — открываю Safari") }
        _ = shell("open -a Safari; osascript -e 'tell application \"Safari\" to activate' -e 'delay 1' -e 'tell application \"System Events\" to keystroke \"n\" using {command down, shift down}' -e 'delay 1' -e 'tell application \"Safari\" to set URL of front document to \"https://my.telegram.org\"'")
        log(demoMode ? "ДЕМО: приватное окно Safari открыто" : "Safari открыт. Войдите и создайте приложение Telegram.")
        log("5. Очищаю DNS-кэш и возвращаю настройки по умолчанию")
        _ = shell("sudo dscacheutil -flushcache 2>/dev/null; sudo killall -HUP mDNSResponder 2>/dev/null; true")
        log("DNS-кэш очищен; временные настройки завершены")
        result = demoMode ? "Демо завершено" : "Готово: создайте приложение в Safari"
        log(result)
        if demoMode {
            try? await Task.sleep(for: .seconds(3))
            externalIP = "—"; country = "—"; telegramIP = "—"
            log("Состояние интерфейса возвращено по умолчанию")
        }
    }

    func continueLiveCheck() { NotificationCenter.default.post(name: .continueLiveCheck, object: nil) }

    func restoreDefaults() {
        guard let backup = hostsBackup else {
            log("Настройки уже по умолчанию; hosts не изменялся")
            restoreProxy()
            return
        }
        _ = shell("sudo cp \(backup.path) /etc/hosts; sudo dscacheutil -flushcache 2>/dev/null; sudo killall -HUP mDNSResponder 2>/dev/null; true")
        hostsBackup = nil
        log("Исходный hosts восстановлен, DNS-кэш очищен")
        result = "Настройки восстановлены"
        restoreProxy()
    }

    func applyProxy() {
        normalizeProxyInput()
        guard let parsed = parseProxy(proxyURL) else { proxyStatus = "Ошибка формата"; log("Прокси: формат должен быть http://, https:// или socks5://IP:PORT"); return }
        proxyStatus = "Применяю…"
        proxyTested = false
        let service = "Wi-Fi"
        proxyBackup = shell("networksetup -getwebproxy '\(service)' 2>/dev/null; networksetup -getsecurewebproxy '\(service)' 2>/dev/null; networksetup -getsocksfirewallproxy '\(service)' 2>/dev/null").output
        let command: String
        let user = proxyUsername.replacingOccurrences(of: "'", with: "'\\''")
        let pass = proxyPassword.replacingOccurrences(of: "'", with: "'\\''")
        _ = shell("security add-generic-password -U -a TelePrep -s TelePrepProxy -w '\(pass)' 2>/dev/null || true")
        if parsed.scheme == "socks5" { command = "networksetup -setsocksfirewallproxy '\(service)' \(parsed.host) \(parsed.port); networksetup -setsocksfirewallproxyusername '\(service)' '\(user)'; networksetup -setsocksfirewallproxypassword '\(service)' '\(pass)'; networksetup -setsocksfirewallproxystate '\(service)' on" }
        else { command = "networksetup -setwebproxy '\(service)' \(parsed.host) \(parsed.port); networksetup -setsecurewebproxy '\(service)' \(parsed.host) \(parsed.port); networksetup -setwebproxyusername '\(service)' '\(user)'; networksetup -setwebproxypassword '\(service)' '\(pass)'; networksetup -setsecurewebproxyusername '\(service)' '\(user)'; networksetup -setsecurewebproxypassword '\(service)' '\(pass)'; networksetup -setwebproxystate '\(service)' on; networksetup -setsecurewebproxystate '\(service)' on" }
        let applied = shell("sudo \(command)")
        guard applied.status == 0 else { proxyApplied = false; proxyStatus = "Не удалось применить"; log("Прокси не применён: проверьте права и настройки Wi-Fi"); return }
        proxyApplied = true
        proxyStatus = "Успешно применён, проверяю…"
        log("Прокси применён для Wi-Fi и Safari: \(parsed.scheme)://\(parsed.host):\(parsed.port)")
        testProxy()
    }

    func testProxy() {
        normalizeProxyInput()
        guard let parsed = parseProxy(proxyURL), !proxyTesting else { log("Прокси: проверьте формат и адрес"); return }
        proxyTesting = true; proxyTested = false
        let user = proxyUsername.replacingOccurrences(of: "'", with: "'\\''")
        let pass = proxyPassword.replacingOccurrences(of: "'", with: "'\\''")
        let auth = user.isEmpty ? "" : "--proxy-user '\(user):\(pass)'"
        proxyStatus = "Проверяю доступ и IP…"
        let proxy = "\(parsed.scheme)://\(parsed.host):\(parsed.port)"
        let check = shell("curl -fsS \(auth) --proxy '\(proxy)' --connect-timeout 6 -m 12 https://api.ipify.org")
        let detectedIP = check.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedCountry = cleanCountry(shell("curl -fsS \(auth) --proxy '\(proxy)' --connect-timeout 6 -m 12 https://ipinfo.io/country 2>/dev/null").output)
        proxyTesting = false
        if check.status == 0 && !detectedIP.isEmpty {
            proxyTested = true; externalIP = detectedIP; country = detectedCountry.isEmpty ? "—" : detectedCountry
            proxyStatus = "Успешно применён"
            log(detectedCountry == "—" ? "Прокси работает. IP: \(detectedIP); страна не определена" : "Прокси работает. IP: \(detectedIP), страна: \(detectedCountry)")
        } else { proxyTested = false; proxyStatus = "Проверка не пройдена"; log("Прокси не прошёл проверку; запуск рабочего режима заблокирован") }
    }

    func restoreProxy() {
        guard proxyApplied else { proxyStatus = "Стандартные настройки"; return }
        _ = shell("sudo networksetup -setwebproxystate 'Wi-Fi' off; sudo networksetup -setsecurewebproxystate 'Wi-Fi' off; sudo networksetup -setsocksfirewallproxystate 'Wi-Fi' off")
        proxyApplied = false; proxyTested = false; proxyStatus = "Стандартные настройки"; externalIP = "—"; country = "—"; log("Прокси отключён, системные настройки возвращены")
    }

    func openLogs() { NSWorkspace.shared.open(logFile) }

    func copyLogsFile() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([logFile as NSURL])
        log("Файл журнала скопирован")
    }

    func exportV2RayProfile() {
        guard let parsed = parseProxy(proxyURL), !proxyUsername.isEmpty, !proxyPassword.isEmpty else {
            log("Экспорт V2Ray: заполните адрес, логин и пароль прокси")
            return
        }
        let profile: [String: Any] = [
            "log": ["level": "warn"],
            "outbounds": [
                ["type": "socks", "tag": "froxy", "server": parsed.host, "server_port": Int(parsed.port) ?? 0, "username": proxyUsername, "password": proxyPassword],
                ["type": "direct", "tag": "direct"]
            ],
            "route": [
                "rules": [
                    ["domain": ["full:fast.froxy.com"], "outbound": "direct"],
                    ["domain": ["my.telegram.org", "telegram.org", "api.ipify.org", "ipinfo.io", "2ip.io"], "outbound": "froxy"]
                ],
                "final": "direct"
            ]
        ]
        guard JSONSerialization.isValidJSONObject(profile), let data = try? JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = logFile.deletingLastPathComponent().appendingPathComponent("v2ray-froxy-profile.json")
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            log("Профиль V2Ray сохранён локально")
        } catch {
            log("Профиль V2Ray не удалось сохранить")
        }
    }

    private func parseProxy(_ value: String) -> (scheme: String, host: String, port: String)? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https", "socks5"].contains(scheme), let host = url.host, let port = url.port else { return nil }
        return (scheme, host, String(port))
    }

    private func proxyCurlOptions() -> String? {
        guard let parsed = parseProxy(proxyURL) else { return nil }
        let user = proxyUsername.replacingOccurrences(of: "'", with: "'\\''")
        let pass = proxyPassword.replacingOccurrences(of: "'", with: "'\\''")
        let auth = user.isEmpty ? "" : "--proxy-user '\(user):\(pass)' "
        // SOCKS5H resolves destination DNS through the proxy. Plain SOCKS5
        // resolves locally and can hang when the local DNS path is blocked.
        let curlScheme = parsed.scheme == "socks5" ? "socks5h" : parsed.scheme
        // Froxy's hostname can be unavailable to the local resolver while a
        // tunnel is active. Use the currently verified endpoint IP instead.
        let curlHost = parsed.host == "fast.froxy.com" ? "103.152.136.26" : parsed.host
        return "\(auth)--proxy '\(curlScheme)://\(curlHost):\(parsed.port)'"
    }

    private func cleanCountry(_ value: String) -> String {
        let country = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard country.count == 2, country.allSatisfy({ $0.isLetter }) else { return "—" }
        return country.uppercased()
    }

    private func httpStatusLine(from output: String) -> String? {
        let lines = output.split(separator: "\n").map(String.init)
        return lines.last(where: { $0.range(of: #"HTTP/\d(?:\.\d)?\s+\d{3}"#, options: .regularExpression) != nil })?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connectionFailure(from output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") { return "истекло время ожидания — IP или маршрут недоступен" }
        if lower.contains("failed to connect") || lower.contains("could not connect") { return "не удалось подключиться — IP может быть заблокирован" }
        if lower.contains("connection reset") { return "соединение сброшено — возможна фильтрация трафика" }
        if lower.contains("ssl") || lower.contains("handshake") { return "ошибка защищённого соединения — возможна фильтрация трафика" }
        return "неизвестная ошибка подключения"
    }

    /// Accepts a compact host:port form and extracts credentials from a full proxy URL.
    func normalizeProxyInput() {
        var value = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            if !proxyApplied {
                result = "Введите адрес прокси"
                proxyStatus = "Прокси не настроен"
                proxyTested = false
            }
            return
        }
        if !value.contains("://") { value = "socks5://" + value }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), let host = url.host, let port = url.port,
              ["http", "https", "socks5"].contains(scheme) else { return }
        let normalized = "\(scheme)://\(host):\(port)"
        if proxyURL != normalized { proxyURL = normalized }
        if let user = url.user { proxyUsername = user.removingPercentEncoding ?? user }
        if let password = url.password { proxyPassword = password.removingPercentEncoding ?? password }
        proxyTested = false
        if !proxyApplied && !proxyTesting {
            result = "Прокси готов"
            proxyStatus = "Прокси готов"
        }
    }

    private func waitForUser() async {
        await withCheckedContinuation { continuation in
            NotificationCenter.default.addObserver(forName: .continueLiveCheck, object: nil, queue: .main) { _ in continuation.resume() }
        }
    }

    private func shell(_ command: String) -> (output: String, status: Int32) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run(); process.waitUntilExit() } catch { return (error.localizedDescription, 1) }
        return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", process.terminationStatus)
    }
}

extension Notification.Name { static let continueLiveCheck = Notification.Name("continueLiveCheck") }

struct ContentView: View {
    @StateObject private var model = SetupModel()
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.08, blue: 0.18), Color(red: 0.03, green: 0.20, blue: 0.34), Color(red: 0.02, green: 0.42, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.16)).frame(width: 58, height: 58)
                        Image(systemName: "shield.lefthalf.filled").font(.system(size: 30, weight: .bold)).foregroundStyle(.white, .cyan)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TelePrep").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        Text("Telegram API Access Assistant").font(.subheadline).foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    Text(model.demoMode ? "DEMO" : "LIVE").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6).background(model.demoMode ? .yellow.opacity(0.25) : .green.opacity(0.3)).clipShape(Capsule()).foregroundStyle(.white)
                }
                Text("Безопасно пройдите сетевую подготовку и откройте страницу создания Telegram-приложения.").font(.callout).foregroundStyle(.white.opacity(0.82))
                HStack(spacing: 10) {
                    step("01", "DNS")
                    step("02", "Прокси / IP")
                    step("03", "Safari")
                    step("04", "Готово")
                }
                HStack {
                    Text("Режим запуска").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Toggle("Демо", isOn: $model.demoMode).labelsHidden().tint(.cyan)
                    Text(model.demoMode ? "Полный цикл без прокси" : "Прокси проверяется перед запуском; IP показывается информационно").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 12) {
                    stat("Внешний IP", model.externalIP, "network")
                    stat("Страна", model.country, "globe")
                    stat("Прокси", model.proxyStatus, "bolt.horizontal.circle")
                }
                HStack(spacing: 8) {
                    TextField("Прокси: host:port или socks5://user:pass@host:port", text: $model.proxyURL).textFieldStyle(.roundedBorder)
                    TextField("Логин", text: $model.proxyUsername).textFieldStyle(.roundedBorder).frame(width: 110)
                    SecureField("Пароль", text: $model.proxyPassword).textFieldStyle(.roundedBorder).frame(width: 110)
                    Button(model.proxyTesting ? "Проверяю…" : (model.proxyTested ? "Проверен" : "Проверить")) { model.testProxy() }.buttonStyle(GlassButton()).disabled(model.proxyURL.isEmpty || model.proxyTesting)
                    Button(model.proxyTesting ? "Проверяю…" : (model.proxyApplied ? "Применён" : "Применить")) { model.applyProxy() }.buttonStyle(GlassButton()).disabled(model.proxyURL.isEmpty || model.proxyTesting || model.proxyApplied)
                    Button("Сбросить") { model.restoreProxy() }.buttonStyle(GlassButton()).disabled(!model.proxyApplied)
                }
                Text("Для VLESS сначала включите ключ в V2Ray-клиенте и укажите его локальный HTTP/SOCKS-порт.")
                    .font(.caption).foregroundStyle(.white.opacity(0.62))
                HStack(spacing: 10) {
                    Button { model.run() } label: {
                        Label(model.running ? "Выполняется…" : (model.demoMode ? "Запустить демо" : "Начать подготовку"), systemImage: "play.fill")
                    }.buttonStyle(PrimaryButton()).disabled(model.running)
                    if !model.demoMode && model.running {
                        Button { model.continueLiveCheck() } label: {
                            Label("Прокси подключён — продолжить проверку", systemImage: "arrow.right.circle.fill")
                        }.buttonStyle(GlassButton()).disabled(!model.proxyTested)
                    }
                    Menu {
                        Button("Открыть журнал") { model.openLogs() }
                        Button("Скопировать файл журнала") { model.copyLogsFile() }
                        Divider()
                        Button("Экспортировать профиль V2Ray") { model.exportV2RayProfile() }
                    } label: {
                        Label("Логи", systemImage: "doc.text.magnifyingglass")
                    }.buttonStyle(GlassButton())
                    Button { model.restoreDefaults() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(GlassButton()).help("Восстановить настройки")
                }
                ScrollView { Text(model.logs.isEmpty ? "Журнал появится после запуска…" : model.logs.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading).font(.system(.callout, design: .monospaced)).foregroundStyle(.white.opacity(0.82)) }
                    .padding(14).frame(maxHeight: 170).background(.black.opacity(0.22)).clipShape(RoundedRectangle(cornerRadius: 14))
            }.padding(28)
        }
        .frame(width: 780, height: 560)
        .onChange(of: model.proxyURL) { _ in model.normalizeProxyInput() }
    }

    private func step(_ number: String, _ title: String) -> some View { HStack(spacing: 7) { Text(number).font(.caption.bold()).foregroundStyle(.cyan); Text(title).font(.caption).foregroundStyle(.white.opacity(0.8)) }.padding(.vertical, 8).padding(.horizontal, 10).background(.white.opacity(0.09)).clipShape(Capsule()) }
    private func stat(_ title: String, _ value: String, _ icon: String) -> some View { VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: icon).font(.caption).foregroundStyle(.white.opacity(0.62)); Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12)) }
}

struct PrimaryButton: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).foregroundStyle(.black).padding(.horizontal, 16).padding(.vertical, 10).background(.cyan).clipShape(RoundedRectangle(cornerRadius: 10)).opacity(configuration.isPressed ? 0.75 : 1) } }
struct GlassButton: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 10).background(.white.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 10)).opacity(configuration.isPressed ? 0.65 : 1) } }
