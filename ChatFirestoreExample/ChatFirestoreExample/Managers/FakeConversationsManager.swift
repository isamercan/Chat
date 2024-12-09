//
//  FakeConversationsManager.swift
//  ChatFirestoreExample
//
//  Created by Alisa Mylnikova on 14.07.2023.
//

import Foundation
import FirebaseFirestore

class FakeConversationsManager {

    /// add fake users and conversation so you don't feel alone

    func createFakesIfNeeded() {
        Task {
            do {
                // check if users were already created
                let usersSnapshot = try await Firestore.firestore()
                    .collection(Collection.users)
                    .whereField("deviceId", isEqualTo: "0")
                    .getDocuments()

                //MARK: if not - create both: users and conversations
                if usersSnapshot.isEmpty {
                    addFakeUsersWithConversations()
                    return
                }

            } catch {
                print(error.localizedDescription)
            }
            
            do {
                let db = Firestore.firestore()
                let snapshot = try await db.collection(Collection.conversations).whereField("users", in: [SessionManager.currentUserId]).getDocuments()

//                // if yes - check if conversations were already created
//                let snapshot = try await Firestore.firestore()
//                    .collection(Collection.conversations)
//                    .whereField("users", arrayContainsAny: [SessionManager.currentUserId])
//                    .getDocuments()

                if snapshot.isEmpty {
                    addFakeConversations()
                }
            }catch {
                print(error.localizedDescription)
            }
        }
            
    }

    func addFakeUsersWithConversations() {
        createNewUser(nickname: "Bob", imageName: "bob")
        createNewUser(nickname: "Steve", imageName: "steve")
        createNewUser(nickname: "Tim", imageName: "tim")
    }

    func addFakeConversations() {
        createIndividualConversation("Bob")
        createIndividualConversation("Steve")
        createIndividualConversation("Tim")
    }

    func createNewUser(nickname: String, imageName: String) {
        Task {
            guard let data = UIImage(named: imageName)?.jpegData(compressionQuality: 1.0),
                  let avatarURL = await UploadingManager.uploadImageData(data) else { return }

            try await Firestore.firestore()
                .collection(Collection.users)
                .document(nickname)
                .setData([
                    "deviceId": "0",
                    "nickname": nickname,
                    "avatarURL": avatarURL.absoluteString
                ])

            createIndividualConversation(nickname)
        }
    }

    private func createIndividualConversation(_ userId: String) {
        Task {
            guard let currentUser = SessionManager.currentUser else { return }
            let allUserIds = [userId, currentUser.id]
            let dict: [String : Any] = [
                "users": allUserIds,
                "usersUnreadCountInfo": Dictionary(uniqueKeysWithValues: allUserIds.map { ($0, 0) } ),
                "isGroup": false,
                "title": "a"
            ]
            
            let conversation = try await Firestore.firestore()
                .collection(Collection.conversations)
                .addDocument(data: dict)

            print("created", [userId, currentUser.id])

            try await conversation
                .collection(Collection.messages)
                .addDocument(data: fakeMessageDict(userId: userId, index: 0))

            let latestDict = fakeMessageDict(userId: userId, index: 1)
            try await conversation
                .collection(Collection.messages)
                .addDocument(data: latestDict)

            try await conversation
                .updateData(["latestMessage" : latestDict])
        }
    }

    func fakeMessageDict(userId: String, index: Int) -> [String: Any] {
        let texts = [
            "Bob": [
                "Hello",
                "Welcome to Firestore chat example"
            ],
            "Steve": [
                "How's it going",
                "I'm a bot, but you can send messages to me"
            ],
            "Tim": [
                "Morning!",
                "You look great today!"
            ]
        ]

        return [
            "userId": userId,
            "createdAt": Timestamp(date: Date()),
            "text": texts[userId]?[index] ?? "",
            "attachments": []
        ]
    }
}
