import Foundation
import SwiftSignalKit
import Postbox
import TelegramApi

public func canShareLinkToPeer(peer: EnginePeer) -> Bool {
    var isEnabled = false
    switch peer {
    case let .channel(channel):
        if channel.flags.contains(.isCreator) || (channel.adminRights?.rights.contains(.canInviteUsers) == true) {
            isEnabled = true
        } else if channel.username != nil {
            isEnabled = true
        }
    case let .legacyGroup(group):
        if !group.hasBannedPermission(.banAddMembers) {
            isEnabled = true
        }
    default:
        break
    }
    return isEnabled
}

public enum ExportChatFolderError {
    case generic
    case sharedFolderLimitExceeded(limit: Int32, premiumLimit: Int32)
    case limitExceeded(limit: Int32, premiumLimit: Int32)
}

public struct ExportedChatFolderLink: Equatable {
    public var title: String
    public var link: String
    public var peerIds: [EnginePeer.Id]
    public var isRevoked: Bool
    
    public init(
        title: String,
        link: String,
        peerIds: [EnginePeer.Id],
        isRevoked: Bool
    ) {
        self.title = title
        self.link = link
        self.peerIds = peerIds
        self.isRevoked = isRevoked
    }
}

public extension ExportedChatFolderLink {
    var slug: String {
        var slug = self.link
        if slug.hasPrefix("https://t.me/folder/") {
            slug = String(slug[slug.index(slug.startIndex, offsetBy: "https://t.me/folder/".count)...])
        }
        return slug
    }
}

func _internal_exportChatFolder(account: Account, filterId: Int32, title: String, peerIds: [PeerId]) -> Signal<ExportedChatFolderLink, ExportChatFolderError> {
    return account.postbox.transaction { transaction -> [Api.InputPeer] in
        return peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
    }
    |> castError(ExportChatFolderError.self)
    |> mapToSignal { inputPeers -> Signal<ExportedChatFolderLink, ExportChatFolderError> in
        return account.network.request(Api.functions.communities.exportCommunityInvite(community: .inputCommunityDialogFilter(filterId: filterId), title: title, peers: inputPeers))
        |> `catch` { error -> Signal<Api.communities.ExportedCommunityInvite, ExportChatFolderError> in
            if error.errorDescription == "INVITES_TOO_MUCH" || error.errorDescription == "COMMUNITIES_TOO_MUCH" {
                return account.postbox.transaction { transaction -> (AppConfiguration, Bool) in
                    return (currentAppConfiguration(transaction: transaction), transaction.getPeer(account.peerId)?.isPremium ?? false)
                }
                |> castError(ExportChatFolderError.self)
                |> mapToSignal { appConfiguration, isPremium -> Signal<Api.communities.ExportedCommunityInvite, ExportChatFolderError> in
                    let userDefaultLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: false)
                    let userPremiumLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: true)
                    
                    if error.errorDescription == "COMMUNITIES_TOO_MUCH" {
                        if isPremium {
                            return .fail(.sharedFolderLimitExceeded(limit: userPremiumLimits.maxSharedFolderJoin, premiumLimit: userPremiumLimits.maxSharedFolderJoin))
                        } else {
                            return .fail(.sharedFolderLimitExceeded(limit: userDefaultLimits.maxSharedFolderJoin, premiumLimit: userPremiumLimits.maxSharedFolderJoin))
                        }
                    } else {
                        if isPremium {
                            return .fail(.limitExceeded(limit: userPremiumLimits.maxSharedFolderInviteLinks, premiumLimit: userPremiumLimits.maxSharedFolderInviteLinks))
                        } else {
                            return .fail(.limitExceeded(limit: userDefaultLimits.maxSharedFolderInviteLinks, premiumLimit: userPremiumLimits.maxSharedFolderInviteLinks))
                        }
                    }
                }
            } else {
                return .fail(.generic)
            }
        }
        |> mapToSignal { result -> Signal<ExportedChatFolderLink, ExportChatFolderError> in
            return account.postbox.transaction { transaction -> Signal<ExportedChatFolderLink, ExportChatFolderError> in
                switch result {
                case let .exportedCommunityInvite(filter, invite):
                    let parsedFilter = ChatListFilter(apiFilter: filter)
                    
                    let _ = updateChatListFiltersState(transaction: transaction, { state in
                        var state = state
                        if let index = state.filters.firstIndex(where: { $0.id == filterId }) {
                            state.filters[index] = parsedFilter
                        } else {
                            state.filters.append(parsedFilter)
                        }
                        state.remoteFilters = state.filters
                        return state
                    })
                    
                    switch invite {
                    case let .exportedCommunityInvite(flags, title, url, peers):
                        return .single(ExportedChatFolderLink(
                            title: title,
                            link: url,
                            peerIds: peers.map(\.peerId),
                            isRevoked: (flags & (1 << 0)) != 0
                        ))
                    }
                }
            }
            |> castError(ExportChatFolderError.self)
            |> switchToLatest
        }
    }
}

