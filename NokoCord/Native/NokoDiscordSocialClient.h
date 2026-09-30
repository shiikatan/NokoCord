#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface NokoDiscordOperationResult : NSObject

@property(nonatomic, readonly, getter=isSuccessful) BOOL successful;
@property(nonatomic, readonly, copy) NSString *message;
@property(nonatomic, readonly) BOOL invalidGrant;
@property(nonatomic, readonly, getter=isRetryable) BOOL retryable;

@end

typedef void (^NokoDiscordOperationCompletion)(NokoDiscordOperationResult *result);
@class NokoDiscordTokenResult;
typedef void (^NokoDiscordTokenCompletion)(NokoDiscordTokenResult *result);
typedef void (^NokoDiscordConnectionStatusCompletion)(NSInteger status);
typedef void (^NokoDiscordStatusChangedHandler)(NSInteger status, NSInteger error, NSInteger errorDetail);
typedef void (^NokoDiscordTokenExpirationHandler)(void);

typedef NS_ENUM(NSInteger, NokoDiscordSocialClientStatus) {
    NokoDiscordSocialClientStatusDisconnected = 0,
    NokoDiscordSocialClientStatusConnecting = 1,
    NokoDiscordSocialClientStatusConnected = 2,
    NokoDiscordSocialClientStatusReady = 3,
    NokoDiscordSocialClientStatusReconnecting = 4,
    NokoDiscordSocialClientStatusDisconnecting = 5,
    NokoDiscordSocialClientStatusHTTPWait = 6,
};

@interface NokoDiscordTokenResult : NSObject

@property(nonatomic, readonly, getter=isSuccessful) BOOL successful;
@property(nonatomic, readonly) BOOL invalidGrant;
@property(nonatomic, readonly) BOOL wasCancelled;
@property(nonatomic, readonly, getter=isRetryable) BOOL retryable;
@property(nonatomic, readonly) NSTimeInterval expiresIn;
@property(nonatomic, readonly, copy, nullable) NSString *accessToken;
@property(nonatomic, readonly, copy, nullable) NSString *refreshToken;

@end

/// Serializes Discord Social SDK authentication, connection, presence, and
/// callback pumping on one queue.
@interface NokoDiscordSocialClient : NSObject {
@private
    void *_implementation;
}

- (instancetype)initWithApplicationID:(uint64_t)applicationID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, copy, nullable) NokoDiscordStatusChangedHandler statusChangedHandler;
@property(nonatomic, copy, nullable) NokoDiscordTokenExpirationHandler tokenExpirationHandler;

/// Runs Discord's public-client OAuth flow with SDK-generated state and PKCE.
- (void)authorizeWithCompletion:(NokoDiscordTokenCompletion)completion
    NS_SWIFT_NAME(authorize(completion:));

/// Exchanges a saved refresh token. The returned pair replaces the old pair.
- (void)refreshToken:(NSString *)refreshToken
          completion:(NokoDiscordTokenCompletion)completion
    NS_SWIFT_NAME(refreshToken(_:completion:));

/// Updates the SDK's bearer token. Call `connect()` after this completion on
/// the first authenticated connection.
- (void)updateToken:(NSString *)accessToken
         completion:(NokoDiscordOperationCompletion)completion
    NS_SWIFT_NAME(updateToken(_:completion:));

- (void)connect NS_SWIFT_NAME(connect());
- (void)disconnect NS_SWIFT_NAME(disconnect());
- (void)abortAuthorization NS_SWIFT_NAME(abortAuthorization());

/// Returns the last SDK connection state reported by its callback pump.
- (NSInteger)connectionStatus NS_SWIFT_NAME(connectionStatus());

/// Reads Client::GetStatus on the serialized SDK queue after previously queued
/// SDK operations have run.
- (void)refreshConnectionStatusWithCompletion:(NokoDiscordConnectionStatusCompletion)completion
    NS_SWIFT_NAME(refreshConnectionStatus(completion:));

/// Revokes the application authorization associated with this token.
- (void)revokeToken:(NSString *)token
         completion:(NokoDiscordOperationCompletion)completion
    NS_SWIFT_NAME(revokeToken(_:completion:));

/// `successful` comes from the SDK's UpdateRichPresence callback.
- (void)updateRichPresenceWithType:(NSString *)activityType
                              name:(nullable NSString *)activityName
                           details:(nullable NSString *)details
                                state:(nullable NSString *)state
                            startedAt:(nullable NSDate *)startedAt
                              endsAt:(nullable NSDate *)endsAt
                 statusDisplayField:(nullable NSString *)statusDisplayField
                         largeImage:(nullable NSString *)largeImage
                    largeImageText:(nullable NSString *)largeImageText
                           completion:(NokoDiscordOperationCompletion)completion
    NS_SWIFT_NAME(updateRichPresence(type:name:details:state:startedAt:endsAt:statusDisplayField:largeImage:largeImageText:completion:));

/// The SDK's clear call has no result callback. Completion reports that the
/// request was issued on the serialized SDK queue, not a Discord acknowledgement.
- (void)clearRichPresenceWithCompletion:(NokoDiscordOperationCompletion)completion
    NS_SWIFT_NAME(clearRichPresence(completion:));

/// Call periodically while this client is alive to deliver SDK callbacks.
- (void)runCallbacks NS_SWIFT_NAME(runCallbacks());

@end

NS_ASSUME_NONNULL_END
