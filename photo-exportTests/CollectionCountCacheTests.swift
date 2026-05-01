import Foundation
import Testing

@testable import Photo_Export

/// Phase 3.4 of the collections-export plan adds `CollectionCountCache`. The cache
/// dedups concurrent fetches for the same key, returns cached values until invalidated,
/// and cancels in-flight tasks on `invalidateAll()`. Phase 4's sidebar uses
/// `cachedCountAssets(in:)` from `PhotoLibraryService`; Phase 3 lands the actor and
/// wires the invalidation into `PHPhotoLibraryChangeObserver`.
struct CollectionCountCacheTests {

  // MARK: - Caching

  @Test func firstCallRunsFetch() async throws {
    let cache = CollectionCountCache()
    var calls = 0
    let n = try await cache.count(for: "k") {
      calls += 1
      return 42
    }
    #expect(n == 42)
    #expect(calls == 1)
  }

  @Test func secondCallReturnsCachedValue() async throws {
    let cache = CollectionCountCache()
    let counter = Counter()
    let n1 = try await cache.count(for: "k") {
      await counter.increment()
      return 7
    }
    let n2 = try await cache.count(for: "k") {
      await counter.increment()
      return 999  // shouldn't run
    }
    #expect(n1 == 7)
    #expect(n2 == 7)
    #expect(await counter.value == 1)
  }

  @Test func differentKeysAreCachedSeparately() async throws {
    let cache = CollectionCountCache()
    let a = try await cache.count(for: "a") { 1 }
    let b = try await cache.count(for: "b") { 2 }
    #expect(a == 1)
    #expect(b == 2)
  }

  // MARK: - Invalidation

  @Test func invalidateAllClearsValues() async throws {
    let cache = CollectionCountCache()
    let counter = Counter()
    _ = try await cache.count(for: "k") {
      await counter.increment()
      return 5
    }
    await cache.invalidateAll()
    let n = try await cache.count(for: "k") {
      await counter.increment()
      return 8
    }
    #expect(n == 8)
    #expect(await counter.value == 2)
  }

  // MARK: - Cancellation

  /// `invalidateAll()` cancels every in-flight task. The fetch closure observes
  /// `Task.isCancelled` (or hits a cancellation point) and aborts so resources aren't
  /// stranded after a `PHPhotoLibraryChangeObserver` callback.
  @Test func invalidateAllCancelsInFlightTask() async throws {
    let cache = CollectionCountCache()
    let observed = AtomicFlag()

    // Start a fetch that suspends and observes cancellation.
    async let result: Int = cache.count(for: "slow") {
      do {
        // Suspend long enough for invalidateAll to cancel us.
        try await Task.sleep(nanoseconds: 5_000_000_000)
      } catch {
        await observed.set(true)
        throw error
      }
      return 42
    }

    // Give the task a moment to enter its sleep, then invalidate.
    try await Task.sleep(nanoseconds: 50_000_000)
    await cache.invalidateAll()

    // The awaited task should now throw CancellationError.
    do {
      _ = try await result
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
      // Good
    } catch {
      // The closure rethrows whatever Task.sleep threw, which on cancellation is
      // CancellationError. Accept that exact path.
      #expect(error is CancellationError, "Expected CancellationError, got \(error)")
    }
    #expect(await observed.value)
  }

  // MARK: - Error propagation

  @Test func errorIsPropagatedAndNotCached() async throws {
    let cache = CollectionCountCache()
    let counter = Counter()
    do {
      _ = try await cache.count(for: "fail") {
        await counter.increment()
        throw NSError(domain: "test", code: 1)
      }
      Issue.record("Expected throw")
    } catch {
      // Good
    }
    // Subsequent call retries (didn't cache the failure).
    do {
      let n = try await cache.count(for: "fail") {
        await counter.increment()
        return 12
      }
      #expect(n == 12)
    } catch {
      Issue.record("Second call should have succeeded: \(error)")
    }
    #expect(await counter.value == 2)
  }
}

/// Tiny actor counter so concurrent tests can count fetches without data races.
private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// Tiny actor flag for the cancellation test (the closure observes cancellation in a
/// detached context).
private actor AtomicFlag {
  private(set) var value = false
  func set(_ newValue: Bool) { value = newValue }
}
