/// Shared account-boundary lifecycle for authenticated mutation stores.
/// See `backend/stores.md`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/api_error.dart';
import 'mutation_boundary.dart';
import 'mutation_models.dart';

/// Mixin providing account-scoped [MutationLedger] lifecycle, boundary
/// invalidation, and operation ownership checks for mutation notifiers.
mixin AccountScopedMutationStore<S> on Notifier<S> {
  final MutationLedger ledger = MutationLedger();
  MutationBoundary? _boundary;

  /// The revision at which the current account boundary started: remote
  /// snapshots captured before it belong to the previous account.
  int _boundaryRevision = 0;
  Object _boundaryToken = Object();
  bool _built = false;
  bool _disposeRegistered = false;

  /// A fresh token per account boundary rebuild (A -> B -> A gives a third).
  Object get boundaryToken => _boundaryToken;

  int get boundaryRevision => _boundaryRevision;

  int revisionNow() => ledger.revisionNow;

  List<MutationDiscardEvent> get discardEvents => ledger.discardEvents;

  /// Initializes or refreshes the account boundary during [Notifier.build].
  void initAccountBoundary() {
    // Riverpod may rebuild a Notifier after an async dependency transitions
    // from loading to data while retaining the Notifier instance. A ledger
    // disposed by the previous provider lifecycle must not make the new
    // authenticated boundary permanently reject every operation.
    if (ledger.isDisposed) {
      ledger.reopen();
      _disposeRegistered = false;
    }
    ref.watch(
      accountStoreProvider.select((async) {
        // C1: the stable account id is the invalidate boundary; a token
        // refresh or profile metadata update keeps the same store valid.
        return async.value?.usableCurrent?.id;
      }),
    );
    final current = readMutationBoundary(ref);
    if (_boundary != null && !sameMutationBoundary(_boundary, current)) {
      invalidateBoundary(current, settleState: false);
    }
    _boundary = current;
    _boundaryToken = Object();
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() {
        ledger.dispose();
        _built = false;
      });
    }
    _built = true;
  }

  /// Ensures a usable authenticated account exists, invalidating stale
  /// in-flight mutations if the account changed between builds.
  MutationBoundary requireBoundary() {
    final current = readMutationBoundary(ref);
    if (current == null) {
      throw const ApiUnauthorized('no signed-in account');
    }
    if (_boundary != null && !sameMutationBoundary(_boundary, current)) {
      invalidateBoundary(current, settleState: _built);
    }
    _boundary = current;
    return current;
  }

  /// Cancels all active ledger entries for the previous account boundary.
  void invalidateBoundary(
    MutationBoundary? current, {
    required bool settleState,
  }) {
    _boundaryRevision = ledger.advance();
    ledger.cancelAll(MutationDiscardReason.accountChanged);
    if (settleState) settlePendingOnBoundaryInvalidated();
  }

  /// Verifies that [envelope] is still active, still belongs to the current
  /// account boundary, and still owns the store's pending slot.
  bool ownsMutation(
    MutationEnvelope envelope, {
    required bool Function() isPendingOwner,
    required void Function() onBoundaryCancelled,
  }) {
    if (!ledger.isActive(envelope)) return false;
    final current = readMutationBoundary(ref);
    _boundary = current;
    final reason = mutationBoundaryReason(envelope, current);
    if (reason != null) {
      ledger.discard(envelope, reason);
      onBoundaryCancelled();
      return false;
    }
    if (!isPendingOwner()) {
      ledger.discard(envelope, MutationDiscardReason.stale);
      return false;
    }
    return true;
  }

  /// Transitions any store-local pending entries to [MutationStatus.cancelled]
  /// when an account boundary invalidation happens after [build].
  void settlePendingOnBoundaryInvalidated();
}
