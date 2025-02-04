//
//  SignupViewController.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import UIKit
import TinodeSDK

class SignupViewController: UITableViewController {

    @IBOutlet weak var avatarImageView: RoundImageView!
    @IBOutlet weak var loginTextField: UITextField!
    @IBOutlet weak var passwordTextField: UITextField!
    @IBOutlet weak var nameTextField: UITextField!
    @IBOutlet weak var emailPhoneTextField: UITextField!
    @IBOutlet weak var signUpButton: UIButton!

    var imagePicker: ImagePicker!
    var uploadedAvatar: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()

        self.imagePicker = ImagePicker(presentationController: self, delegate: self, editable: true)

        // Listen to text change events to clear the possible error from earlier attempt.
        loginTextField.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
        passwordTextField.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
        nameTextField.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
        emailPhoneTextField.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
        UiUtils.dismissKeyboardForTaps(onView: self.view)
    }

    @objc func textFieldDidChange(_ textField: UITextField) {
        UiUtils.clearTextFieldError(textField)
    }

    @IBAction func addAvatarClicked(_ sender: Any) {
        // Get avatar image
        self.imagePicker.present(from: self.view)
    }

    @IBAction func signUpClicked(_ sender: Any) {
        let login = UiUtils.ensureDataInTextField(loginTextField)
        let pwd = UiUtils.ensureDataInTextField(passwordTextField)
        let name = UiUtils.ensureDataInTextField(nameTextField, maxLength: UiUtils.kMaxTitleLength)
        let credential = UiUtils.ensureDataInTextField(emailPhoneTextField)

        guard !login.isEmpty && !pwd.isEmpty && !name.isEmpty && !credential.isEmpty else { return }

        var method: String? = nil
        if let cred = ValidatedCredential.parse(from: credential) {
            switch cred {
            case .email:
                method = Credential.kMethEmail
            case .phoneNum:
                method = Credential.kMethPhone
            default:
                break
            }
        }

        guard method != nil else {
            UiUtils.markTextFieldAsError(emailPhoneTextField)
            return
        }

        signUpButton.isUserInteractionEnabled = false
        let tinode = Cache.getTinode()

        let avatar = uploadedAvatar ? avatarImageView?.image?.resize(width: UiUtils.kAvatarSize, height: UiUtils.kAvatarSize, clip: true) : nil
        let vcard = VCard(fn: name, avatar: avatar)

        let desc = MetaSetDesc<VCard, String>(pub: vcard, priv: nil)
        let cred = Credential(meth: method!, val: credential)
        var creds = [Credential]()
        creds.append(cred)
        UiUtils.toggleProgressOverlay(in: self, visible: true, title: "Registering...")
        do {
            try tinode.connectDefault()?.thenApply(
                    onSuccess: { pkt in
                        print("Successfully connected, creating account")
                        return tinode.createAccountBasic(
                            uname: login, pwd: pwd, login: true,
                            tags: nil, desc: desc, creds: creds)
            })?.thenApply(
                onSuccess: { [weak self] msg in
                    if let ctrl = msg?.ctrl, ctrl.code >= 300, ctrl.text.contains("validate credentials") {
                        DispatchQueue.main.async {
                            UiUtils.routeToCredentialsVC(in: self!.navigationController,
                                                         verifying: ctrl.getStringArray(for: "cred")?.first)
                        }
                    } else {
                        if let token = tinode.authToken {
                            tinode.setAutoLoginWithToken(token: token)
                        }
                        UiUtils.routeToChatListVC()
                    }
                    return nil
            })?.thenCatch(
                onFailure: { err in
                    DispatchQueue.main.async {
                        UiUtils.showToast(message: "Failed to create account: \(err.localizedDescription)")
                    }
                    tinode.disconnect()
                    return nil
            })?.thenFinally(finally: { [weak self] in
                guard let signupVC = self else { return }
                DispatchQueue.main.async {
                    signupVC.signUpButton.isUserInteractionEnabled = true
                    UiUtils.toggleProgressOverlay(in: signupVC, visible: false)
                }
            })
        } catch {
            tinode.disconnect()
            DispatchQueue.main.async {
                UiUtils.showToast(message: "Failed to create account: \(error.localizedDescription)")
                self.signUpButton.isUserInteractionEnabled = true
                UiUtils.toggleProgressOverlay(in: self, visible: false)
            }
        }
    }
}

extension SignupViewController: ImagePickerDelegate {
    func didSelect(image: UIImage?, mimeType: String?, fileName: String?) {
        guard let image = image?.resize(width: CGFloat(UiUtils.kAvatarSize), height: CGFloat(UiUtils.kAvatarSize), clip: true) else {
            return
        }

        self.avatarImageView.image = image
        uploadedAvatar = true
    }
}

