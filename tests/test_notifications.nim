import std/unittest
import notifications

suite "notifications":
  test "new notification marks pane unread":
    var ns = initNotifState()
    ns.add(paneId = 1, notifId = 0, body = "waiting")
    check ns.unread(1) == true

  test "multiple notifications accumulate":
    var ns = initNotifState()
    ns.add(paneId = 1, notifId = 0, body = "first")
    ns.add(paneId = 1, notifId = 1, body = "second")
    check ns.unreadCount(1) == 2

  test "jump to latest unread":
    var ns = initNotifState()
    ns.add(paneId = 2, notifId = 0, body = "a")
    ns.add(paneId = 3, notifId = 1, body = "b")
    check ns.latestUnread() == 3

  test "marking read clears badge":
    var ns = initNotifState()
    ns.add(paneId = 1, notifId = 0, body = "x")
    ns.markRead(1)
    check ns.unread(1) == false
    check ns.unreadCount(1) == 0

  test "all unread notifications":
    var ns = initNotifState()
    ns.add(paneId = 1, notifId = 0, body = "a")
    ns.add(paneId = 2, notifId = 1, body = "b")
    let all = ns.allUnread()
    check all.len == 2

  test "clear all notifications":
    var ns = initNotifState()
    ns.add(paneId = 1, notifId = 0, body = "x")
    ns.clear()
    check ns.notifications.len == 0
    check ns.latestUnread() == -1