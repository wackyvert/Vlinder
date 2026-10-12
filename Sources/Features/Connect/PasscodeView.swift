import SwiftUI

/// App-lock gate shown at launch when a passcode is set (Fladder's lock screen).
struct PasscodeView: View {
    @Environment(AppState.self) private var app
    @State private var code = ""
    @State private var wrongAttempt = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Enter passcode")
                .font(.title3.weight(.semibold))
            SecureField("Passcode", text: $code)
                .fieldStyle()
                .frame(maxWidth: TenFoot.isTV ? 520 : 200)
                .multilineTextAlignment(.center)
                .focused($focused)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: code) {
                    attemptUnlock()
                }
                .onSubmit { attemptUnlock(force: true) }
            if wrongAttempt {
                Text("Wrong passcode")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { focused = true }
    }

    private func attemptUnlock(force: Bool = false) {
        guard force || code.count >= 4 else { return }
        if app.unlock(code: code) {
            wrongAttempt = false
        } else {
            wrongAttempt = true
            if force { code = "" }
        }
    }
}

/// Two-step passcode capture used from Settings.
struct SetPasscodeSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var mismatch = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Set a passcode")
                .font(.headline)
            SecureField("Passcode (4+ digits)", text: $first)
                .fieldStyle()
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            SecureField("Repeat passcode", text: $second)
                .fieldStyle()
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            if mismatch {
                Text("Passcodes don't match")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Enable Lock") {
                    guard first.count >= 4, first == second else {
                        mismatch = true
                        return
                    }
                    app.enableAppLock(code: first)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(first.count < 4)
            }
        }
        .padding(TenFoot.cardPadding)
        .frame(maxWidth: TenFoot.isTV ? 900 : 360)
    }
}