func _internal_getExportedChatFolderLinks(account: Account, id: Int32) -> Signal<[ExportedChatFolderLink]?, NoError> {
    return account.network.request(Api.functions.communities.getExportedInvites(community: .inputCommunityDialogFilter(filterId: id)))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.communities.ExportedInvites?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<[ExportedChatFolderLink]?, NoError> in
        guard let result = result else {
            return .single(nil)
        }
        return account.postbox.transaction { transaction -> [ExportedChatFolderLink]? in
            switch result {
            case let .exportedInvites(invites, chats, users):
                var peers: [Peer] = []
                var peerPresences: [PeerId: Api.User] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    peers.append(telegramUser)
                    peerPresences[telegramUser.id] = user
                }
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        peers.append(peer)
                    }
                }
                
                updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                var result: [ExportedChatFolderLink] = []
                for invite in invites {
                    switch invite {
                    case let .exportedCommunityInvite(flags, title, url, peers):
                        result.append(ExportedChatFolderLink(
                            title: title,
                            link: url,
                            peerIds: peers.map(\.peerId),
                            isRevoked: (flags & (1 << 0)) != 0
                        ))
                    }
                }
                
                return result
            }
        }
    }
}

public enum EditChatFolderLinkError {
    case generic
}

func _internal_editChatFolderLink(account: Account, filterId: Int32, link: ExportedChatFolderLink, title: String?, peerIds: [EnginePeer.Id]?, revoke: Bool) -> Signal<ExportedChatFolderLink, EditChatFolderLinkError> {
    return account.postbox.transaction { transaction -> Signal<ExportedChatFolderLink, EditChatFolderLinkError> in
        var flags: Int32 = 0
        if revoke {
            flags |= 1 << 0
        }
        if title != nil {
            flags |= 1 << 1
        }
        var peers: [Api.InputPeer]?
        if let peerIds = peerIds {
            flags |= 1 << 2
            peers = peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
        }
        return account.network.request(Api.functions.communities.editExportedInvite(flags: flags, community: .inputCommunityDialogFilter(filterId: filterId), slug: link.slug, title: title, peers: peers))
        |> mapError { _ -> EditChatFolderLinkError in
            return .generic
        }
        |> map { result in
            switch result {
            case let .exportedCommunityInvite(flags, title, url, peers):
                return ExportedChatFolderLink(
                    title: title,
                    link: url,
                    peerIds: peers.map(\.peerId),
                    isRevoked: (flags & (1 << 0)) != 0
                )
            }
        }
    }
    |> castError(EditChatFolderLinkError.self)
    |> switchToLatest
    
}

public enum RevokeChatFolderLinkError {
    case generic
}

func _internal_deleteChatFolderLink(account: Account, filterId: Int32, link: ExportedChatFolderLink) -> Signal<Never, RevokeChatFolderLinkError> {
    return account.network.request(Api.functions.communities.deleteExportedInvite(community: .inputCommunityDialogFilter(filterId: filterId), slug: link.slug))
    |> mapError { error -> RevokeChatFolderLinkError in
        return .generic
    }
    |> ignoreValues
}

public enum CheckChatFolderLinkError {
    case generic
}

public final class ChatFolderLinkContents {
    public let localFilterId: Int32?
    public let title: String?
    public let peers: [EnginePeer]
    public let alreadyMemberPeerIds: Set<EnginePeer.Id>
    public let memberCounts: [EnginePeer.Id: Int]
    
