import 'package:equatable/equatable.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';

import '../common/persistence/stable_storage_keys.dart';
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

  /// Changes whenever the authenticated identity is replaced or revoked.
  /// SyncEngine uses this to discard responses started in an older session.
  int _sessionGeneration = 0;
  int get sessionGeneration => _sessionGeneration;

  int _authAttempt = 0;

  AuthCubit({required SyncClient Function() client})
      : _client = client,
        super(const AuthState());

  @override
  String get storagePrefix => StableStorageKeys.auth;

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
    final attempt = ++_authAttempt;
    // A new login attempt may replace the current identity. Invalidate
    // requests and refreshes bound to the prior account immediately.
    _sessionGeneration++;
    emit(state.copyWith(status: AuthStatus.working, clearError: true));
    try {
      final tokens = await call();
      if (attempt != _authAttempt) return false;
      emit(AuthState(
        status: AuthStatus.signedIn,
        email: email,
        accessToken: tokens['access_token'] as String?,
        refreshToken: tokens['refresh_token'] as String?,
      ));
      return true;
    } on SyncException catch (e) {
      if (attempt != _authAttempt) return false;
      emit(state.copyWith(status: AuthStatus.signedOut, error: e.message));
      return false;
    } catch (e) {
      if (attempt != _authAttempt) return false;
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
  int? _refreshingGeneration;

  /// Refreshes the access token using the stored refresh token. Used by
  /// [SyncClient] on 401. Returns the new access token or null.
  Future<String?> refreshAccessToken() {
    final inFlight = _refreshing;
    final generation = _sessionGeneration;
    if (inFlight != null && _refreshingGeneration == generation) {
      return inFlight;
    }
    final fut = _doRefresh(generation);
    _refreshing = fut;
    _refreshingGeneration = generation;
    fut.whenComplete(() {
      if (identical(_refreshing, fut)) {
        _refreshing = null;
        _refreshingGeneration = null;
      }
    });
    return fut;
  }

  Future<String?> _doRefresh(int generation) async {
    final refresh = state.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      if (generation != _sessionGeneration) return null;
      _sessionGeneration++;
      emit(state.copyWith(
        status: AuthStatus.signedOut,
        clearAccess: true,
        clearRefresh: true,
        error: 'Session expired — please sign in again.',
      ));
      return null;
    }
    try {
      final tokens = await _client().refresh(refresh);
      if (generation != _sessionGeneration) return null;
      final access = tokens['access_token'] as String?;
      final nextRefresh = tokens['refresh_token'] as String?;
      if (access == null || access.isEmpty) return null;
      emit(state.copyWith(
        status: AuthStatus.signedIn,
        accessToken: access,
        refreshToken: nextRefresh,
        clearError: true,
      ));
      return access;
    } on SyncException catch (e) {
      if (generation != _sessionGeneration) return null;
      if (e.statusCode == 401 || e.statusCode == 403) {
        _sessionGeneration++;
        emit(state.copyWith(
          status: AuthStatus.signedOut,
          clearAccess: true,
          clearRefresh: true,
          error: 'Session expired — please sign in again.',
        ));
      }
      return null;
    } catch (_) {
      if (generation != _sessionGeneration) return null;
      // Transient transport error: keep stored tokens so a momentary network
      // drop does not permanently sign the user out.
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
    _authAttempt++;
    _sessionGeneration++;
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
      final rawStatus = AuthStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => AuthStatus.signedOut,
      );
      final hasTokens = (json['accessToken'] as String?)?.isNotEmpty == true;
      final status = !hasTokens
          ? AuthStatus.signedOut
          : (rawStatus == AuthStatus.working ? AuthStatus.signedIn : rawStatus);
      return AuthState(
        status: status,
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
        'status': state.status == AuthStatus.working
            ? (state.accessToken?.isNotEmpty == true
                ? AuthStatus.signedIn.name
                : AuthStatus.signedOut.name)
            : state.status.name,
        'email': state.email,
        'accessToken': state.accessToken,
        'refreshToken': state.refreshToken,
      };
}
