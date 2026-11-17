# EventKit — reading the user's calendars

EventKit is the framework for the user's calendar database:
`EKEventStore` (the store + permission gateway) and `EKEvent`
(one calendar entry). The Calendar screen here is read-only, which is
the simple case.

## Permission first

```swift
let store = EKEventStore()
let status = await store.requestAccess(to: .event)   // prompts once
// or check store.authorizationStatus first to avoid a needless prompt
```

Access is `.granted` / `.denied` / `.fullAccess` / `.writeOnly`
(modern iOS splits it). Denied is a normal, renderable state (the
screen shows the empty calendar), never a crash. Like PhotoKit, the
user can revoke in Settings anytime, so the screen re-requests per
appearance rather than caching one verdict forever.

## Fetching events

```swift
let pred = store.predicateForEvents(withStart: monthStart, end: monthEnd, calendars: nil)
let events = store.events(matching: pred)   // synchronous, returns [EKEvent]
```

`events(matching:)` is a **synchronous disk/local query** — fine for a
month window on a background hop, kept off the main thread during
scroll. Events carry `title`, `startDate`/`endDate`, `isAllDay`, and
their calendar's color — everything the day-detail list renders.

## Why not CloudKit/MusicKit-style async?

EventKit's API is older: the Swift-async `requestAccess` is modern, but
queries remain synchronous method calls. The screen hops to a
background task for the query and back to the main actor to publish —
the standard bridge between sync frameworks and SwiftUI
([swift-async-await.md](swift-async-await.md)).

## Where to look

- `Sources/Features/Calendar/CalendarScreen.swift` — month grid, locale
  first-weekday alignment, per-day event dots/list.

## Related

[photokit.md](photokit.md) — same permission model, different store.
