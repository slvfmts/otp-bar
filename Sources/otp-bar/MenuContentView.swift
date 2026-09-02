import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuContentView: View {
    @ObservedObject var store: AccountStore
    @State private var copiedID: AccountID?
    @State private var flashID: AccountID?
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.loadError {
                Text("Не удалось загрузить хранилище")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.top, 12)
                Text(error.userMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.bottom, 8)
                Button("Повторить") {
                    store.reload()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.horizontal).padding(.bottom, 8)
            } else if store.accounts.isEmpty {
                Text("Нет аккаунтов")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.top, 12)
                Text("Нажмите «Добавить аккаунт…» и выберите\nкартинку с QR-кодом (скриншот из Google\nAuthenticator или с экрана подключения 2FA).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal).padding(.bottom, 8)
            } else {
                ForEach(store.accounts) { account in
                    row(account)
                    Divider()
                }
            }

            footer
        }
        .frame(width: 280)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Button {
                ImportFlow.presentImportPanel(store: store)
            } label: {
                Label("Добавить аккаунт…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(store.loadError != nil)
            HStack {
                if !store.accounts.isEmpty {
                    Button(editing ? "Готово" : "Изменить") {
                        withAnimation(.easeInOut(duration: 0.15)) { editing.toggle() }
                    }
                }
                Spacer()
                Button("Обновить") { store.reload() }
                Button("Выход") { NSApplication.shared.terminate(nil) }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(8)
    }

    @ViewBuilder
    private func row(_ account: Account) -> some View {
        let code = store.code(for: account)
        let left = store.secondsRemaining(for: account)
        HStack(spacing: 0) {
            if editing {
                Button {
                    ImportFlow.confirmDelete(account, store: store)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .padding(.leading, 12)
                }
                .buttonStyle(.borderless)
                .help("Удалить аккаунт")
            }
            Button {
                guard !editing else { return }
                store.copy(account)
                flash(account.id)
                confirmCopy(account.id)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.issuer).font(.system(size: 13, weight: .semibold))
                        Text(account.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatted(code))
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundStyle(copiedID == account.id ? Color.green : Color.primary)
                    CountdownRing(secondsLeft: left, period: account.period)
                        .frame(width: 16, height: 16)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(flashID == account.id ? Color.primary.opacity(0.1) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .contextMenu {
                Button("Удалить «\(account.issuer)»…", role: .destructive) {
                    ImportFlow.confirmDelete(account, store: store)
                }
            }
        }
    }

    /// Кратковременная вспышка фона строки в момент клика. Гасим по таймеру —
    /// не полагаемся на isPressed кнопки, которое в окне MenuBarExtra залипает.
    private func flash(_ id: AccountID) {
        withAnimation(.easeOut(duration: 0.08)) { flashID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.25)) {
                if flashID == id { flashID = nil }
            }
        }
    }

    /// Зелёная подсветка кода как подтверждение «скопировано» — держится ~1с и гаснет.
    private func confirmCopy(_ id: AccountID) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                if copiedID == id { copiedID = nil }
            }
        }
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let i = code.index(code.startIndex, offsetBy: 3)
        return code[..<i] + " " + code[i...]
    }
}

/// Нейтральный стиль кнопки-строки: никакой собственной подсветки на нажатие
/// (её рисуем сами через flashID), только кликабельная область.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}

struct CountdownRing: View {
    let secondsLeft: Int
    let period: Int
    var body: some View {
        let frac = Double(secondsLeft) / Double(max(period, 1))
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(secondsLeft <= 5 ? Color.red : Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
