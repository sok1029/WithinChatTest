/// Copyright (c) 2018 Razeware LLC
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
///
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import UIKit
import Firebase
import MessageKit
import FirebaseFirestore
import Photos
import WXImageCompress

  
final class ChatViewController: MessagesViewController {
  
  private let db = Firestore.firestore()
  private var reference: CollectionReference?
  
  private var messages: [Message] = []
  private var messageListener: ListenerRegistration?
  
  private let user: User
  private let channel: Channel
  private let mediaWidth: CGFloat = UIScreen.main.bounds.size.width * 2.0 / 3.0
  
  var isFirstLoad = true
  var lastDocSnapshot: QueryDocumentSnapshot?
  let loadDataNum: Int = 15
  let topOffsetForLoading: CGFloat = -50
  
  private var moveToBottomButton: UIButton
  var fetching = false
  var scrollDecelerating = false

  var runLoadPrevMessage: (() -> ())?
  
  private var isSendingPhoto = false {
    didSet {
      DispatchQueue.main.async {
        self.messageInputBar.leftStackViewItems.forEach { item in
          item.isEnabled = !self.isSendingPhoto
        }
      }
    }
  }

  private let storage = Storage.storage().reference()
  
  init(user: User, channel: Channel) {
    self.user = user
    self.channel = channel
    self.moveToBottomButton = UIButton(frame: CGRect(x: 250, y: 250, width: 50, height: 50))

    super.init(nibName: nil, bundle: nil)
    
    title = channel.name
  }
  
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    navigationItem.largeTitleDisplayMode = .never
    
    maintainPositionOnKeyboardFrameChanged = true
    messageInputBar.inputTextView.tintColor = .primary
    messageInputBar.sendButton.setTitleColor(.primary, for: .normal)
    
    messageInputBar.delegate = self
    messagesCollectionView.messagesDataSource = self
    messagesCollectionView.messagesLayoutDelegate = self
    messagesCollectionView.messagesDisplayDelegate = self
    
    guard let id = channel.id else {
      navigationController?.popViewController(animated: true)
      return
    }

    reference = db.collection(["channels", id, "thread"].joined(separator: "/"))

    initDocuments()
    
    let cameraItem = InputBarButtonItem(type: .system)
    cameraItem.tintColor = .primary
    cameraItem.image = #imageLiteral(resourceName: "camera")

    cameraItem.addTarget(
      self,
      action: #selector(cameraButtonPressed),
      for: .primaryActionTriggered
    )
    cameraItem.setSize(CGSize(width: 60, height: 30), animated: false)

    messageInputBar.leftStackView.alignment = .center
    messageInputBar.setLeftStackViewWidthConstant(to: 50, animated: false)

    messageInputBar.setStackViewItems([cameraItem], forStack: .left, animated: false)
    
//    moveToButtomButton = UIButton(frame: CGRect(x: 250, y: 250, width: 50, height: 50))
    moveToBottomButton.backgroundColor = .red
    moveToBottomButton.isHidden = true
    moveToBottomButton.addTarget(self, action: #selector(moveToBottom), for: .touchUpInside)
    self.view.addSubview(moveToBottomButton)
  }
  
  deinit {
    messageListener?.remove()
  }
  
  
  // MARK: - Helpers
  @IBAction func moveToBottom(){
    self.messagesCollectionView.scrollToBottom()
  }
  
  func initDocuments (){
     let first = reference?.order(by: "created", descending: true).limit(to: loadDataNum)
     messageListener = first?.addSnapshotListener({ [weak self] (snapshot, error) in
        guard let sSelf = self else { return }
        guard let snapshot = snapshot else { return }

        if sSelf.isFirstLoad{
            sSelf.loadFirstData(snapshot)
            guard let lastSnapshot = snapshot.documents.last else { return }
            sSelf.lastDocSnapshot = lastSnapshot
            sSelf.loadPrevData()
        }
        else{
          snapshot.documentChanges.forEach { (change) in
            sSelf.handleDocumentChange(change)
          }
        }
      })
   }
  
  private func loadFirstData(_ snapshot: QuerySnapshot){
    isFirstLoad = false

    snapshot.documentChanges.forEach { (change) in
      guard let message = Message(document: change.document) else{ return }
      messages.append(message)
    }
    
    messages.sort()
    messagesCollectionView.reloadData()
    messagesCollectionView.performBatchUpdates({
      messagesCollectionView.scrollToBottom()
    })

  }
  
