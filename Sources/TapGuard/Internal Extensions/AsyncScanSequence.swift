//  Created by Thibault Wittemberg on 31/12/2021.
//  Original: https://github.com/sideeffect-io/AsyncExtensions

extension AsyncSequence {
  func scan<Output>(
    _ initialResult: Output,
    _ nextPartialResult: @Sendable @escaping (Output, Element) async -> Output
  ) -> AsyncScanSequence<Self, Output> {
    AsyncScanSequence(self, initialResult: initialResult, nextPartialResult: nextPartialResult)
  }
}

struct AsyncScanSequence<Base: AsyncSequence, Output>: AsyncSequence {
  typealias Element = Output
  typealias AsyncIterator = Iterator

  var base: Base
  var initialResult: Output
  let nextPartialResult: @Sendable (Output, Base.Element) async -> Output

  init(
    _ base: Base,
    initialResult: Output,
    nextPartialResult: @Sendable @escaping (Output, Base.Element) async -> Output
  ) {
    self.base = base
    self.initialResult = initialResult
    self.nextPartialResult = nextPartialResult
  }

  func makeAsyncIterator() -> AsyncIterator {
    Iterator(
      base: self.base.makeAsyncIterator(),
      initialResult: self.initialResult,
      nextPartialResult: self.nextPartialResult
    )
  }

  struct Iterator: AsyncIteratorProtocol {
    var base: Base.AsyncIterator
    var currentValue: Output
    let nextPartialResult: @Sendable (Output, Base.Element) async -> Output

    init(
      base: Base.AsyncIterator,
      initialResult: Output,
      nextPartialResult: @Sendable @escaping (Output, Base.Element) async -> Output
    ) {
      self.base = base
      self.currentValue = initialResult
      self.nextPartialResult = nextPartialResult
    }

    mutating func next() async rethrows -> Output? {
      let nextUpstreamValue = try await self.base.next()
      guard let nonNilNextUpstreamValue = nextUpstreamValue else { return nil }
      self.currentValue = await self.nextPartialResult(self.currentValue, nonNilNextUpstreamValue)
      return self.currentValue
    }
  }
}

extension AsyncScanSequence: Sendable where Base: Sendable, Output: Sendable {}
extension AsyncScanSequence.Iterator: Sendable where Base.AsyncIterator: Sendable, Output: Sendable {}