    public init(
        localFilterId: Int32?,
        title: String?,
        peers: [EnginePeer],
        alreadyMemberPeerIds: Set<EnginePeer.Id>,
        memberCounts: [EnginePeer.Id: Int]
    ) {
        self.localFilterId = localFilterId
        self.title = title
        self.peers = peers
        self.alreadyMemberPeerIds = alreadyMemberPeerIds
        self.memberCounts = memberCounts
    }
}

func _internal_checkChatFolderLink(account: Account, slug: String) -> Signal<ChatFolderLinkContents, CheckChatFolderLinkError> {
    return account.network.request(Api.functions.communities.checkCommunityInvite(slug: slug))
    |> mapError { _ -> CheckChatFolderLinkError in
        return .generic
    }
    |> mapToSignal { result -> Signal<ChatFolderLinkContents, CheckChatFolderLinkError> in
        return account.postbox.transaction { transaction -> ChatFolderLinkContents in
            switch result {
            case let .communityInvite(_, title, emoticon, peers, chats, users):
                let _ = emoticon
                
                var allPeers: [Peer] = []
                var peerPresences: [PeerId: Api.User] = [:]
                var memberCounts: [PeerId: Int] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    allPeers.append(telegramUser)
                    peerPresences[telegramUser.id] = user
                }
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        allPeers.append(peer)
                    }
                    if case let .channel(_, _, _, _, _, _, _, _, _, _, _, _, participantsCount, _) = chat {
                        if let participantsCount = participantsCount {
                            memberCounts[chat.peerId] = Int(participantsCount)
                        }
                    }
                }
                
                updatePeers(transaction: transaction, peers: allPeers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                var resultPeers: [EnginePeer] = []
                var alreadyMemberPeerIds = Set<EnginePeer.Id>()
                for peer in peers {
                    if let peerValue = transaction.getPeer(peer.peerId) {
                        resultPeers.append(EnginePeer(peerValue))
                        
                        if transaction.getPeerChatListIndex(peer.peerId) != nil {
                            alreadyMemberPeerIds.insert(peer.peerId)
                        }
                    }
                }
                alreadyMemberPeerIds.removeAll()
                
                return ChatFolderLinkContents(localFilterId: nil, title: title, peers: resultPeers, alreadyMemberPeerIds: alreadyMemberPeerIds, memberCounts: memberCounts)
            case let .communityInviteAlready(filterId, missingPeers, alreadyPeers, chats, users):
                let _ = alreadyPeers
                
                var allPeers: [Peer] = []
                var peerPresences: [PeerId: Api.User] = [:]
                var memberCounts: [PeerId: Int] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    allPeers.append(telegramUser)
                    peerPresences[telegramUser.id] = user
                }
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        allPeers.append(peer)
                    }
                    if case let .channel(_, _, _, _, _, _, _, _, _, _, _, _, participantsCount, _) = chat {
                        if let participantsCount = participantsCount {
                            memberCounts[chat.peerId] = Int(participantsCount)
                        }
                    }
                }
                
                updatePeers(transaction: transaction, peers: allPeers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                let currentFilters = _internal_currentChatListFilters(transaction: transaction)
                var currentFilterTitle: String?
                var currentFilterPeers: [EnginePeer.Id] = []
                if let index = currentFilters.firstIndex(where: { $0.id == filterId }) {
                    switch currentFilters[index] {
                    case let .filter(_, title, _, data):
                        currentFilterTitle = title
                        currentFilterPeers = data.includePeers.peers
                    default:
                        break
                    }
                }
                
                var resultPeers: [EnginePeer] = []
                var alreadyMemberPeerIds = Set<EnginePeer.Id>()
                for peer in missingPeers {
                    if let peerValue = transaction.getPeer(peer.peerId) {
                        resultPeers.append(EnginePeer(peerValue))
                        
                        if currentFilterPeers.contains(where: { $0 == peer.peerId }) && transaction.getPeerChatListIndex(peer.peerId) != nil {
                            alreadyMemberPeerIds.insert(peer.peerId)
                        }
                    }
                }
                for peerId in currentFilterPeers {
                    if resultPeers.contains(where: { $0.id == peerId }) {
                        continue
                    }
                    if let peerValue = transaction.getPeer(peerId) {
                        if canShareLinkToPeer(peer: EnginePeer(peerValue)) {
                            resultPeers.append(EnginePeer(peerValue))
                            
                            if transaction.getPeerChatListIndex(peerId) != nil {
                                alreadyMemberPeerIds.insert(peerId)
                            }
                        }
                    }
                }
                
                return ChatFolderLinkContents(localFilterId: filterId, title: currentFilterTitle, peers: resultPeers, alreadyMemberPeerIds: alreadyMemberPeerIds, memberCounts: memberCounts)
            }
        }
        |> castError(CheckChatFolderLinkError.self)
    }
}