  private func handleDocumentChange(_ change: DocumentChange){
    guard var message = Message(document: change.document) else{ return }
    if isFromCurrentSender(message: message) { return }
    
    if let url = message.downloadURL {
      //from cache
      if let img = UIImage.loadImage(urlString: url.absoluteString){
        message.image = img
        insertMessage(message)
      }
      else{ //from server
        //insert server image
        downloadImage(at: url) { [weak self] image in
          guard let sSelf = self else { return }
          guard let image = image else { return }

          message.image = image
          sSelf.insertMessage(message)
          DispatchQueue.global().async {
              UIImage.storeImage(urlString: url.absoluteString, img: image)
          }
        }
      }
    }
    else {
      insertMessage(message)
    }
  }
  
  private func loadPrevData() {
      guard let snapShot = self.lastDocSnapshot else { return }

      let prev = self.reference?.order(by: "created", descending: true).limit(to: loadDataNum).start(afterDocument: snapShot)
      prev?.getDocuments(completion: { [weak self]( snapshot, error) in
        guard let sSelf = self else { return }
        
        if let run = sSelf.runLoadPrevMessage{
           run()
           sSelf.runLoadPrevMessage = nil
        }

        if let e = error{
            print(e)
        }
        else{
          guard let lastDocSnapShot = snapshot?.documents.last else { return }
          sSelf.lastDocSnapshot = lastDocSnapShot
          guard let docs = snapshot?.documents else { return  }
         
          func loadPrevMessage(){
            var newMsgs = [Message]()
            for doc in docs {
              guard let msg = Message(document: doc) else { break }
              newMsgs.append(msg)
            }
            newMsgs.sort()

            sSelf.messages.insert(contentsOf: newMsgs, at: 0)
            sSelf.messagesCollectionView.reloadData()
            sSelf.messagesCollectionView.performBatchUpdates({
              let moveSection =  newMsgs.count > 0 ? (newMsgs.count - 2) : 0
               let indexPath = IndexPath(row: 0, section: moveSection)
               sSelf.messagesCollectionView.scrollToItem(at: indexPath, at: .top, animated: false)
             }) { _ in
               sSelf.fetching = false
             }
          }
          sSelf.runLoadPrevMessage = loadPrevMessage
        }
    })
  }
  
  private func insertMessage(_ message: Message) {
//    guard !messages.contains(message) else {
//      return
//      }
    messages.append(message)
    messages.sort()
//    messagesCollectionView.reloadSections([messages.count])
    
    messagesCollectionView.reloadData()
    
    let isLatestMessage = messages.index(of: message) == (messages.count - 1)
    let shouldScrollToBottom = messagesCollectionView.isAtBottom && isLatestMessage
    
    if shouldScrollToBottom {
        DispatchQueue.main.async {
          self.messagesCollectionView.scrollToBottom(animated: false)
        }
    }
  }
  
  private func save(_ message: Message) {
    reference?.addDocument(data: message.representation) { error in
      if let e = error {
        print("Error sending message: \(e.localizedDescription)")
        return
      }
    }
  }
  
  private func uploadImage(_ image: UIImage, to channel: Channel, completion: @escaping (URL?) -> Void) {
    guard let channelID = channel.id else {
      completion(nil)
      return
    }
//    guard let scaledImage = image.scaledToSafeUploadSize,
    guard let data = image.jpegData(compressionQuality: 1.0) else {
      completion(nil)
      return
    }
    
    let metadata = StorageMetadata()
    metadata.contentType = "image/jpeg"
    
    let imageName = [UUID().uuidString, String(Date().timeIntervalSince1970)].joined()
    storage.child(channelID).child(imageName).putData(data, metadata: metadata) { meta, error in
      completion(meta?.downloadURL())
    }
  }
  
  private func sendPhoto(_ image: UIImage) {
    let thumbImg = image.wxCompress()
    preApplyPhoto(thumbImg)
    isSendingPhoto = true
    
    uploadImage(thumbImg, to: channel) { [weak self] url in
      guard let sSelf = self else { return }
      sSelf.isSendingPhoto = false
      
      guard let url = url else { return }
      
      var message = Message(user: sSelf.user, image: thumbImg)
      message.downloadURL = url
      UIImage.storeImage(urlString: url.absoluteString, img: image)
      sSelf.save(message)
    }
  }

