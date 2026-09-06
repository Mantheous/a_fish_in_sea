import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:a_fish_in_sea/finances/service/plaid_link_handler.dart';
import 'package:a_fish_in_sea/finances/service/plaid_service.dart';
import 'package:a_fish_in_sea/finances/service/plaid_user_id.dart';

/// Connection status for the Plaid integration.
enum PlaidConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// State for the Plaid connection.
class PlaidState extends Equatable {
  final String userId;
  final PlaidConnectionStatus status;
  final String? itemId;
  final double? currentBalance;
  final List<Map<String, dynamic>> accounts;
  final String? errorMessage;

  const PlaidState({
    required this.userId,
    this.status = PlaidConnectionStatus.disconnected,
    this.itemId,
    this.currentBalance,
    this.accounts = const [],
    this.errorMessage,
  });

  bool get isConnected => status == PlaidConnectionStatus.connected;

  PlaidState copyWith({
    String? userId,
    PlaidConnectionStatus? status,
    String? itemId,
    double? currentBalance,
    List<Map<String, dynamic>>? accounts,
    String? errorMessage,
    bool clearError = false,
    bool clearConnection = false,
  }) {
    return PlaidState(
      userId: userId ?? this.userId,
      status: clearConnection
          ? PlaidConnectionStatus.disconnected
          : (status ?? this.status),
      itemId: clearConnection ? null : (itemId ?? this.itemId),
      currentBalance:
          clearConnection ? null : (currentBalance ?? this.currentBalance),
      accounts: clearConnection ? const [] : (accounts ?? this.accounts),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  @override
  List<Object?> get props =>
      [userId, status, itemId, currentBalance, accounts, errorMessage];
}

/// Manages the Plaid bank connection lifecycle.
class PlaidCubit extends HydratedCubit<PlaidState> {
  PlaidCubit({PlaidService? service, String? userId})
      : _serviceOverride = service,
        super(PlaidState(userId: userId ?? PlaidUserId.generate())) {
    _service = _serviceOverride ?? PlaidService(userId: state.userId);
  }

  final PlaidService? _serviceOverride;
  late PlaidService _service;

  String get serverUrl => _service.baseUrl;

  // ── Connection ──────────────────────────────────────────────────────

  /// Connect via Plaid Link (iOS, Android, Web) or sandbox auto-connect on
  /// desktop platforms where Link is unavailable.
  Future<void> connectBank() async {
    emit(state.copyWith(
      status: PlaidConnectionStatus.connecting,
      clearError: true,
    ));

    try {
      if (PlaidLinkHandler.isSupported) {
        final linkToken = await _service.createLinkToken();
        final publicToken = await PlaidLinkHandler.open(linkToken);
        if (publicToken == null) {
          emit(state.copyWith(status: PlaidConnectionStatus.disconnected));
          return;
        }
        final exchange = await _service.exchangePublicToken(publicToken);
        await _onConnected(itemId: exchange['item_id'] as String?);
      } else {
        await _service.sandboxAutoConnect();
        final info = await _service.getInfo();
        await _onConnected(itemId: info['item_id'] as String?);
      }
    } on PlaidServiceException catch (e) {
      emit(state.copyWith(
        status: PlaidConnectionStatus.error,
        errorMessage: e.message,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: PlaidConnectionStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  /// Sandbox-only shortcut without Link UI (desktop dev).
  Future<void> sandboxAutoConnect() async {
    emit(state.copyWith(
      status: PlaidConnectionStatus.connecting,
      clearError: true,
    ));
    try {
      await _service.sandboxAutoConnect();
      final info = await _service.getInfo();
      await _onConnected(itemId: info['item_id'] as String?);
    } on PlaidServiceException catch (e) {
      emit(state.copyWith(
        status: PlaidConnectionStatus.error,
        errorMessage: e.message,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: PlaidConnectionStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> disconnect() async {
    try {
      await _service.disconnect();
    } catch (_) {
      // Best-effort; clear local state regardless.
    }
    emit(state.copyWith(clearConnection: true));
  }

  Future<void> _onConnected({String? itemId}) async {
    emit(state.copyWith(
      status: PlaidConnectionStatus.connected,
      itemId: itemId,
    ));
    await fetchBalance();
    await fetchAccounts();
  }

  // ── Data fetching ───────────────────────────────────────────────────

  Future<void> fetchBalance() async {
    try {
      final data = await _service.getBalance();
      final accounts = data['accounts'] as List<dynamic>? ?? [];
      double totalBalance = 0;
      for (final account in accounts) {
        final type = account['type'] as String?;
        if (type == 'depository') {
          final balances = account['balances'] as Map<String, dynamic>?;
          totalBalance += (balances?['current'] as num?)?.toDouble() ?? 0;
        }
      }
      emit(state.copyWith(currentBalance: totalBalance));
    } catch (_) {
      // Non-fatal — balance will stay stale
    }
  }

  Future<void> fetchAccounts() async {
    try {
      final accounts = await _service.getAccounts();
      emit(state.copyWith(accounts: accounts));
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> fetchTransactions() async {
    try {
      return await _service.getTransactions();
    } catch (e) {
      emit(state.copyWith(errorMessage: 'Failed to fetch transactions: $e'));
      return [];
    }
  }

  /// Restore connection if the server still has a token for this user.
  Future<void> checkExistingConnection() async {
    try {
      final info = await _service.getInfo();
      if (info['access_token'] != null) {
        await _onConnected(itemId: info['item_id'] as String?);
      }
    } catch (_) {
      // Server not running or no connection
    }
  }

  // ── Persistence ─────────────────────────────────────────────────────

  @override
  PlaidState? fromJson(Map<String, dynamic> json) {
    final wasConnected = json['wasConnected'] as bool? ?? false;
    final userId =
        json['userId'] as String? ?? PlaidUserId.generate();
    return PlaidState(
      userId: userId,
      status: wasConnected
          ? PlaidConnectionStatus.disconnected
          : PlaidConnectionStatus.disconnected,
      itemId: json['itemId'] as String?,
    );
  }

  @override
  Map<String, dynamic>? toJson(PlaidState state) {
    return {
      'userId': state.userId,
      'wasConnected': state.isConnected,
      'itemId': state.itemId,
    };
  }

  @override
  void onChange(Change<PlaidState> change) {
    super.onChange(change);
    if (change.nextState.userId != _service.userId) {
      _service = _serviceOverride ?? PlaidService(userId: change.nextState.userId);
    }
  }
}
