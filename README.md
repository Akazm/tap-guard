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

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "<repository_url>", from: "1.0.0")
]
```

## Usage

### Create a `HIDEventDispatcher`

<PACKAGE NAME> provides a convenient way to initialize a `HIDEventDispatcher` with a backing 
[CGEventTap](https://developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate).

```swift
import HIDEventDispatcher

let dispatcher = HIDEventDispatcher.systemDispatcher(
    enabled: true,
    eventsOfInterest: CGEventMask(1 << kCGEventKeyDown | 1 << kCGEventKeyUp),
    eventTapLocation: .cgSessionEventTap
)
```

### Satisfying prequesites

For event processing to function as one might expect already by now, several conditions must be met.

- **Screens & Device must be awake**
- **At least one enabled receiver must be present**
- **HIDEventDispatcher is not suspended**
- **HIDEventDispatcher is enabled**
- **Accessibility API access must have been granted:** Access to the macOS Accessibility API must be granted by the 
application's user. Prompting the user to grant access is out of scope for this package, but a `HIDEventDispatcher` 
attributes for Accessibility API. 

Unless or when all of the above conditions have been met, a `HIDEventDispatcher` will automatically remove or add the 
installed CGEventTap. 

### Processing events

`HIDEventDispatcher` allows you to register multiple *event receivers*.

#### Using an `AsyncStream`:

```swift
let stream = dispatcher.stream()

Task {
    for await event in stream {
        print("Received event: \(event)")
    }
}
```

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

Event processing happens within the closure specified for the defined `HIDEventProcessor`. In the example, the closure
returns a `PostProcessHIDEventInstruction` to specify how to postprocess the event after the closure exited.

Async event processing is an opt-in and enabled by using a `async` processor instead.

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

#### Removing receivers

Any receiver can be removed by calling the `remove()` method:

```swift
let receiver = MyReceiver()
let registration = dispatcher.addReceiver(myReceiver)

// Remove the receiver

registration.remove()
```

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

### Notes on async event processing

Async event processing is supported in order to achieve *formal* thread safety first and foremost, but *not* 
to await time-intensive tasks that rely on networking, File I/O or CPU-intensive tasks. 

Doing so nonetheless might result in the following: 

1. **MacOS disables a dispatcher's backing event tap ((kCGEventTapDisabledByTimeout)[https://developer.apple.com/documentation/coregraphics/cgeventtype/kcgeventtapdisabledbytimeout?language=swift]).** 
It will be re-enabled automatically.
2. **MacOS ignores the `PostProcessHIDEventInstruction`**, effectively replacing it with `.bypass` behaviour. 

## Documentation

// TODO

## Contributing

Contributions are welcome! Please submit issues or pull requests on the official repository.

