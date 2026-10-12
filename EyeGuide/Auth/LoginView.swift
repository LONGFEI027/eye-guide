import SwiftUI

struct LoginView: View {
    @ObservedObject var account: Account
    @State private var name = UserDefaults.standard.string(forKey: "login") ?? ""
    @State private var password = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("登录").font(.title2.bold()).padding(.top, 28)
            Text("用茉兔网站（feizhu.asia）的账号登录，用量记在同一个账户里")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            TextField("账号", text: $name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).padding(.horizontal, 30)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 30)
            if !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                busy = true; error = ""
                Task {
                    do { try await account.signIn(name: name, password: password) }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            } label: {
                Text(busy ? "登录中…" : "登录").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || name.isEmpty || password.isEmpty)
            .padding(.horizontal, 30)
            Spacer()
        }
        .interactiveDismissDisabled()
    }
}
