//
//  MessageInteractor.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import Foundation
import TinodeSDK
import TinodiosDB

protocol MessageBusinessLogic: class {
    @discardableResult
    func setup(topicName: String?) -> Bool
    @discardableResult
    func attachToTopic(interactively: Bool) -> Bool
    func cleanup()
    func leaveTopic()

    func sendMessage(content: Drafty) -> Bool
    func sendReadNotification()
    func sendTypingNotification()
    func enablePeersMessaging()
    func acceptInvitation()
    func ignoreInvitation()
    func blockTopic()
    func uploadFile(filename: String?, refurl: URL?, mimeType: String?, data: Data?)
}

protocol MessageDataStore {
    var topicName: String? { get set }
    var topic: DefaultComTopic? { get set }
    @discardableResult
    func setup(topicName: String?) -> Bool
    func loadMessages()
    func loadNextPage()
    func deleteMessage(seqId: Int)
} 

class MessageInteractor: DefaultComTopic.Listener, MessageBusinessLogic, MessageDataStore {
    class MessageEventListener: UiTinodeEventListener {
        private weak var interactor: MessageBusinessLogic?
        init(interactor: MessageBusinessLogic?, connected: Bool) {
            super.init(connected: connected)
            self.interactor = interactor
        }
        override func onLogin(code: Int, text: String) {
            super.onLogin(code: code, text: text)
            _ = UiUtils.attachToMeTopic(meListener: nil)
            _ = interactor?.attachToTopic(interactively: false)
        }
    }
    static let kMessagesPerPage = 24
    var pagesToLoad: Int = 0
    var topicId: Int64?
    var topicName: String?
    var topic: DefaultComTopic?
    var presenter: MessagePresentationLogic?
    var messages: [StoredMessage] = []
    private var messageInteractorQueue = DispatchQueue(label: "co.tinode.messageinteractor")
    private var tinodeEventListener: MessageEventListener? = nil
    // Last reported recv and read seq ids by the onInfo handler.
    // Upon receipt of an info message, the handler will reload all messages with
    // seq ids between the last seen seq id (for recv and read messages respectively)
    // and the reported info.seq.
    // The new value for the variables below will be updated to info.seq.
    private var lastSeenRecv: Int?
    private var lastSeenRead: Int?

