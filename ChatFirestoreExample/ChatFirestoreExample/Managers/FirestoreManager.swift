//
//  FirestoreManager.swift
//  ChatFirestoreExample
//
//  Created by İlker İsa Mercan on 30.10.2024.
//

import Foundation
import FirebaseFirestore

// Protocol defining core functionalities for data management in the chat app
protocol FirestoreManaging: AnyObject {
    var users: [User] { get }
    var allUsers: [User] { get }
    var conversations: [Conversation] { get }
    
    func getUsers() async
    func getConversations() async
    func fetchMessages(for conversationId: String) async -> [FirestoreMessage]
    func sendMessage(to conversationId: String, message: FirestoreMessage) async
    func deleteConversation(with conversationId: String) async
    func markMessageAsRead(conversationId: String) async
    func subscribeToUpdates()
    func refreshData() async
}

// Manager for data storage and real-time updates for users and conversations
class FirestoreManager: ObservableObject, FirestoreManaging {
    static let shared = FirestoreManager()

    @Published private(set) var users: [User] = [] // List of users, excluding the current user
    @Published private(set) var allUsers: [User] = [] // All users, including the current user
    @Published private(set) var conversations: [Conversation] = [] // List of conversations for the current user

    private let firestore = Firestore.firestore()
    private let currentUser = SessionManager.currentUser

    // MARK: - Fetching Data

    /// Fetches all users from Firestore and updates the `users` and `allUsers` arrays
    func getUsers() async {
        do {
            let snapshot = try await firestore.collection(Collection.users).getDocuments()
            storeUsers(snapshot)
        } catch {
            print("Failed to fetch users: \(error)")
        }
    }

    /// Fetches all conversations involving the current user from Firestore
    func getConversations() async {
        let currentUserId = SessionManager.currentUserId
        do {
            let snapshot = try await firestore.collection(Collection.conversations)
                .whereField("users", arrayContains: currentUserId)
                .getDocuments()
            storeConversations(snapshot)
        } catch {
            print("Failed to fetch conversations: \(error)")
        }
    }

    /// Fetches messages for a specific conversation in chronological order
    func fetchMessages(for conversationId: String) async -> [FirestoreMessage] {
        do {
            let snapshot = try await firestore.collection(Collection.conversations)
                .document(conversationId).collection("messages")
                .order(by: "createdAt", descending: false)
                .getDocuments()
            return snapshot.documents.compactMap { try? $0.data(as: FirestoreMessage.self) }
        } catch {
            print("Failed to fetch messages: \(error)")
            return []
        }
    }

    // MARK: - Data Modification

    /// Sends a new message to a conversation and updates the latest message in Firestore
    func sendMessage(to conversationId: String, message: FirestoreMessage) async {
//        do {
//            let conversationRef = firestore.collection(Collection.conversations).document(conversationId)
//            try await conversationRef.updateData([
//                "latestMessage": message.dictionary // convert to Firestore-compatible dictionary
//            ])
//            await getConversations() // refresh conversation list
//        } catch {
//            print("Failed to send message: \(error)")
//        }
    }

    /// Deletes a conversation from Firestore by its ID
    func deleteConversation(with conversationId: String) async {
        do {
            try await firestore.collection(Collection.conversations).document(conversationId).delete()
            await getConversations() // refresh conversation list
        } catch {
            print("Failed to delete conversation: \(error)")
        }
    }

    /// Marks messages in a conversation as read for the current user by resetting their unread count
    func markMessageAsRead(conversationId: String) async {
        do {
            let conversationRef = firestore.collection(Collection.conversations).document(conversationId)
            try await conversationRef.updateData([
                "usersUnreadCountInfo.\(SessionManager.currentUserId)": 0 // reset unread count
            ])
        } catch {
            print("Failed to mark message as read: \(error)")
        }
    }

    // MARK: - Updates & Subscriptions

