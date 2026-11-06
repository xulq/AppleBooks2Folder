// AppleBooks2Folder addition. The iterator can stop early on invalid or encrypted entries.
extension Archive {
    public var declaredEntryCount: UInt64 { totalNumberOfEntriesInCentralDirectory }
}