public enum JoinChatFolderLinkError {
    case generic
    case dialogFilterLimitExceeded(limit: Int32, premiumLimit: Int32)
    case sharedFolderLimitExceeded(limit: Int32, premiumLimit: Int32)
    case tooManyChannels(limit: Int32, premiumLimit: Int32)
}

public final class JoinChatFolderResult {
    public let folderId: Int32
    public let title: String
    public let newChatCount: Int
    
    public init(folderId: Int32, title: String, newChatCount: Int) {
        self.folderId = folderId
        self.title = title
        self.newChatCount = newChatCount
    }
}

func _internal_joinChatFolderLink(account: Account, slug: String, peerIds: [EnginePeer.Id]) -> Signal<JoinChatFolderResult, JoinChatFolderLinkError> {
    return account.postbox.transaction { transaction -> ([Api.InputPeer], Int) in
        var newChatCount = 0
        for peerId in peerIds {
            if transaction.getPeerChatListIndex(peerId) != nil {
                newChatCount += 1
            }
        }
        
        return (peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer), newChatCount)
    }
    |> castError(JoinChatFolderLinkError.self)
    |> mapToSignal { inputPeers, newChatCount -> Signal<JoinChatFolderResult, JoinChatFolderLinkError> in
        return account.network.request(Api.functions.communities.joinCommunityInvite(slug: slug, peers: inputPeers))
        |> `catch` { error -> Signal<Api.Updates, JoinChatFolderLinkError> in
            if error.errorDescription == "USER_CHANNELS_TOO_MUCH" {
                return account.postbox.transaction { transaction -> (AppConfiguration, Bool) in
                    return (currentAppConfiguration(transaction: transaction), transaction.getPeer(account.peerId)?.isPremium ?? false)
                }
                |> castError(JoinChatFolderLinkError.self)
                |> mapToSignal { appConfiguration, isPremium -> Signal<Api.Updates, JoinChatFolderLinkError> in
                    let userDefaultLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: false)
                    let userPremiumLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: true)
                    
                    if isPremium {
                        return .fail(.tooManyChannels(limit: userPremiumLimits.maxFolderChatsCount, premiumLimit: userPremiumLimits.maxFolderChatsCount))
                    } else {
                        return .fail(.tooManyChannels(limit: userDefaultLimits.maxFolderChatsCount, premiumLimit: userPremiumLimits.maxFolderChatsCount))
                    }
                }
            } else if error.errorDescription == "DIALOG_FILTERS_TOO_MUCH" {
                return account.postbox.transaction { transaction -> (AppConfiguration, Bool) in
                    return (currentAppConfiguration(transaction: transaction), transaction.getPeer(account.peerId)?.isPremium ?? false)
                }
                |> castError(JoinChatFolderLinkError.self)
                |> mapToSignal { appConfiguration, isPremium -> Signal<Api.Updates, JoinChatFolderLinkError> in
                    let userDefaultLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: false)
                    let userPremiumLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: true)
                    
                    if isPremium {
                        return .fail(.dialogFilterLimitExceeded(limit: userPremiumLimits.maxFoldersCount, premiumLimit: userPremiumLimits.maxFoldersCount))
                    } else {
                        return .fail(.dialogFilterLimitExceeded(limit: userDefaultLimits.maxFoldersCount, premiumLimit: userPremiumLimits.maxFoldersCount))
                    }
                }
            } else if error.errorDescription == "COMMUNITIES_TOO_MUCH" {
                return account.postbox.transaction { transaction -> (AppConfiguration, Bool) in
                    return (currentAppConfiguration(transaction: transaction), transaction.getPeer(account.peerId)?.isPremium ?? false)
                }
                |> castError(JoinChatFolderLinkError.self)
                |> mapToSignal { appConfiguration, isPremium -> Signal<Api.Updates, JoinChatFolderLinkError> in
                    let userDefaultLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: false)
                    let userPremiumLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: true)
                    
                    if isPremium {
                        return .fail(.sharedFolderLimitExceeded(limit: userPremiumLimits.maxSharedFolderJoin, premiumLimit: userPremiumLimits.maxSharedFolderJoin))
                    } else {
                        return .fail(.sharedFolderLimitExceeded(limit: userDefaultLimits.maxSharedFolderJoin, premiumLimit: userPremiumLimits.maxSharedFolderJoin))
                    }
                }
            } else {
                return .fail(.generic)
            }
        }
        |> mapToSignal { result -> Signal<JoinChatFolderResult, JoinChatFolderLinkError> in
            account.stateManager.addUpdates(result)
            
            var folderResult: JoinChatFolderResult?
            for update in result.allUpdates {
                if case let .updateDialogFilter(_, id, data) = update {
                    if let data = data, case let .filter(_, title, _, _) = ChatListFilter(apiFilter: data) {
                        folderResult = JoinChatFolderResult(folderId: id, title: title, newChatCount: newChatCount)
                    }
                    break
                }
            }
            
            if let folderResult = folderResult {
                return _internal_updatedChatListFilters(postbox: account.postbox)
                |> castError(JoinChatFolderLinkError.self)
                |> filter { filters -> Bool in
                    if filters.contains(where: { $0.id == folderResult.folderId }) {
                        return true
                    } else {
                        return false
                    }
                }
                |> take(1)
                |> map { _ -> JoinChatFolderResult in
                    return folderResult
                }
            } else {
                return .fail(.generic)
            }
        }
    }
}