    @discardableResult
    func setup(topicName: String?) -> Bool {
        guard let topicName = topicName else { return false }
        self.topicName = topicName
        self.topicId = BaseDb.getInstance().topicDb?.getId(topic: topicName)
        let tinode = Cache.getTinode()
        if self.tinodeEventListener == nil {
            self.tinodeEventListener = MessageEventListener(
                interactor: self,
                connected: tinode.isConnected)
        }
        tinode.addListener(self.tinodeEventListener!)
        self.topic = tinode.getTopic(topicName: topicName) as? DefaultComTopic
        self.pagesToLoad = 1

        if let pub = self.topic?.pub {
            self.presenter?.updateTitleBar(icon: pub.photo?.image(), title: pub.fn, online: self.topic?.online ?? false)
        }
        self.lastSeenRead = self.topic?.read
        self.lastSeenRecv = self.topic?.recv
        self.topic?.listener = self
        return self.topic != nil
    }
    func cleanup() {
        // set listeners to nil
        if self.topic?.listener === self {
            self.topic?.listener = nil
        }
        let tinode = Cache.getTinode()
        if let listener = self.tinodeEventListener {
            tinode.removeListener(listener)
        }
    }
    func leaveTopic() {
        if self.topic?.attached ?? false {
            self.topic?.leave()
        }
    }
    func attachToTopic(interactively: Bool) -> Bool {
        guard let topic = self.topic, !topic.attached else {
            self.presenter?.applyTopicPermissions(withError: nil)
            return true
        }
        let tinode = Cache.getTinode()
        guard tinode.isConnectionAuthenticated else {
            // If connection is not ready, wait for completion.
            // MessageInteractor.attachToTopic() will be called again from the onLogin callback.
            tinode.reconnectNow(interactively: interactively, reset: false)
            return false
        }
        do {
            var builder = topic.getMetaGetBuilder()
                .withDesc()
                .withSub()
                .withLaterData(limit: MessageInteractor.kMessagesPerPage)
                .withDel()
            if topic.isOwner {
                builder = builder.withTags()
            }
            try topic.subscribe(set: nil, get: builder.build())?.then(
                    onSuccess: { [weak self] _ in
                        self?.messageInteractorQueue.async {
                            do {
                                try _ = self?.topic?.syncAll()?.thenApply(onSuccess: { [weak self] _ in
                                    self?.loadMessages()
                                    return nil
                                })
                            } catch {
                                Cache.log.error("MessageInteractor - Failed to send pending messages: %@", error.localizedDescription)
                            }
                        }
                        if self?.topicId == -1 {
                            self?.topicId = BaseDb.getInstance().topicDb?.getId(topic: self?.topicName)
                        }
                        self?.loadMessages()
                        self?.presenter?.applyTopicPermissions(withError: nil)
                        return nil
                    },
                    onFailure: { [weak self] err in
                        let tinode = Cache.getTinode()
                        let errorMsg = "Failed to subscribe to topic: \(err.localizedDescription)"
                        if tinode.isConnected {
                            DispatchQueue.main.async {
                                UiUtils.showToast(message: errorMsg)
                            }
                        } else {
                            Cache.log.error("MessageInteractor: %@", errorMsg)
                        }
                        switch err {
                        case TinodeError.notConnected(_):
                            tinode.reconnectNow(interactively: false, reset: false)
                        default:
                            self?.presenter?.applyTopicPermissions(withError: err)
                        }
                        return nil
                    })
        } catch TinodeError.notConnected(let errorMsg) {
            Cache.log.error("MessageInteractor - Tinode isn't connected: %@", errorMsg)
        } catch {
            Cache.log.error("MessageInteractor - error subscribing to topic: %@", error.localizedDescription)
        }
        return false
    }

    func sendMessage(content: Drafty) -> Bool {
        guard let topic = self.topic else { return false }
        defer {
            loadMessages()
        }
        do {
            _ = try topic.publish(content: content)?.then(
                onSuccess: { [weak self] msg in
                    self?.loadMessages()
                    return nil
                },
                onFailure: UiUtils.ToastFailureHandler)
        } catch TinodeError.notConnected {
            DispatchQueue.main.async { UiUtils.showToast(message: "You are offline.") }
            Cache.getTinode().reconnectNow(interactively: false, reset: false)
            return false
        } catch {
            DispatchQueue.main.async { UiUtils.showToast(message: "Message not sent.") }
            return false
        }
        return true
    }
    func sendReadNotification() {
        topic?.noteRecv()
        topic?.noteRead()
    }
    func sendTypingNotification() {
        topic?.noteKeyPress()
    }

    func loadMessages() {
        self.messageInteractorQueue.async {
            if let messages = BaseDb.getInstance().messageDb?.query(
                    topicId: self.topicId,
                    pageCount: self.pagesToLoad,
                    pageSize: MessageInteractor.kMessagesPerPage) {
                self.messages = messages
                self.presenter?.presentMessages(messages: messages)
            }
        }
    }

    private func loadNextPageInternal() -> Bool {
        if self.pagesToLoad * MessageInteractor.kMessagesPerPage == self.messages.count {
            self.pagesToLoad += 1
            self.loadMessages()
            return true
        }
        return false
    }