  private func downloadImage(at url: URL, completion: @escaping (UIImage?) -> Void) {
    let ref = Storage.storage().reference(forURL: url.absoluteString)
    let megaByte = Int64(1 * 1024 * 1024)
    
    ref.getData(maxSize: megaByte) { data, error in
      guard let imageData = data else {
        completion(nil)
        return
      }
      
      completion(UIImage(data: imageData))
    }
  }
  // MARK: - Actions
  
  @objc private func cameraButtonPressed() {
    let picker = UIImagePickerController()
    picker.delegate = self

    if UIImagePickerController.isSourceTypeAvailable(.camera) {
      picker.sourceType = .camera
    } else {
      picker.sourceType = .photoLibrary
    }

    present(picker, animated: true, completion: nil)
  }
  
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let boundsHeight = scrollView.bounds.height
    let contentHeight = scrollView.contentSize.height
    let contentOffsetY = scrollView.contentOffset.y
    moveToBottomButton.isHidden = (contentHeight - contentOffsetY) > (boundsHeight * 2) ? false : true
    
    if (contentOffsetY < topOffsetForLoading) && scrollDecelerating{
      if !fetching{
          fetchData()
      }
    }
  }
  
  func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
     scrollDecelerating = true
  }
  
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    scrollDecelerating = false
  }
  
  private func fetchData(){
      fetching = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.0001, execute: { [weak self] in
          self?.loadPrevData()
      })
  }
  
  public override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    print("cellForItem:\(indexPath.section)")
//      guard let messagesDataSource = messagesCollectionView.messagesDataSource else {
//          fatalError("Ouch. nil data source for messages")
//      }
//
//      // Very important to check this when overriding `cellForItemAt`
//      // Super method will handle returning the typing indicator cell
////      guard !isSectionReservedForTypingIndicator(indexPath.section) else {
////          return super.collectionView(collectionView, cellForItemAt: indexPath)
////      }
////
//      let message = messagesDataSource.messageForItem(at: indexPath, in: messagesCollectionView)

    
//    let cell = super.collectionView(collectionView, cellForItemAt: indexPath) as! MessageCollectionViewCell
    let message = messages[indexPath.section]
    
    if message.isImageMessage() {
      if let _ = message.image{ } //already image set
      else{
        if let url = message.downloadURL{
          //from cache
          DispatchQueue.global().sync{
            if let img = UIImage.loadImage(urlString: url.absoluteString){
              messages[indexPath.section].image = img
              DispatchQueue.main.async{[weak self] in
                self?.messagesCollectionView.reloadSections([indexPath.section])
              }
            }
            else{
            //from server
              downloadImage(at: url) { [weak self] image in
                guard let sSelf = self else { return }
                guard let img = image else { return }
                sSelf.messages[indexPath.section].image = img
                DispatchQueue.global().async {
                  UIImage.storeImage(urlString: url.absoluteString, img: img)
                }
                DispatchQueue.main.async{
                  self?.messagesCollectionView.reloadSections([indexPath.section])
                }
              }
            }
          }
        }
      }
    }
    return super.collectionView(collectionView, cellForItemAt: indexPath) as! MessageCollectionViewCell
  }
  
}

// MARK: - // MARK: - MessagesDisplayDelegate


extension ChatViewController: MessagesDataSource {
  // 1
  func currentSender() -> Sender {
    return Sender(id: user.uid, displayName: AppSettings.displayName)
  }

  // 2
  func numberOfMessages(in messagesCollectionView: MessagesCollectionView) -> Int {
    return messages.count
  }