public final class ChatFolderUpdates: Equatable {
    fileprivate let folderId: Int32
    fileprivate let title: String
    fileprivate let missingPeers: [EnginePeer]
    fileprivate let memberCounts: [EnginePeer.Id: Int]
    
    public var availableChatsToJoin: Int {
        return self.missingPeers.count
    }
    
    public var chatFolderLinkContents: ChatFolderLinkContents {
        return ChatFolderLinkContents(localFilterId: self.folderId, title: self.title, peers: self.missingPeers, alreadyMemberPeerIds: Set(), memberCounts: self.memberCounts)
    }
    
    fileprivate init(
        folderId: Int32,
        title: String,
        missingPeers: [EnginePeer],
        memberCounts: [EnginePeer.Id: Int]
    ) {
        self.folderId = folderId
        self.title = title
        self.missingPeers = missingPeers
        self.memberCounts = memberCounts
    }
    
    public static func ==(lhs: ChatFolderUpdates, rhs: ChatFolderUpdates) -> Bool {
        if lhs.folderId != rhs.folderId {
            return false
        }
        if lhs.missingPeers.map(\.id) != rhs.missingPeers.map(\.id) {
            return false
        }
        return true
    }
}

private struct FirstTimeFolderUpdatesKey: Hashable {
    var accountId: AccountRecordId
    var folderId: Int32
}
private var firstTimeFolderUpdates = Set<FirstTimeFolderUpdatesKey>()