    func loadNextPage() {
        guard let t = self.topic else {
            self.presenter?.endRefresh()
            return
        }
        if !loadNextPageInternal() && !StoredTopic.isAllDataLoaded(topic: t) {
            do {
                try t.getMeta(query:
                    t.getMetaGetBuilder()
                        .withEarlierData(
                            limit: MessageInteractor.kMessagesPerPage)
                        .build())?.then(
                            onSuccess: { [weak self] msg in
                                self?.presenter?.endRefresh()
                                return nil
                            },
                            onFailure: { [weak self] err in
                                self?.presenter?.endRefresh()
                                return nil
                            })
            } catch {
                self.presenter?.endRefresh()
            }
        } else {
            self.presenter?.endRefresh()
        }
    }
    func deleteMessage(seqId: Int) {
        do {
            try topic?.delMessage(id: seqId, hard: false)?.then(
                onSuccess: { [weak self] msg in
                    self?.loadMessages()
                    return nil
                },
                onFailure: UiUtils.ToastFailureHandler)
            self.loadMessages()
        } catch TinodeError.notConnected(_) {
            UiUtils.showToast(message: "You are offline")
        } catch {
            UiUtils.showToast(message: "Action failed: \(error.localizedDescription)")
        }
    }

    func enablePeersMessaging() {
        // Enable peer.
        guard let origAm = self.topic?.getSubscription(for: self.topic?.name)?.acs else { return }
        let am = Acs(from: origAm)
        guard am.given?.update(from: "+RW") ?? false else {
            return
        }
        do {
            try topic?.setMeta(meta: MsgSetMeta(
                desc: nil,
                sub: MetaSetSub(user: topic?.name, mode: am.givenString),
                tags: nil,
                cred: nil))?.thenCatch(onFailure: UiUtils.ToastFailureHandler)
        } catch TinodeError.notConnected(_) {
            UiUtils.showToast(message: "You are offline")
        } catch {
            UiUtils.showToast(message: "Action failed: \(error.localizedDescription)")
        }
    }
    func acceptInvitation() {
        guard let topic = self.topic, let mode = self.topic?.accessMode?.givenString else { return }
        var response = topic.setMeta(meta: MsgSetMeta(desc: nil, sub: MetaSetSub(mode: mode), tags: nil, cred: nil))
        if topic.isP2PType {
            // For P2P topics change 'given' permission of the peer too.
            // In p2p topics the other user has the same name as the topic.
            do {
                response = try response?.thenApply(onSuccess: { msg in
                    _ = topic.setMeta(meta: MsgSetMeta(
                        desc: nil,
                        sub: MetaSetSub(user: topic.name, mode: mode),
                        tags: nil,
                        cred: nil))
                    return nil
                })
            } catch TinodeError.notConnected(_) {
                UiUtils.showToast(message: "You are offline")
            } catch {
                UiUtils.showToast(message: "Operation failed \(error.localizedDescription)")
            }
        }
        _ = try? response?.thenApply(onSuccess: { msg in
            self.presenter?.applyTopicPermissions(withError: nil)
            return nil
        })
    }
    func ignoreInvitation() {
        _ = try? self.topic?.delete()?.thenFinally(
            finally: {
                self.presenter?.dismiss()
            })
    }
    func blockTopic() {
        guard let origAm = self.topic?.accessMode else { return }
        let am = Acs(from: origAm)
        guard am.want?.update(from: "-JP") ?? false else { return }
        do {
            try self.topic?.setMeta(meta: MsgSetMeta(desc: nil, sub: MetaSetSub(mode: am.wantString), tags: nil, cred: nil))?.thenFinally(
                finally: {
                    self.presenter?.dismiss()
                })
        } catch TinodeError.notConnected(_) {
            UiUtils.showToast(message: "You are offline")
        } catch {
            UiUtils.showToast(message: "Operation failed \(error.localizedDescription)")
        }
    }
    static private func existingInteractor(for topicName: String?) -> MessageInteractor? {
        // Must be called on main thread.
        guard let topicName = topicName else { return nil }
        guard let window = UIApplication.shared.keyWindow, let navVC = window.rootViewController as? UINavigationController else {
            return nil
        }
        for controller in navVC.viewControllers {
            if let messageVC = controller as? MessageViewController, messageVC.topicName == topicName {
                return messageVC.interactor as? MessageInteractor
            }
        }
        return nil
    }
    func uploadFile(filename: String?, refurl: URL?, mimeType: String?, data: Data?) {
        guard let filename = filename, let mimeType = mimeType, let data = data, let topic = topic else { return }
        guard let content = try? Drafty().attachFile(mime: mimeType,
                                                bits: nil,
                                                fname: filename,
                                                refurl: refurl,
                                                size: data.count) else { return }
        if let msgId = topic.store?.msgDraft(topic: topic, data: content, head: Tinode.draftyHeaders(for: content)) {
            let helper = Cache.getLargeFileHelper()
            helper.startUpload(
                filename: filename, mimetype: mimeType, d: data,
                topicId: self.topicName!, msgId: msgId,
                progressCallback: { [weak self] progress in
                    let interactor = self ?? MessageInteractor.existingInteractor(for: topic.name)
                    interactor?.presenter?.updateProgress(forMsgId: msgId, progress: progress)
                },
                completionCallback: { [weak self] (serverMessage, error) in
                    let interactor = self ?? MessageInteractor.existingInteractor(for: topic.name)
                    var success = false
                    defer {
                        if !success {
                            _ = topic.store?.msgDiscard(topic: topic, dbMessageId: msgId)
                        }
                        interactor?.loadMessages()
                    }
                    guard error == nil else {
                        DispatchQueue.main.async {
                            UiUtils.showToast(message: error!.localizedDescription)
                        }
                        return
                    }
                    guard let ctrl = serverMessage?.ctrl, ctrl.code == 200, let serverUrl = ctrl.getStringParam(for: "url") else {
                        return
                    }
                    if let srvUrl = URL(string: serverUrl), let content = try? Drafty().attachFile(
                        mime: mimeType, fname: filename,
                        refurl: srvUrl, size: data.count) {
                        _ = topic.store?.msgReady(topic: topic, dbMessageId: msgId, data: content)
                        _ = try? topic.syncOne(msgId: msgId)?.thenFinally(finally: {
                            interactor?.loadMessages()
                        })
                        success = true
                    }
                })
            self.loadMessages()
        }
    }
    override func onData(data: MsgServerData?) {
        self.loadMessages()
    }
    override func onPres(pres: MsgServerPres) {
        self.presenter?.applyTopicPermissions(withError: nil)
    }
    override func onOnline(online: Bool) {
        self.presenter?.setOnline(online: online)
    }
    override func onInfo(info: MsgServerInfo) {
        switch info.what {
        case "kp":
            self.presenter?.runTypingAnimation()
        case "recv":
            if let oldRecv = self.lastSeenRecv {
                if let newRecv = info.seq, oldRecv < newRecv {
                    self.presenter?.reloadMessages(fromSeqId: oldRecv + 1, toSeqId: newRecv)
                    self.lastSeenRecv = newRecv
                }
            } else {
                self.lastSeenRead = info.seq
                self.presenter?.reloadAllMessages()
            }
        case "read":
            if let oldRead = self.lastSeenRead {
                if let newRead = info.seq, oldRead < newRead {
                    self.presenter?.reloadMessages(fromSeqId: oldRead + 1, toSeqId: newRead)
                    self.lastSeenRead = newRead
                }
            } else {
                self.lastSeenRead = info.seq
                self.presenter?.reloadAllMessages()
            }
        default:
            break
        }
    }
    override func onSubsUpdated() {
        self.presenter?.applyTopicPermissions(withError: nil)
    }
    override func onMetaDesc(desc: Description<VCard, PrivateType>) {
        self.presenter?.applyTopicPermissions(withError: nil)
        if let pub = topic?.pub {
            self.presenter?.updateTitleBar(icon: pub.photo?.image(), title: pub.fn, online: self.topic?.online ?? false)
        }
    }
}
