import SwiftUI
import SoleCore

struct SoleLogin: View {
    @EnvironmentObject private var model: SoleModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) { ConLogo(size: 25); Text("Con").font(.system(size: 14, weight: .medium, design: .rounded)) }
                Spacer()
                IconButton(icon: "xmark", help: loc("Close sign-in")) { model.cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 23).padding(.top, 18)
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 43, weight: .ultraLight)).foregroundStyle(Color.soleAccent).padding(.top, 30)
            Text(loc("Connect PlayStation")).font(.system(size: 24, weight: .semibold)).tracking(-0.5).padding(.top, 20)
            Text(loc("One sign-in for the library and the cloud."))
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 9)
            Text(loc("Sign in on Sony's website.\nSony offers the sign-in methods, including QR."))
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5).padding(.top, 25)
            Button { model.signIn() } label: {
                HStack(spacing: 9) {
                    Text(model.signingIn ? loc("Waiting for sign-in…") : loc("Sign in on Sony's website"))
                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                }.frame(width: 218)
            }.buttonStyle(QuietButton(prominent: true)).disabled(model.signingIn || model.restoringAccount || model.signingOut).padding(.top, 22)
            if model.signingIn {
                Button(loc("Cancel sign-in")) { model.cancelSignIn() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
            }
            Text(model.authError ?? loc("Your password is entered only on Sony's website."))
                .font(.system(size: 10)).foregroundStyle(model.authError == nil ? Color.secondary : Color.soleAccent)
                .multilineTextAlignment(.center).frame(minHeight: 32).padding(.horizontal, 30).padding(.top, 15)
            Spacer(minLength: 17)
        }.frame(width: 460, height: 395).background(Color.soleCanvas).tint(.soleAccent).onDisappear { model.cancelSignIn() }
    }
}
