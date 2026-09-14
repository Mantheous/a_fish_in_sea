import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import 'sync_client.dart';

enum AuthStatus { signedOut, working, signedIn }

/// Owns the sync-server identity (email + JWT pair).
///
/// Tokens persist in the same HydratedBox as everything else: this matches
/// the app's existing per-device storage story and keeps desktop builds
/// free of keychain dependencies. Trade-off is documented: on shared or
/// rooted devices prefer moving these two fields to flutter_secure_storage
/// later — the seam is [accessToken]/[refreshToken], callers never read
/// state fields directly for transport.
///
/// Google sign-in is the planned add-on (server Google port first): the
/// seam is [signInWithGoogle], currently an explicit [UnimplementedError].
class AuthState extends Equatable {
  final AuthStatus status;
  final String email;
  final String? accessToken;
  final String? refreshToken;
  final String? error;

  const AuthState({
    this.status = AuthStatus.signedOut,
    this.email = '',
    this.accessToken,
    this.refreshToken,
    this.error,
  });

  bool get isSignedIn =>
      status == AuthStatus.signedIn &&
      (accessToken ?? '').isNotEmpty;

  AuthState copyWith({
    AuthStatus? status,
    String? email,
    String? accessToken,
    bool clearAccess = false,
    String? refreshToken,
    bool clearRefresh = false,
    String? error,
    bool clearError = false,
  }) =>
      AuthState(
        status: status ?? this.status,
        email: email ?? this.email,
        accessToken: clearAccess ? null : (accessToken ?? this.accessToken),
        refreshToken:
            clearRefresh ? null : (refreshToken ?? this.refreshToken),
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props =>
      [status, email, accessToken, refreshToken, error];
}

class AuthCubit extends HydratedCubit<AuthState> {
  final SyncClient Function() _client;

  AuthCubit({required SyncClient Function() client})
      : _client = client,
        super(const AuthState());

  Future<bool> register(String email, String password) =>
      _tokenCall(() => _client().register(email.trim(), password),
          email.trim());

  Future<bool> login(String email, String password) =>
      _tokenCall(
          () => _client().login(email.trim(), password), email.trim());

  Future<bool> _tokenCall(
    Future<Map<String, dynamic>> Function() call,
    String email,
  ) async {
    emit(state.copyWith(status: AuthStatus.working, clearError: true));
    try {
      final tokens = await call();
      emit(AuthState(
        status: AuthStatus.signedIn,
        email: email,
        accessToken: tokens['access_token'] as String?,
        refreshToken: tokens['refresh_token'] as String?,
      ));
      return true;
    } on SyncException catch (e) {
      emit(state.copyWith(status: AuthStatus.signedOut, error: e.message));
      return false;
    } catch (e) {
      emit(state.copyWith(
          status: AuthStatus.signedOut, error: e.toString()));
      return false;
    }
  }

  /// In-flight refresh shared by concurrent callers. The server kills
  /// the whole token family when a revoked token is replayed, so two
  /// simultaneous refreshes with the same token would sign the user
  /// out — this dedups them into one network call.
  Future<String?>? _refreshing;

  /// Refreshes the access token using the stored refresh token. Used by
  /// [SyncClient] on 401. Returns the new access token or null.
  Future<String?> refreshAccessToken() {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final fut = _doRefresh();
    _refreshing = fut;
    fut.whenComplete(() {
      if (identical(_refreshing, fut)) _refreshing = null;
    });
    return fut;
  }

  Future<String?> _doRefresh() async {
    final refresh = state.refreshToken;
    if (refresh == null || refresh.isEmpty) return null;
    try {
      final tokens = await _client().refresh(refresh);
      final access = tokens['access_token'] as String?;
      final nextRefresh = tokens['refresh_token'] as String?;
      if (access == null || access.isEmpty) return null;
      emit(state.copyWith(
        status: AuthStatus.signedIn,
        accessToken: access,
        refreshToken: nextRefresh,
      ));
      return access;
    } catch (_) {
      emit(state.copyWith(
          status: AuthStatus.signedOut,
          clearAccess: true,
          clearRefresh: true,
          error: 'Session expired — please sign in again.'));
      return null;
    }
  }

  /// Google sign-in seam (add-on after the server Google port). Currently
  /// explicit so nobody mistakes email auth for SSO.
  Future<bool> signInWithGoogle() =>
      throw UnimplementedError(
          'Google sign-in lands after the server Google port; '
          'use email + password for now.');

  void logout() {
    final refresh = state.refreshToken;
    if (refresh != null && refresh.isNotEmpty) {
      // Best-effort server revocation; local state clears regardless.
      _client().logout(refresh);
    }
    emit(const AuthState());
  }

  /// Transport handle for [SyncEngine]; same instance the cubit logs in with.
  SyncClient get syncClient => _client();

  @override
  AuthState? fromJson(Map<String, dynamic> json) {
    try {
      final status = AuthStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => AuthStatus.signedOut,
      );
      final hasTokens = (json['accessToken'] as String?)?.isNotEmpty == true;
      return AuthState(
        status: hasTokens ? status : AuthStatus.signedOut,
        email: json['email'] as String? ?? '',
        accessToken: json['accessToken'] as String?,
        refreshToken: json['refreshToken'] as String?,
      );
    } catch (_) {
      return const AuthState();
    }
  }

  @override
  Map<String, dynamic> toJson(AuthState state) => {
        'status': state.status.name,
        'email': state.email,
        'accessToken': state.accessToken,
        'refreshToken': state.refreshToken,
      };
}
