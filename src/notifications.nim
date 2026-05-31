## Notification state machine.
## Tracks unread notifications per pane and provides jump-to functionality.

import std/tables

type
  Notification* = ref object
    paneId*: int
    id*: int
    body*: string
    timestamp*: int64

  NotifState* = object
    notifications*: seq[Notification]
    unreadByPane*: Table[int, int]  ## count of unread per pane
    latestUnread*: int              ## pane ID of most recent unread

proc initNotifState*(): NotifState =
  result.notifications = @[]
  result.unreadByPane = initTable[int, int]()
  result.latestUnread = -1

proc add*(state: var NotifState; paneId, notifId: int; body: string; timestamp: int64 = 0) =
  ## Add a notification for a pane
  let notif = Notification(paneId: paneId, id: notifId, body: body, timestamp: timestamp)
  state.notifications.add(notif)
  
  ## Update unread count
  let prevCount = state.unreadByPane.getOrDefault(paneId, 0)
  state.unreadByPane[paneId] = prevCount + 1
  state.latestUnread = paneId

proc markRead*(state: var NotifState; paneId: int) =
  ## Mark all notifications for a pane as read
  state.unreadByPane[paneId] = 0
  if state.latestUnread == paneId:
    state.latestUnread = -1

proc unread*(state: NotifState; paneId: int): bool =
  ## Check if a pane has unread notifications
  state.unreadByPane.getOrDefault(paneId, 0) > 0

proc unreadCount*(state: NotifState; paneId: int): int =
  ## Get count of unread notifications for a pane
  state.unreadByPane.getOrDefault(paneId, 0)

proc latestUnread*(state: NotifState): int =
  ## Get pane ID of most recent unread notification
  state.latestUnread

proc allUnread*(state: NotifState): seq[Notification] =
  ## Get all unread notifications, newest first
  var notifications = newSeq[Notification]()
  for notif in state.notifications:
    if state.unread(notif.paneId):
      notifications.add(notif)
  # Sort by timestamp, newest first
  for i in 0..<notifications.len:
    for j in i+1..<notifications.len:
      if notifications[i].timestamp < notifications[j].timestamp:
        let tmp = notifications[i]
        notifications[i] = notifications[j]
        notifications[j] = tmp
  result = notifications

proc clear*(state: var NotifState) =
  ## Clear all notifications
  state.notifications = @[]
  state.unreadByPane = initTable[int, int]()
  state.latestUnread = -1