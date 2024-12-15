class UncheckedWeakSendable<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value?) {
        self.value = value
    }
}
