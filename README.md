# TapGuard

TapGuard provides a Swift 6 ready, thread-safe abstraction layer for asynchronous processing of [CGEvents](https://developer.apple.com/documentation/coregraphics/cgevent) 
with support for macOS Catalina (`.macOS(.v10_15)`) and above. 

It offers tools for managing multiple event streams and receivers in a concurrent environment.

## Features

- **Asynchronous Event Processing:** Utilize Swift Concurrency for modern, non-blocking event handling.
- **Thread-Safe:** Built with thread safety in mind.
- **Event Suspension:** Temporarily suspend event processing for scenarios like UI interactions or recording shortcuts.
- **System Prerequisites:** Automatically handles system-level conditions (e.g., Accessibility API requirements) for enabling or disabling event sources.

## Installation

Add the package to your `Package.swift` package dependencies:

```swift
    dependencies: [
        .package(url: "https://github.com/Akazm/osx-tap-guard", from: "1.0.0")
    ]
```
Then, add `TapGuard` to your target's dependencies:

```swift
    dependencies: [
        .product(name: "TapGuard", package: "tap-guard")
    ]
```

## Usage

### Initialize [`HIDEventDispatcher`](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventdispatcher)

TapGuard provides a convenient way to initialize a `HIDEventDispatcher` with a backing 
[CGEventTap](https://developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate).

```swift
import TapGuard

let dispatcher = HIDEventDispatcher.systemDispatcher(
    enabled: true,
    eventsOfInterest: CGEventMask(1 << kCGEventKeyDown | 1 << kCGEventKeyUp),
    eventTapLocation: .cgSessionEventTap
)
```

### Satisfying prerequesites

For event processing to function as one might expect already by now, several conditions must be met.

- **Screens & Device must be awake**
- **At least one receiver must be present**
- **HIDEventDispatcher is not suspended**
- **HIDEventDispatcher is enabled**
- **Accessibility API access must have been granted:** Access to the macOS Accessibility API must be granted by the 
application's user. Prompting the user to grant access is out of scope for this package, but a `HIDEventDispatcher` 
attributes for the Accessibility API access status. 

_Unless_ or _when_ all of the above conditions have been met, a `HIDEventDispatcher` will automatically _remove_ or 
_install_ the backing CGEventTap. 

For more information, see
[HIDEventDispatcherEnabledPrerequisite
](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventdispatcherenabledprerequisite).

### Processing events

`HIDEventDispatcher` allows you to register multiple 
[event receivers](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventreceiver). This is also refered 
to as 'event processing pipeline.

#### Using an `AsyncStream`:

```swift
let stream = dispatcher.stream()

Task {
    for await event in stream {
        print("Received event: \(event)")
    }
}
```

For more information, see 
[stream(withPriority:)](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventdispatcher/stream(withpriority:))

#### Conformance to `HIDEventReceiver & AnyObject`

```swift
class MyReceiver: HIDEventReceiver {

    var hidEventProcessor: HIDEventProcessor {
        .sync { event in 
            print("Event: \(event)")
            return PostProcessHIDEventInstruction.pass
        }
    }
    
    // Optional (default: UInt64(UInt32.max))
    var hidEventReceiverPriority: UInt64 {
        UInt64(UInt32.max)
    }
    
    // Optional (default: true)
    var hidEventReceiverEnabled: Bool {
        true
    }
}
```
For more information, see [HIDEventReceiver](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventreceiver).

Event processing happens within the closure specified for the defined 
[HIDEventReceiver](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventreceiver). In the example, 
the closure returns a [PostProcessHIDEventInstruction](https://akazm.github.io/osx-tap-guard/documentation/tapguard/postprocesshideventinstruction) 
to specify how to postprocess the event after the closure exited.

To enable async event processing, use an `async` processor instead.

```swift
class MyAsyncReceiver: HIDEventReceiver {

    var hidEventProcessor: HIDEventProcessor {
        .async { event in 
            print("Event received: \(event)")
            //await something here
            return PostProcessHIDEventInstruction.pass
        }
    }
    
    // Optional (default: UInt64(UInt32.max))
    var hidEventReceiverPriority: UInt64 {
        UInt64(UInt32.max)
    }
    
    // Optional (default: true)
    var hidEventReceiverEnabled: Bool {
        true
    }
}
```
For more information, see [HIDEventProcessor](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventprocessor).

#### Using closures

Add a receiver with a synchronous callback:

```swift
let receiver = dispatcher.addReceiver { event in
    print("Event received: \(event)")
    return .pass
}
```

Add a receiver with an asynchronous callback:

```swift
let receiver = dispatcher.addReceiver { event in
    print("Event received: \(event)")
    //await something here
    return .pass
}
```
For more information, see [`HIDEventDispatcher`](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventdispatcher).

#### Removing receivers

Any receiver can be removed by calling the `remove()` method:

```swift
let receiver = MyReceiver()
let registration = dispatcher.addReceiver(myReceiver)

// Remove the receiver

registration.remove()
```

For more information, see [`DisposableHIDEventReceiver`](https://akazm.github.io/osx-tap-guard/documentation/tapguard/disposablehideventreceiver).

### Enable or disable dispatcher

Manually enable or disable the dispatcher:

```swift
dispatcher.setEnabled(true) // Enable
```

### Suspend dispatcher

Aside from enabling or disabling a dispatcher, it can also be *suspended*. Like a disabled dispatcher, a *suspended* 
dispatcher will not process events - this is semantically idential. However, analogous to adding and removing receivers,
suspensions can be *acquired* and *released* indepentendly from each other.

```swift
let suspension = dispatcher.acquireSuspension()

// Release the suspension when done
suspension.release()
```

For more information, see 
[`acquireSuspension()`](https://akazm.github.io/osx-tap-guard/documentation/tapguard/hideventdispatcher/acquiresuspension()).

### Notes on async event processing

Async event processing is supported in order to achieve *formal* thread safety first and foremost, but *not* 
to await time-intensive tasks that rely on networking, File I/O or CPU-intensive tasks. 

Doing so nonetheless might result in the following: 

1. **MacOS disables a dispatcher's backing event tap ([kCGEventTapDisabledByTimeout](https://developer.apple.com/documentation/coregraphics/cgeventtype/kcgeventtapdisabledbytimeout?language=swift)).** 
It will be re-enabled automatically.
2. **MacOS ignores the `PostProcessHIDEventInstruction`**, effectively replacing it with [.bypass](https://akazm.github.io/osx-tap-guard/documentation/tapguard/postprocesshideventinstruction/bypass) behaviour. 

## Documentation

See [here](https://akazm.github.io/osx-tap-guard/documentation/tapguard).

## Contributing

Contributions are welcome! Please submit issues or pull requests on the official repository.

