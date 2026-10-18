import Foundation
import Testing

@testable import CodexAdapter

@Suite
final class CodexProcessEnvironmentTests {
  @Test
  func testChildCodexProcessDoesNotInheritParentSessionAuthority() {
    let environment = CodexProcessEnvironment.resolved(
      base: [
        "CODEX_APP_TOOLS_PIPE_PATH": "/tmp/parent-tools.sock",
        "CODEX_CI": "1",
        "CODEX_HOME": "/tmp/codex-home",
        "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Codex Desktop",
        "CODEX_PERMISSION_PROFILE": "parent-profile",
        "CODEX_SAGE_BACKFILL_TRACKER_TAB_REUSE": "1",
        "CODEX_SESSION_ID": "parent-session",
        "CODEX_THREAD_ID": "parent-thread",
        "PATH": "/usr/bin",
      ],
      systemProxy: SystemNetworkProxySettings()
    )

    #expect(environment["CODEX_APP_TOOLS_PIPE_PATH"] == nil)
    #expect(environment["CODEX_CI"] == nil)
    #expect(environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == nil)
    #expect(environment["CODEX_PERMISSION_PROFILE"] == nil)
    #expect(environment["CODEX_SAGE_BACKFILL_TRACKER_TAB_REUSE"] == nil)
    #expect(environment["CODEX_SESSION_ID"] == nil)
    #expect(environment["CODEX_THREAD_ID"] == nil)
    #expect(environment["CODEX_HOME"] == "/tmp/codex-home")
    #expect(environment["PATH"] == "/usr/bin")
  }

  @Test
  func testFixedMacOSProxiesAreMappedToConventionalCodexEnvironment() {
    let environment = CodexProcessEnvironment.resolved(
      base: ["PATH": "/usr/bin"],
      systemProxy: SystemNetworkProxySettings(
        httpProxy: "http://127.0.0.1:6152",
        httpsProxy: "http://127.0.0.1:6152",
        socksProxy: "socks5://127.0.0.1:6153",
        bypassHosts: ["*.local", "localhost", "invalid,entry"]
      )
    )

    #expect(environment["PATH"] == "/usr/bin")
    #expect(environment["HTTP_PROXY"] == "http://127.0.0.1:6152")
    #if !os(Windows)
      #expect(environment["http_proxy"] == "http://127.0.0.1:6152")
    #endif
    #expect(environment["HTTPS_PROXY"] == "http://127.0.0.1:6152")
    #if !os(Windows)
      #expect(environment["https_proxy"] == "http://127.0.0.1:6152")
    #endif
    #expect(environment["ALL_PROXY"] == "socks5://127.0.0.1:6153")
    #if !os(Windows)
      #expect(environment["all_proxy"] == "socks5://127.0.0.1:6153")
    #endif
    #expect(environment["NO_PROXY"] == "localhost,127.0.0.1,::1,*.local")
    #if !os(Windows)
      #expect(environment["no_proxy"] == "localhost,127.0.0.1,::1,*.local")
    #else
      #expect(
        environment.keys.sorted() == ["ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "PATH"])
    #endif
  }

  @Test
  func testInheritedProxyEnvironmentWinsAndIsMirroredWithoutSystemOverride() {
    let environment = CodexProcessEnvironment.resolved(
      base: [
        "PATH": "/usr/bin",
        "https_proxy": "http://inherited.example:8080",
        "NO_PROXY": "internal.example",
      ],
      systemProxy: SystemNetworkProxySettings(
        httpProxy: "http://system.example:9000",
        httpsProxy: "http://system.example:9001",
        socksProxy: "socks5://system.example:9002"
      )
    )

    #expect(environment["HTTP_PROXY"] == nil)
    #expect(environment["http_proxy"] == nil)
    #if os(Windows)
      #expect(environment["HTTPS_PROXY"] == nil)
    #else
      #expect(environment["HTTPS_PROXY"] == "http://inherited.example:8080")
    #endif
    #expect(environment["https_proxy"] == "http://inherited.example:8080")
    #expect(environment["ALL_PROXY"] == nil)
    #expect(environment["all_proxy"] == nil)
    #expect(environment["NO_PROXY"] == "internal.example")
    #if os(Windows)
      #expect(environment["no_proxy"] == nil)
    #else
      #expect(environment["no_proxy"] == "internal.example")
    #endif
  }

  #if os(Windows)
    @Test
    func testNativeCaseAliasesDoNotLeakParentAuthorityOrDuplicateProxies() {
      let base = [
        "Computer_Mcp_Host_Context": "parent-context", "Computer_Mcp_Host_Fd": "123",
        "Codex_Thread_Id": "parent-thread", "Codex_Permission_Profile": "parent-profile",
        "Codex_Home": "C:\\Codex", "hTtPs_PrOxY": "http://proxy.example:8080",
        "No_PrOxY": "internal.example", "CODEX_THREAD_ID\0suffix": "invalid-key",
      ]
      let environment = CodexProcessEnvironment.resolved(
        base: base,
        systemProxy: SystemNetworkProxySettings(httpsProxy: "http://system.example:9000"))
      #expect(
        environment == [
          "Codex_Home": "C:\\Codex", "hTtPs_PrOxY": "http://proxy.example:8080",
          "No_PrOxY": "internal.example", "CODEX_THREAD_ID\0suffix": "invalid-key",
        ])
    }
  #endif

  @Test
  func testNoProxyConfigurationLeavesTheBaseEnvironmentUnchanged() {
    let base = ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"]
    let environment = CodexProcessEnvironment.resolved(
      base: base,
      systemProxy: SystemNetworkProxySettings()
    )

    #expect(environment == base)
  }

  @Test
  func testConflictingInheritedVariableCasesRemainUntouched() {
    let environment = CodexProcessEnvironment.resolved(
      base: [
        "HTTPS_PROXY": "http://uppercase.example:8080",
        "https_proxy": "http://lowercase.example:8081",
      ],
      systemProxy: SystemNetworkProxySettings(httpsProxy: "http://system.example:9001")
    )

    #expect(environment["HTTPS_PROXY"] == "http://uppercase.example:8080")
    #expect(environment["https_proxy"] == "http://lowercase.example:8081")
  }

  @Test
  func testSystemSettingsParserRejectsDisabledAndMalformedFixedProxies() {
    let settings = SystemNetworkProxySettings.resolved(from: [
      "HTTPEnable": 1,
      "HTTPProxy": "127.0.0.1",
      "HTTPPort": 6152,
      "HTTPSEnable": 0,
      "HTTPSProxy": "127.0.0.2",
      "HTTPSPort": 6153,
      "SOCKSEnable": 1,
      "SOCKSProxy": "",
      "SOCKSPort": 6154,
      "ExceptionsList": ["localhost", "*.example.test"],
    ])

    #expect(settings.httpProxy == "http://127.0.0.1:6152")
    #expect(settings.httpsProxy == nil)
    #expect(settings.socksProxy == nil)
    #expect(settings.bypassHosts == ["localhost", "*.example.test"])
  }
}
