/// Verifies an access code with the token server before it is ever persisted.
///
/// The credential lifecycle is deliberately kept out of `AppCtrl`. The UI
/// controller may only ask this class to approve, restore or forget a code, so
/// the ordering that matters — check the server first, store second — lives in
/// one place that can be tested without a LiveKit session.
library;

/// Outcome of checking a candidate access code against the token server.
enum AccessCodeStatus {
  /// The server accepted the code, so it is safe to persist.
  verified,

  /// The server answered 401 or 403. The code is wrong or has been revoked.
  rejected,

  /// The server could not be reached, or failed for an unrelated reason.
  unreachable,
}

/// Maps a token-endpoint HTTP status to a verdict about the access code.
///
/// Only 401 and 403 are a verdict on the credential. Every other status is
/// transport or server trouble and must leave the stored code alone.
AccessCodeStatus statusForHttpResponse(int statusCode) =>
    (statusCode == 401 || statusCode == 403) ? AccessCodeStatus.rejected : AccessCodeStatus.unreachable;

/// Checks candidate codes and persists only the ones the server accepts.
class AccessCodeStore {
  AccessCodeStore({
    required this.verify,
    required this.read,
    required this.save,
    required this.clear,
  });

  /// Asks the token server whether a candidate code is accepted.
  final Future<AccessCodeStatus> Function(String code) verify;

  /// Returns the code persisted by an earlier successful [approve] call.
  final Future<String?> Function() read;

  /// Persists a code in the platform's secure storage.
  final Future<void> Function(String code) save;

  /// Removes the persisted code.
  final Future<void> Function() clear;

  /// Verifies [candidate] and stores it only when the server accepts it.
  ///
  /// A rejected, unreachable or throwing check leaves whatever was already
  /// stored untouched, so a mistyped code can never replace a working one.
  Future<AccessCodeStatus> approve(String candidate) async {
    AccessCodeStatus status;
    try {
      status = await verify(candidate);
    } catch (_) {
      // A check that cannot complete is not a verdict on the code.
      status = AccessCodeStatus.unreachable;
    }

    if (status == AccessCodeStatus.verified) {
      await save(candidate);
    }
    return status;
  }

  /// Returns the code saved at launch, or `null` when the user must type one.
  Future<String?> restore() => read();

  /// Forgets a code the server has rejected, either as wrong or as revoked.
  ///
  /// A storage failure is not surfaced: the in-memory credential is dropped by
  /// the caller regardless, and the next launch re-checks whatever remains.
  Future<void> forgetRejected() async {
    try {
      await clear();
    } catch (_) {
      // Nothing else can be done here; the caller still asks for a new code.
    }
  }
}

/// Runs at most one access-code check at a time.
///
/// A double tap or a stray Enter must not send a second request while the
/// first is still waiting for the token server, so the second caller receives
/// `null` and leaves the outcome to the submission already in flight.
class AccessCodeSubmission {
  bool _running = false;

  /// True while a check is in flight.
  bool get isRunning => _running;

  /// Runs [task] unless a check is already running.
  ///
  /// Returns the check outcome, or `null` for a duplicate submission. A task
  /// that throws is reported as [AccessCodeStatus.unreachable] so the gate is
  /// always released and the caller always gets an answer.
  Future<AccessCodeStatus?> run(Future<AccessCodeStatus> Function() task) async {
    if (_running) return null;

    _running = true;
    try {
      return await task();
    } catch (_) {
      return AccessCodeStatus.unreachable;
    } finally {
      _running = false;
    }
  }
}