func _internal_pollChatFolderUpdatesOnce(account: Account, folderId: Int32) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> ChatListFiltersState in
        return _internal_currentChatListFiltersState(transaction: transaction)
    }
    |> mapToSignal { state -> Signal<Never, NoError> in
        let timestamp = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        let key = FirstTimeFolderUpdatesKey(accountId: account.id, folderId: folderId)
        
        if firstTimeFolderUpdates.contains(key) {
            if let current = state.updates.first(where: { $0.folderId == folderId }) {
                let updateInterval: Int32
#if DEBUG
                updateInterval = 5
#else
                updateInterval = 60 * 60
#endif
                
                if current.timestamp + updateInterval >= timestamp {
                    
                    return .complete()
                }
            }
        } else {
            firstTimeFolderUpdates.insert(key)
        }
            
        return account.network.request(Api.functions.communities.getCommunityUpdates(community: .inputCommunityDialogFilter(filterId: folderId)))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.communities.CommunityUpdates?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Never, NoError> in
            guard let result = result else {
                return account.postbox.transaction { transaction -> Void in
                    let _ = updateChatListFiltersState(transaction: transaction, { state in
                        var state = state
                        
                        state.updates.removeAll(where: { $0.folderId == folderId })
                        state.updates.append(ChatListFiltersState.ChatListFilterUpdates(folderId: folderId, timestamp: Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970), peerIds: [], memberCounts: []))
                        
                        return state
                    })
                }
                |> ignoreValues
            }
            switch result {
            case let .communityUpdates(missingPeers, chats, users):
                return account.postbox.transaction { transaction -> Void in
                    var peers: [Peer] = []
                    var peerPresences: [PeerId: Api.User] = [:]
                    var memberCounts: [ChatListFiltersState.ChatListFilterUpdates.MemberCount] = []
                    
                    for user in users {
                        let telegramUser = TelegramUser(user: user)
                        peers.append(telegramUser)
                        peerPresences[telegramUser.id] = user
                    }
                    for chat in chats {
                        if let peer = parseTelegramGroupOrChannel(chat: chat) {
                            peers.append(peer)
                        }
                        if case let .channel(_, _, _, _, _, _, _, _, _, _, _, _, participantsCount, _) = chat {
                            if let participantsCount = participantsCount {
                                memberCounts.append(ChatListFiltersState.ChatListFilterUpdates.MemberCount(id: chat.peerId, count: participantsCount))
                            }
                        }
                    }
                    
                    updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                        return updated
                    })
                    updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                    
                    let _ = updateChatListFiltersState(transaction: transaction, { state in
                        var state = state
                        
                        state.updates.removeAll(where: { $0.folderId == folderId })
                        state.updates.append(ChatListFiltersState.ChatListFilterUpdates(folderId: folderId, timestamp: Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970), peerIds: missingPeers.map(\.peerId), memberCounts: memberCounts))
                        
                        return state
                    })
                }
                |> ignoreValues
            }
        }
    }
}

func _internal_subscribedChatFolderUpdates(account: Account, folderId: Int32) -> Signal<ChatFolderUpdates?, NoError> {
    struct InternalData: Equatable {
        var title: String
        var peerIds: [EnginePeer.Id]
        var memberCounts: [EnginePeer.Id: Int]
    }
    
    return _internal_updatedChatListFiltersState(postbox: account.postbox)
    |> map { state -> InternalData? in
        guard let update = state.updates.first(where: { $0.folderId == folderId }) else {
            return nil
        }
        guard let folder = state.filters.first(where: { $0.id == folderId }) else {
            return nil
        }
        guard case let .filter(_, title, _, data) = folder, data.isShared else {
            return nil
        }
        let filteredPeerIds: [PeerId] = update.peerIds.filter { !data.includePeers.peers.contains($0) }
        var memberCounts: [PeerId: Int] = [:]
        for item in update.memberCounts {
            memberCounts[item.id] = Int(item.count)
        }
        return InternalData(title: title, peerIds: filteredPeerIds, memberCounts: memberCounts)
    }
    |> distinctUntilChanged
    |> mapToSignal { internalData -> Signal<ChatFolderUpdates?, NoError> in
        guard let internalData = internalData else {
            return .single(nil)
        }
        if internalData.peerIds.isEmpty {
            return .single(nil)
        }
        return account.postbox.transaction { transaction -> ChatFolderUpdates? in
            var peers: [EnginePeer] = []
            for peerId in internalData.peerIds {
                if let peer = transaction.getPeer(peerId) {
                    peers.append(EnginePeer(peer))
                }
            }
            return ChatFolderUpdates(folderId: folderId, title: internalData.title, missingPeers: peers, memberCounts: internalData.memberCounts)
        }
    }
}

