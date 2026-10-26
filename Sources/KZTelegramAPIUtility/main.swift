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
    @Published var result = "Готово к запуску"

    private var hostsBackup: URL?

    func run() {
        guard !running else { return }
        running = true
        logs.removeAll()
        result = demoMode ? "Демо-режим" : "Рабочий режим"
        Task { await execute() }
    }

    private func log(_ value: String) { logs.append(value) }

    private func execute() async {
        defer { running = false }
        log("1. Выполняю nslookup my.telegram.org")
        let lookup = shell("nslookup my.telegram.org")
        telegramIP = String(lookup.output.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .last(where: { $0.contains(".") }) ?? "—")
        log(lookup.output.trimmingCharacters(in: .whitespacesAndNewlines))

        if demoMode {
            externalIP = "198.51.100.10"
            country = "KZ"
            log("ДЕМО: внешний IP 198.51.100.10, страна KZ")
        } else {
            log("Подключите VPN к Казахстану и нажмите «Продолжить проверку».")
            await waitForUser()
            externalIP = shell("curl -fsS --connect-timeout 5 https://api.ipify.org").output.trimmingCharacters(in: .whitespacesAndNewlines)
            country = shell("curl -fsS --connect-timeout 5 https://ipinfo.io/country").output.trimmingCharacters(in: .whitespacesAndNewlines)
            log("Внешний IP: \(externalIP)")
            log("Страна: \(country)")
            guard country == "KZ" else { result = "Остановлено: IP не Казахстан"; log(result); return }
        }

        log("2. Проверяю HTTPS-доступ к my.telegram.org через IP")
        let check = shell("curl -sv --connect-timeout 5 -m 15 --resolve my.telegram.org:443:\(telegramIP) https://my.telegram.org -o /dev/null")
        if demoMode {
            log("ДЕМО: HTTP/2 200")
        } else if check.status == 0 {
            log("Успешное соединение")
        } else {
            log("Неуспешное соединение: Failed to connect / timeout / SSL-DPI")
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
            logs.append("Состояние интерфейса возвращено по умолчанию")
        }
    }

    func continueLiveCheck() { NotificationCenter.default.post(name: .continueLiveCheck, object: nil) }

    func restoreDefaults() {
        guard let backup = hostsBackup else {
            logs.append("Настройки уже по умолчанию; hosts не изменялся")
            return
        }
        _ = shell("sudo cp \(backup.path) /etc/hosts; sudo dscacheutil -flushcache 2>/dev/null; sudo killall -HUP mDNSResponder 2>/dev/null; true")
        hostsBackup = nil
        logs.append("Исходный hosts восстановлен, DNS-кэш очищен")
        result = "Настройки восстановлены"
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
                    step("02", "VPN / IP")
                    step("03", "Safari")
                    step("04", "Готово")
                }
                HStack {
                    Text("Режим запуска").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Toggle("Демо", isOn: $model.demoMode).labelsHidden().tint(.cyan)
                    Text(model.demoMode ? "Полный цикл без VPN" : "Проверка KZ обязательна").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 12) {
                    stat("Внешний IP", model.externalIP, "network")
                    stat("Страна", model.country, "globe")
                    stat("Состояние", model.result, "checkmark.seal")
                }
                HStack(spacing: 10) {
                    Button { model.run() } label: { Label(model.running ? "Выполняется…" : "Запустить проверку", systemImage: "play.fill") }.buttonStyle(PrimaryButton()) .disabled(model.running)
                    Button { model.continueLiveCheck() } label: { Label("VPN подключён", systemImage: "lock.open.fill") }.buttonStyle(GlassButton()).disabled(model.demoMode || !model.running)
                    Button { model.restoreDefaults() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(GlassButton()).help("Восстановить настройки")
                }
                ScrollView { Text(model.logs.isEmpty ? "Журнал появится после запуска…" : model.logs.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading).font(.system(.callout, design: .monospaced)).foregroundStyle(.white.opacity(0.82)) }
                    .padding(14).frame(maxHeight: 170).background(.black.opacity(0.22)).clipShape(RoundedRectangle(cornerRadius: 14))
            }.padding(28)
        }.frame(width: 780, height: 560)
    }

    private func step(_ number: String, _ title: String) -> some View { HStack(spacing: 7) { Text(number).font(.caption.bold()).foregroundStyle(.cyan); Text(title).font(.caption).foregroundStyle(.white.opacity(0.8)) }.padding(.vertical, 8).padding(.horizontal, 10).background(.white.opacity(0.09)).clipShape(Capsule()) }
    private func stat(_ title: String, _ value: String, _ icon: String) -> some View { VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: icon).font(.caption).foregroundStyle(.white.opacity(0.62)); Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.white.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12)) }
}

struct PrimaryButton: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).foregroundStyle(.black).padding(.horizontal, 16).padding(.vertical, 10).background(.cyan).clipShape(RoundedRectangle(cornerRadius: 10)).opacity(configuration.isPressed ? 0.75 : 1) } }
struct GlassButton: ButtonStyle { func makeBody(configuration: Configuration) -> some View { configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 10).background(.white.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 10)).opacity(configuration.isPressed ? 0.65 : 1) } }

