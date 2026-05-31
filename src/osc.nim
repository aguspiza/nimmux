## OSC sequence parser.
## Handles OSC 9/99/777 notifications from terminal output.
## OSC sequences look like: ESC ] <command> ; <params> BEL
## or ESC ] <command> ; <params> ST (String Terminator)

import std/strutils

type
  OscKind* = enum
    OscNone,
    OscNotify,      ## OSC 9 - terminal notification
    OscTitle,       ## OSC 2 - window title
    OscIconTitle,   ## OSC 1 - icon + title
    OscHyperlink,   ## OSC 8 - hyperlink
    OscOther

  OscMessage* = ref object
    case kind*: OscKind
    of OscNotify:
      notifId*: int       ## notification ID (0 = default)
      body*: string       ## notification text
    of OscTitle, OscIconTitle:
      title*: string
    of OscHyperlink:
      linkId*: string
      uri*: string
      params*: string
    of OscNone, OscOther:
      command*: int
      message*: string

type
  OscState* = enum
    Started,
    EscReceived,
    OscReceived,
    Parsing,
    Complete

  OscParser* = object
    state*: OscState
    buffer*: string
    command*: int
    params*: string

proc initOscParser*(): OscParser =
  OscParser(state: OscState.Started)

proc reset*(p: var OscParser) =
  p.state = OscState.Started
  p.buffer = ""
  p.command = 0
  p.params = ""

proc finish*(p: var OscParser): OscMessage =
  let cmd = p.command
  let params = p.params

  # Parse params based on command
  case cmd
  of 9:
    # OSC 9 - notification: "id;body" or just "body"
    let parts = params.split(';', 2)
    let msg = OscMessage(kind: OscNotify)
    if parts.len >= 2:
      # Format: id;body
      msg.notifId = parseInt(parts[0])
      msg.body = parts[1]
    else:
      # Format: body (id defaults to 0)
      msg.notifId = 0
      msg.body = params
    result = msg

  of 2:
    # OSC 2 - window title
    result = OscMessage(kind: OscTitle, title: params)

  of 1:
    # OSC 1 - icon title
    let parts = params.split(';', 2)
    if parts.len >= 2:
      result = OscMessage(kind: OscIconTitle, title: parts[1])
    else:
      result = OscMessage(kind: OscIconTitle, title: params)

  of 8:
    # OSC 8 - hyperlink
    let parts = params.split(';', 2)
    let msg = OscMessage(kind: OscHyperlink)
    if parts.len >= 1:
      msg.linkId = parts[0]
    if parts.len >= 2:
      let uriParts = parts[1].split('?', 2)
      msg.uri = uriParts[0]
      if uriParts.len > 1:
        msg.params = uriParts[1]
    result = msg

  else:
    result = OscMessage(kind: OscOther, command: cmd, message: params)

  p.reset()

proc feed*(p: var OscParser; data: string): OscMessage =
  ## Feed bytes into the parser. Returns a complete message when available.
  for i, c in data:
    case p.state
    of Started:
      if c == '\x1B':  # ESC
        p.state = OscState.EscReceived
        p.buffer = ""
      elif c == '\x07':  # BEL
        # BEL terminator
        if p.state == OscState.Parsing:
          p.state = OscState.Complete
          return p.finish()
      elif c == '\x03':  # ETX (Ctrl+C) - cancel
        p.reset()

    of EscReceived:
      if c == ']':
        p.state = OscState.OscReceived
        p.buffer = ""  # Will hold command number
      else:
        p.reset()
        if c == '\x1B':
          p.state = OscState.EscReceived
          p.buffer = ""
        else:
          p.state = OscState.Started

    of OscReceived:
      if c == ';':
        p.state = OscState.Parsing
        # Buffer contains command number as string
        p.command = parseInt(p.buffer)
        p.buffer = ""  # Will hold params
      else:
        p.buffer.add(c)  # Accumulate command digits

    of Parsing:
      if c == '\x07':  # BEL terminator
        p.state = OscState.Complete
        p.params = p.buffer
        return p.finish()
      elif c == '\x1B':  # Possible ST sequence
        p.buffer.add(c)
      elif c == ']':
        # Check for ESC ] pattern (another OSC starting)
        if p.buffer.len > 0 and p.buffer[^1] == '\x1B':
          p.reset()
          p.state = OscState.EscReceived
          p.buffer = ""
        else:
          p.buffer.add(c)
      else:
        p.buffer.add(c)

    of Complete:
      p.reset()

  return nil

proc parseOsc*(data: string): OscMessage =
  ## One-shot parser for simple OSC sequences
  var parser = initOscParser()
  return parser.feed(data)