func _internal_joinAvailableChatsInFolder(account: Account, updates: ChatFolderUpdates, peerIds: [EnginePeer.Id]) -> Signal<Never, JoinChatFolderLinkError> {
    return account.postbox.transaction { transaction -> [Api.InputPeer] in
        return peerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
    }
    |> castError(JoinChatFolderLinkError.self)
    |> mapToSignal { inputPeers -> Signal<Never, JoinChatFolderLinkError> in
        return account.network.request(Api.functions.communities.joinCommunityUpdates(community: .inputCommunityDialogFilter(filterId: updates.folderId), peers: inputPeers))
        |> `catch` { error -> Signal<Api.Updates, JoinChatFolderLinkError> in
            if error.errorDescription == "DIALOG_FILTERS_TOO_MUCH" {
                return account.postbox.transaction { transaction -> (AppConfiguration, Bool) in
                    return (currentAppConfiguration(transaction: transaction), transaction.getPeer(account.peerId)?.isPremium ?? false)
                }
                |> castError(JoinChatFolderLinkError.self)
                |> mapToSignal { appConfiguration, isPremium -> Signal<Api.Updates, JoinChatFolderLinkError> in
                    let userDefaultLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: false)
                    let userPremiumLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: true)
                    
                    if isPremium {
                        return .fail(.dialogFilterLimitExceeded(limit: userPremiumLimits.maxFoldersCount, premiumLimit: userPremiumLimits.maxFoldersCount))
                    } else {
                        return .fail(.dialogFilterLimitExceeded(limit: userDefaultLimits.maxFoldersCount, premiumLimit: userPremiumLimits.maxFoldersCount))
                    }
                }
            } else if error.errorDescription == "FILTERS_TOO_MUCH" {
                return account.postbox.transaction { transaction -> (AppConfiguration, Bool) in
                    return (currentAppConfiguration(transaction: transaction), transaction.getPeer(account.peerId)?.isPremium ?? false)
                }
                |> castError(JoinChatFolderLinkError.self)
                |> mapToSignal { appConfiguration, isPremium -> Signal<Api.Updates, JoinChatFolderLinkError> in
                    let userDefaultLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: false)
                    let userPremiumLimits = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: true)
                    
                    if isPremium {
                        return .fail(.sharedFolderLimitExceeded(limit: userPremiumLimits.maxSharedFolderJoin, premiumLimit: userPremiumLimits.maxSharedFolderJoin))
                    } else {
                        return .fail(.sharedFolderLimitExceeded(limit: userDefaultLimits.maxSharedFolderJoin, premiumLimit: userPremiumLimits.maxSharedFolderJoin))
                    }
                }
            } else {
                return .fail(.generic)
            }
        }
        |> mapToSignal { result -> Signal<Never, JoinChatFolderLinkError> in
            account.stateManager.addUpdates(result)
            
            return .complete()
        }
    }
}

func _internal_hideChatFolderUpdates(account: Account, folderId: Int32) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> Void in
        let _ = updateChatListFiltersState(transaction: transaction, { state in
            var state = state
            
            state.updates.removeAll(where: { $0.folderId == folderId })
            
            return state
        })
    }
    |> mapToSignal { _ -> Signal<Never, NoError> in
        return account.network.request(Api.functions.communities.hideCommunityUpdates(community: .inputCommunityDialogFilter(filterId: folderId)))
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> ignoreValues
    }
}

func _internal_leaveChatFolder(account: Account, folderId: Int32, removePeerIds: [EnginePeer.Id]) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> [Api.InputPeer] in
        return removePeerIds.compactMap(transaction.getPeer).compactMap(apiInputPeer)
    }
    |> mapToSignal { inputPeers -> Signal<Never, NoError> in
        return account.network.request(Api.functions.communities.leaveCommunity(community: .inputCommunityDialogFilter(filterId: folderId), peers: inputPeers))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.Updates?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { updates -> Signal<Never, NoError> in
            if let updates = updates {
                account.stateManager.addUpdates(updates)
            }
            return account.postbox.transaction { transaction -> Void in
            }
            |> ignoreValues
        }
    }
}

func _internal_requestLeaveChatFolderSuggestions(account: Account, folderId: Int32) -> Signal<[EnginePeer.Id], NoError> {
    return account.network.request(Api.functions.communities.getLeaveCommunitySuggestions(community: .inputCommunityDialogFilter(filterId: folderId)))
    |> map { result -> [EnginePeer.Id] in
        return result.map(\.peerId)
    }
    |> `catch` { _ -> Signal<[EnginePeer.Id], NoError> in
        return .single([])
    }
}