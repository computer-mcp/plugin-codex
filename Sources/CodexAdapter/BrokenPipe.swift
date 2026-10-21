import Darwin

/// Installs a process-wide no-op SIGPIPE handler once for the default disposition,
/// so broken child-input pipes report write errors. Existing handlers and SIG_IGN
/// are preserved. A caught signal resets to default on exec; SIG_IGN would survive
/// exec and change the signal behavior of child processes.
func installBrokenPipeHandler() {
  _ = brokenPipeHandlerInstallation
}

private let brokenPipeHandlerInstallation: Void = {
  var action = sigaction()
  guard sigaction(SIGPIPE, nil, &action) == 0 else { return }
  guard action.__sigaction_u.__sa_handler == nil else { return }
  action.__sigaction_u.__sa_handler = { _ in }
  sigemptyset(&action.sa_mask)
  action.sa_flags = SA_RESTART
  _ = sigaction(SIGPIPE, &action, nil)
}()
