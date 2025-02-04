//
//  ResetPasswordViewController.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import UIKit

class ResetPasswordViewController : UIViewController {
    @IBOutlet weak var credentialTextField: UITextField!
    @IBOutlet weak var requestButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()

        UiUtils.dismissKeyboardForTaps(onView: self.view)
    }

    override func viewDidAppear(_ animated: Bool) {
        self.setInterfaceColors()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if self.isMovingFromParent {
            // If the user's logged in and is voluntarily leaving the ResetPassword VC
            // by hitting the Back button.
            let tinode = Cache.getTinode()
            if tinode.isConnectionAuthenticated || tinode.myUid != nil {
                tinode.logout()
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        self.setInterfaceColors()
    }

    private func setInterfaceColors() {
        if #available(iOS 12.0, *), traitCollection.userInterfaceStyle == .dark {
            self.view.backgroundColor = .black
        } else {
            self.view.backgroundColor = .white
        }
    }

    @IBAction func credentialTextChanged(_ sender: Any) {
        if credentialTextField.rightView != nil {
            UiUtils.clearTextFieldError(credentialTextField)
        }
    }

    @IBAction func requestButtonClicked(_ sender: Any) {
        UiUtils.clearTextFieldError(credentialTextField)
        let input = UiUtils.ensureDataInTextField(credentialTextField)
        guard let credential = ValidatedCredential.parse(from: input.lowercased()) else {
            UiUtils.markTextFieldAsError(self.credentialTextField)
            UiUtils.showToast(message: "Enter a valid credential (phone or email).")
            return
        }
        let normalized: String
        switch credential {
        case let .email(str): normalized = str
        case let .phoneNum(str): normalized = str
        default: return
        }

        let tinode = Cache.getTinode()
        UiUtils.toggleProgressOverlay(in: self, visible: true, title: "Requesting...")
        do {
            try tinode.connectDefault()?
                .thenApply(onSuccess: { _ in
                    return tinode.requestResetPassword(method: credential.methodName(), newValue: normalized)
                })?
                .thenApply(onSuccess: { _ in
                    DispatchQueue.main.async { UiUtils.showToast(message: "Message with instructions sent to the provided address.") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                        self?.navigationController?.popViewController(animated: true)
                    }
                    return nil
                })?
                .thenCatch(onFailure: UiUtils.ToastFailureHandler)?
                .thenFinally {
                    UiUtils.toggleProgressOverlay(in: self, visible: false)
                }
        } catch {
            UiUtils.toggleProgressOverlay(in: self, visible: false)
            UiUtils.showToast(message: "Request failed: \(error.localizedDescription)")
        }
    }
}