  // 3
  func messageForItem(at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> MessageType {

    return messages[indexPath.section]
  }
  

  func cellTopLabelAlignment(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> LabelAlignment {
//      guard let dataSource = messagesCollectionView.messagesDataSource else { return nil }
    
      let edgeInset = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
      return isFromCurrentSender(message: message) ? .messageTrailing(.zero) : .messageLeading(edgeInset)
  }

  // 4
  func cellTopLabelAttributedText(for message: MessageType,
    at indexPath: IndexPath) -> NSAttributedString? {

    let name = isFromCurrentSender(message: message) ? "" : message.sender.displayName
    return NSAttributedString(
      string: name,
      attributes: [
        .font: UIFont.preferredFont(forTextStyle: .caption1),
        .foregroundColor: UIColor(white: 0.3, alpha: 1)
      ]
    )
  }
}

// MARK: - MessagesLayoutDelegate

extension ChatViewController: MessagesLayoutDelegate {

  func widthForMedia(message: MessageType, at indexPath: IndexPath, with maxWidth: CGFloat, in messagesCollectionView: MessagesCollectionView) -> CGFloat {
      return mediaWidth
  }
  
  func heightForMedia(message: MessageType, at indexPath: IndexPath, with maxWidth: CGFloat, in messagesCollectionView: MessagesCollectionView) -> CGFloat {
  
    switch message.data {
       case .photo(_), .video(_, _):
        let boundingRect = CGRect(origin: .zero, size: CGSize(width: mediaWidth, height: .greatestFiniteMagnitude))
           return AVMakeRect(aspectRatio: messages[indexPath.section].imageSize!, insideRect: boundingRect).height
       default:
           return 0
       }
   }
  
  func avatarSize(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> CGSize {
    
    return isFromCurrentSender(message: message) ? .zero :  CGSize(width: 35, height: 35)
  }
  
//  func messagePadding(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> UIEdgeInsets {
//
//    if isFromCurrentSender(message: message) {
//            return UIEdgeInsets(top: 0, left: 30, bottom: 0, right: 4)
//        } else {
//            return UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 30)
//        }
//
//  }
  func avatarPosition(for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) -> AvatarPosition {
    return AvatarPosition(horizontal: .natural, vertical: .messageBottom)
  }
  
  func footerViewSize(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> CGSize {

    // 2
    return CGSize(width: 0, height: 8)
  }

  func heightForLocation(message: MessageType, at indexPath: IndexPath,
    with maxWidth: CGFloat, in messagesCollectionView: MessagesCollectionView) -> CGFloat {

    // 3
    return 0
  }
  
  private func preApplyPhoto(_ image: UIImage){
    let message = Message(user: user, image: image)
    insertMessage(message)
    DispatchQueue.main.async {
      self.messagesCollectionView.scrollToBottom(animated: false)
    }
  }
}

// MARK: - MessagesDisplayDelegate

extension ChatViewController: MessagesDisplayDelegate {
  
  func configureAvatarView(_ avatarView: AvatarView, for message: MessageType, at indexPath: IndexPath, in messagesCollectionView: MessagesCollectionView) {
      avatarView.image = UIImage.init(named: "2")
      
  }
  func backgroundColor(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> UIColor {
    
    if messages[indexPath.section].isImageMessage(){
      return .imageMessage
    }
    
    return isFromCurrentSender(message: message) ? .primary : .incomingMessage
  }

  func shouldDisplayHeader(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> Bool {

    // 2
    return false
  }

  func messageStyle(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> MessageStyle {

    let corner: MessageStyle.TailCorner = isFromCurrentSender(message: message) ? .bottomRight : .bottomLeft

    // 3
    return .bubbleTail(corner, .pointedEdge)
  }
  
}

// MARK: - MessageInputBarDelegate

extension ChatViewController: MessageInputBarDelegate {
  
  func messageInputBar(_ inputBar: MessageInputBar, didPressSendButtonWith text: String) {

    // 1
    let message = Message(user: user, content: text)

    // 2
    insertMessage(message)
    DispatchQueue.main.async {
      self.messagesCollectionView.scrollToBottom(animated: false)
    }
    save(message)
    // 3
    inputBar.inputTextView.text = ""
  }
  
}

// MARK: - UIImagePickerControllerDelegate

extension ChatViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerController(_ picker: UIImagePickerController,
                             didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
    picker.dismiss(animated: true, completion: nil)
    
    // 1
    if let asset = info[.phAsset] as? PHAsset {
      let size = CGSize(width: 500, height: 500)
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: size,
        contentMode: .aspectFit,
        options: nil) { result, info in
          
        guard let image = result else {
          return
        }
        
        self.sendPhoto(image)
      }

    // 2
    } else if let image = info[.originalImage] as? UIImage {
      sendPhoto(image)
    }
  }
  
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true, completion: nil)
  }
}
