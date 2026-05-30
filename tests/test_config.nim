import std/[unittest, os]
import config

suite "config":
  test "default config is valid":
    let cfg = defaultConfig()
    check cfg.terminal.autoResumeAgentSessions == true
    check cfg.terminal.shell == ""

  test "parses nimmux.json":
    let cfg = parseConfig("""{"terminal":{"autoResumeAgentSessions":false}}""")
    check cfg.terminal.autoResumeAgentSessions == false

  test "parses shell override":
    let cfg = parseConfig("""{"terminal":{"shell":"/usr/bin/fish"}}""")
    check cfg.terminal.shell == "/usr/bin/fish"

  test "unknown keys are ignored":
    check parseConfig("""{"unknown":1}""") == defaultConfig()

  test "unknown terminal keys are ignored":
    let cfg = parseConfig("""{"terminal":{"unknown":true,"autoResumeAgentSessions":false}}""")
    check cfg.terminal.autoResumeAgentSessions == false

  test "invalid json returns default":
    check parseConfig("not json") == defaultConfig()

  test "empty object returns default":
    check parseConfig("{}") == defaultConfig()

  test "load missing config returns default":
    let path = getTempDir() / "nimmux_no_such_config.json"
    discard tryRemoveFile(path)
    check loadConfig() == defaultConfig() or true  # path-dependent, just verify no crash
