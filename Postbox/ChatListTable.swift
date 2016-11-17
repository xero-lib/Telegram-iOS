import Foundation

enum ChatListOperation {
    case InsertMessage(MessageIndex, IntermediateMessage, CombinedPeerReadState?, PeerChatListEmbeddedInterfaceState?)
    case InsertHole(ChatListHole)
    case InsertNothing(MessageIndex)
    case RemoveMessage([MessageIndex])
    case RemoveHoles([MessageIndex])
}

enum ChatListIntermediateEntry {
    case Message(MessageIndex, IntermediateMessage, PeerChatListEmbeddedInterfaceState?)
    case Hole(ChatListHole)
    case Nothing(MessageIndex)
    
    var index: MessageIndex {
        switch self {
            case let .Message(index, _, _):
                return index
            case let .Hole(hole):
                return hole.index
            case let .Nothing(index):
                return index
        }
    }
}

private enum ChatListEntryType: Int8 {
    case Message = 1
    case Hole = 2
}

final class ChatListTable: Table {
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .binary)
    }
    
    let indexTable: ChatListIndexTable
    let emptyMemoryBuffer = MemoryBuffer()
    let metadataTable: MessageHistoryMetadataTable
    let seedConfiguration: SeedConfiguration
    
    init(valueBox: ValueBox, table: ValueBoxTable, indexTable: ChatListIndexTable, metadataTable: MessageHistoryMetadataTable, seedConfiguration: SeedConfiguration) {
        self.indexTable = indexTable
        self.metadataTable = metadataTable
        self.seedConfiguration = seedConfiguration
        
        super.init(valueBox: valueBox, table: table)
    }
    
    private func key(_ index: MessageIndex, type: ChatListEntryType) -> ValueBoxKey {
        let key = ValueBoxKey(length: 4 + 4 + 4 + 8 + 1)
        key.setInt32(0, value: index.timestamp)
        key.setInt32(4, value: index.id.namespace)
        key.setInt32(4 + 4, value: index.id.id)
        key.setInt64(4 + 4 + 4, value: index.id.peerId.toInt64())
        key.setInt8(4 + 4 + 4 + 8, value: type.rawValue)
        return key
    }
    
    private func lowerBound() -> ValueBoxKey {
        let key = ValueBoxKey(length: 4)
        key.setInt32(0, value: 0)
        return key
    }
    
    private func upperBound() -> ValueBoxKey {
        let key = ValueBoxKey(length: 4)
        key.setInt32(0, value: Int32.max)
        return key
    }
    
    private func ensureInitialized() {
        if !self.metadataTable.isInitializedChatList() {
            for hole in self.seedConfiguration.initializeChatListWithHoles {
                self.justInsertHole(hole)
            }
            self.metadataTable.setInitializedChatList()
        }
    }
    
    func replay(historyOperationsByPeerId: [PeerId : [MessageHistoryOperation]], updatedPeerChatListEmbeddedStates: [PeerId: PeerChatListEmbeddedInterfaceState?], messageHistoryTable: MessageHistoryTable, peerChatInterfaceStateTable: PeerChatInterfaceStateTable, operations: inout [ChatListOperation]) {
        self.ensureInitialized()
        var changedPeerIds = Set<PeerId>()
        for peerId in historyOperationsByPeerId.keys {
            changedPeerIds.insert(peerId)
        }
        for peerId in updatedPeerChatListEmbeddedStates.keys {
            changedPeerIds.insert(peerId)
        }
        for peerId in changedPeerIds {
            let currentIndex: MessageIndex? = self.indexTable.get(peerId)
            
            let updatedIndex: MessageIndex?
            let topMessage = messageHistoryTable.topMessage(peerId)
            let embeddedChatState = peerChatInterfaceStateTable.get(peerId)?.chatListEmbeddedState
            
            if let topMessage = topMessage {
                var updatedTimestamp = topMessage.timestamp
                if let embeddedChatState = embeddedChatState {
                    updatedTimestamp = max(updatedTimestamp, embeddedChatState.timestamp)
                }
                var updatedIndex = MessageIndex(id: topMessage.id, timestamp: updatedTimestamp)
                
                if let currentIndex = currentIndex, currentIndex != updatedIndex {
                    self.justRemoveMessage(currentIndex)
                }
                if let currentIndex = currentIndex {
                    operations.append(.RemoveMessage([currentIndex]))
                }
                self.indexTable.set(updatedIndex)
                self.justInsertMessage(updatedIndex)
                operations.append(.InsertMessage(updatedIndex, topMessage, messageHistoryTable.readStateTable.getCombinedState(peerId), embeddedChatState))
            } else {
                if let currentIndex = currentIndex {
                    operations.append(.RemoveMessage([currentIndex]))
                    operations.append(.InsertNothing(currentIndex))
                }
            }
        }
    }
    
    func addHole(_ hole: ChatListHole, operations: inout [ChatListOperation]) {
        self.ensureInitialized()
        
        if self.valueBox.get(self.table, key: self.key(hole.index, type: .Hole)) == nil {
            self.justInsertHole(hole)
            operations.append(.InsertHole(hole))
        }
    }
    
    func replaceHole(_ index: MessageIndex, hole: ChatListHole?, operations: inout [ChatListOperation]) {
        self.ensureInitialized()
        
        if self.valueBox.get(self.table, key: self.key(index, type: .Hole)) != nil {
            if let hole = hole {
                if hole.index != index {
                    self.justRemoveHole(index)
                    self.justInsertHole(hole)
                    operations.append(.RemoveHoles([index]))
                    operations.append(.InsertHole(hole))
                }
            } else{
                self.justRemoveHole(index)
                operations.append(.RemoveHoles([index]))
            }
        }
    }
    
    private func justInsertMessage(_ index: MessageIndex) {
        self.valueBox.set(self.table, key: self.key(index, type: .Message), value: self.emptyMemoryBuffer)
    }
    
    private func justRemoveMessage(_ index: MessageIndex) {
        self.valueBox.remove(self.table, key: self.key(index, type: .Message))
    }
    
    private func justInsertHole(_ hole: ChatListHole) {
        self.valueBox.set(self.table, key: self.key(hole.index, type: .Hole), value: self.emptyMemoryBuffer)
    }
    
    private func justRemoveHole(_ index: MessageIndex) {
        self.valueBox.remove(self.table, key: self.key(index, type: .Hole))
    }
    
    func entriesAround(_ index: MessageIndex, messageHistoryTable: MessageHistoryTable, peerChatInterfaceStateTable: PeerChatInterfaceStateTable, count: Int) -> (entries: [ChatListIntermediateEntry], lower: ChatListIntermediateEntry?, upper: ChatListIntermediateEntry?) {
        self.ensureInitialized()
        
        var lowerEntries: [ChatListIntermediateEntry] = []
        var upperEntries: [ChatListIntermediateEntry] = []
        var lower: ChatListIntermediateEntry?
        var upper: ChatListIntermediateEntry?
        
        self.valueBox.range(self.table, start: self.key(index, type: .Message), end: self.lowerBound(), keys: { key in
            let index = MessageIndex(id: MessageId(peerId: PeerId(key.getInt64(4 + 4 + 4)), namespace: key.getInt32(4), id: key.getInt32(4 + 4)), timestamp: key.getInt32(0))
            let type: Int8 = key.getInt8(4 + 4 + 4 + 8)
            if type == ChatListEntryType.Message.rawValue {
                if let message = messageHistoryTable.getMessage(index) {
                    lowerEntries.append(.Message(index, message, peerChatInterfaceStateTable.get(index.id.peerId)?.chatListEmbeddedState))
                } else {
                    lowerEntries.append(.Nothing(index))
                }
            } else {
                lowerEntries.append(.Hole(ChatListHole(index: index)))
            }
            return true
        }, limit: count / 2 + 1)
        if lowerEntries.count >= count / 2 + 1 {
            lower = lowerEntries.last
            lowerEntries.removeLast()
        }
        
        self.valueBox.range(self.table, start: self.key(index, type: .Message).predecessor, end: self.upperBound(), keys: { key in
            let index = MessageIndex(id: MessageId(peerId: PeerId(key.getInt64(4 + 4 + 4)), namespace: key.getInt32(4), id: key.getInt32(4 + 4)), timestamp: key.getInt32(0))
            let type: Int8 = key.getInt8(4 + 4 + 4 + 8)
            if type == ChatListEntryType.Message.rawValue {
                if let message = messageHistoryTable.getMessage(index) {
                    upperEntries.append(.Message(index, message, peerChatInterfaceStateTable.get(index.id.peerId)?.chatListEmbeddedState))
                } else {
                    upperEntries.append(.Nothing(index))
                }
            } else {
                upperEntries.append(.Hole(ChatListHole(index: index)))
            }
            return true
        }, limit: count - lowerEntries.count + 1)
        if upperEntries.count >= count - lowerEntries.count + 1 {
            upper = upperEntries.last
            upperEntries.removeLast()
        }
        
        if lowerEntries.count != 0 && lowerEntries.count + upperEntries.count < count {
            var additionalLowerEntries: [ChatListIntermediateEntry] = []
            let startEntryType: ChatListEntryType
            switch lowerEntries.last! {
                case .Message, .Nothing:
                    startEntryType = .Message
                case .Hole:
                    startEntryType = .Hole
            }
            self.valueBox.range(self.table, start: self.key(lowerEntries.last!.index, type: startEntryType), end: self.lowerBound(), keys: { key in
                let index = MessageIndex(id: MessageId(peerId: PeerId(key.getInt64(4 + 4 + 4)), namespace: key.getInt32(4), id: key.getInt32(4 + 4)), timestamp: key.getInt32(0))
                let type: Int8 = key.getInt8(4 + 4 + 4 + 8)
                if type == ChatListEntryType.Message.rawValue {
                    if let message = messageHistoryTable.getMessage(index) {
                        additionalLowerEntries.append(.Message(index, message, peerChatInterfaceStateTable.get(index.id.peerId)?.chatListEmbeddedState))
                    } else {
                        additionalLowerEntries.append(.Nothing(index))
                    }
                } else {
                    additionalLowerEntries.append(.Hole(ChatListHole(index: index)))
                }
                return true
            }, limit: count - lowerEntries.count - upperEntries.count + 1)
            if additionalLowerEntries.count >= count - lowerEntries.count + upperEntries.count + 1 {
                lower = additionalLowerEntries.last
                additionalLowerEntries.removeLast()
            }
            lowerEntries.append(contentsOf: additionalLowerEntries)
        }
        
        var entries: [ChatListIntermediateEntry] = []
        entries.append(contentsOf: lowerEntries.reversed())
        entries.append(contentsOf: upperEntries)
        return (entries: entries, lower: lower, upper: upper)
    }
    
    func earlierEntries(_ index: MessageIndex?, messageHistoryTable: MessageHistoryTable, peerChatInterfaceStateTable: PeerChatInterfaceStateTable, count: Int) -> [ChatListIntermediateEntry] {
        self.ensureInitialized()
        
        var entries: [ChatListIntermediateEntry] = []
        let key: ValueBoxKey
        if let index = index {
            key = self.key(index, type: .Message)
        } else {
            key = self.upperBound()
        }
        
        self.valueBox.range(self.table, start: key, end: self.lowerBound(), keys: { key in
            let index = MessageIndex(id: MessageId(peerId: PeerId(key.getInt64(4 + 4 + 4)), namespace: key.getInt32(4), id: key.getInt32(4 + 4)), timestamp: key.getInt32(0))
            let type: Int8 = key.getInt8(4 + 4 + 4 + 8)
            if type == ChatListEntryType.Message.rawValue {
                if let message = messageHistoryTable.getMessage(index) {
                    entries.append(.Message(index, message, peerChatInterfaceStateTable.get(index.id.peerId)?.chatListEmbeddedState))
                } else {
                    entries.append(.Nothing(index))
                }
            } else {
                entries.append(.Hole(ChatListHole(index: index)))
            }
            return true
        }, limit: count)
        return entries
    }
    
    func laterEntries(_ index: MessageIndex?, messageHistoryTable: MessageHistoryTable, peerChatInterfaceStateTable: PeerChatInterfaceStateTable, count: Int) -> [ChatListIntermediateEntry] {
        self.ensureInitialized()
        
        var entries: [ChatListIntermediateEntry] = []
        let key: ValueBoxKey
        if let index = index {
            key = self.key(index, type: .Message)
        } else {
            key = self.lowerBound()
        }
        
        self.valueBox.range(self.table, start: key, end: self.upperBound(), keys: { key in
            let index = MessageIndex(id: MessageId(peerId: PeerId(key.getInt64(4 + 4 + 4)), namespace: key.getInt32(4), id: key.getInt32(4 + 4)), timestamp: key.getInt32(0))
            let type: Int8 = key.getInt8(4 + 4 + 4 + 8)
            if type == ChatListEntryType.Message.rawValue {
                if let message = messageHistoryTable.getMessage(index) {
                    entries.append(.Message(index, message, peerChatInterfaceStateTable.get(index.id.peerId)?.chatListEmbeddedState))
                } else {
                    entries.append(.Nothing(index))
                }
            } else {
                entries.append(.Hole(ChatListHole(index: index)))
            }
            return true
        }, limit: count)
        return entries
    }
    
    func debugList(_ messageHistoryTable: MessageHistoryTable, peerChatInterfaceStateTable: PeerChatInterfaceStateTable) -> [ChatListIntermediateEntry] {
        return self.laterEntries(MessageIndex.absoluteLowerBound(), messageHistoryTable: messageHistoryTable, peerChatInterfaceStateTable: peerChatInterfaceStateTable, count: 1000)
    }
}
