class UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) {
        self.value = value
    }
}
