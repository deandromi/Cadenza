public extension Array where Element == NoteEvent {
    /// Sorts by onset and assigns shared-onset groups. Chain rule applies:
    /// notes within the tolerance of the previous note join its group.
    func assignOnsetGroups() -> [NoteEvent] {
        CadenzaCore.assignOnsetGroups(self)
    }
}
