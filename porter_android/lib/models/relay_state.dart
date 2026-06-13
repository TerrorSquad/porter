/// Tracks the relay (porter serve) progress for a single transfer.
class RelayState {
  int sent; // chunks successfully POSTed
  int failed; // POST errors
  bool complete; // porter serve reported the transfer complete
  bool? verified;
  String? joinedPath;
  String? lastError;

  RelayState({
    this.sent = 0,
    this.failed = 0,
    this.complete = false,
    this.verified,
    this.joinedPath,
    this.lastError,
  });
}