    /// Subscribes to real-time updates for user and conversation data in Firestore
    func subscribeToUpdates() {
        // Monitor changes to users collection
        firestore.collection(Collection.users)
            .addSnapshotListener { [weak self] snapshot, _ in
                self?.handleUserUpdates(snapshot)
            }

        // Monitor changes to conversations collection for the current user
        firestore.collection(Collection.conversations)
            .whereField("users", arrayContains: SessionManager.currentUserId)
            .addSnapshotListener { [weak self] snapshot, _ in
                self?.storeConversations(snapshot)
            }
    }

    /// Manually refreshes user and conversation data
    func refreshData() async {
        await getUsers()
        await getConversations()
    }

    private func handleUserUpdates(_ snapshot: QuerySnapshot?) {
        storeUsers(snapshot)
        Task {
            await getConversations() // Refresh conversations in case new users have joined
        }
    }

    // MARK: - Data Storage

    /// Processes and stores user data from Firestore, excluding the current user
    private func storeUsers(_ snapshot: QuerySnapshot?) {
        guard let currentUser = currentUser else { return }
        let newUsers: [User] = snapshot?.documents.compactMap { document in
            let data = document.data()
            guard document.documentID != currentUser.id else { return nil }
            guard let name = data["nickname"] as? String else { return nil }
            let avatarURL = data["avatarURL"] as? String
            return User(id: document.documentID, name: name, avatarURL: URL(string: avatarURL ?? ""), isCurrentUser: false)
        } ?? []

        DispatchQueue.main.async { [weak self] in
            self?.users = newUsers
            self?.allUsers = newUsers + [currentUser]
        }
    }

    /// Processes and stores conversation data from Firestore
    private func storeConversations(_ snapshot: QuerySnapshot?) {
        let newConversations = snapshot?.documents.compactMap { document in
            do {
                let firestoreConversation = try document.data(as: FirestoreConversation.self)
                return makeConversation(id: document.documentID, firestoreConversation: firestoreConversation)
            } catch {
                print("Failed to parse conversation: \(error)")
                return nil
            }
        }.sorted(by: sortConversations) ?? []

        DispatchQueue.main.async { [weak self] in
            self?.conversations = newConversations
        }
    }

    /// Creates a `Conversation` object by processing Firestore conversation data and mapping users
    private func makeConversation(id: String, firestoreConversation: FirestoreConversation) -> Conversation {
        let message = createLatestMessage(firestoreConversation.latestMessage)
        let participants = firestoreConversation.users.compactMap { userId in
            allUsers.first(where: { $0.id == userId })
        }

        return Conversation(
            id: id,
            users: participants,
            usersUnreadCountInfo: firestoreConversation.usersUnreadCountInfo,
            isGroup: firestoreConversation.isGroup,
            pictureURL: firestoreConversation.pictureURL?.toURL(),
            title: firestoreConversation.title,
            latestMessage: message
        )
    }

    /// Creates a `LatestMessageInChat` by processing a Firestore `FirestoreLatestMessage`
    private func createLatestMessage(_ latestMessage: FirestoreMessage?) -> LatestMessageInChat? {
        guard let latestMessage, let user = allUsers.first(where: { $0.id == latestMessage.userId }) else { return nil }

        let subtext: String? = {
            if !latestMessage.attachments.isEmpty, let firstAttachment = latestMessage.attachments.first {
                return firstAttachment.type.title
            }
            return latestMessage.recording != nil ? "Voice recording" : nil
        }()

        return LatestMessageInChat(
            senderName: user.name,
            createdAt: latestMessage.createdAt,
            text: latestMessage.text.isEmpty ? nil : latestMessage.text,
            subtext: subtext
        )
    }

    /// Sorting function to order conversations by the latest message date or title alphabetically
    private func sortConversations(_ conv1: Conversation, _ conv2: Conversation) -> Bool {
        if let date1 = conv1.latestMessage?.createdAt, let date2 = conv2.latestMessage?.createdAt {
            return date1 > date2
        }
        return conv1.displayTitle < conv2.displayTitle
    }
}
