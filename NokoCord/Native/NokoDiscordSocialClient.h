#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface NokoDiscordOperationResult : NSObject

@property(nonatomic, readonly, getter=isSuccessful) BOOL successful;
@property(nonatomic, readonly, copy) NSString *message;

@end

typedef void (^NokoDiscordOperationCompletion)(NokoDiscordOperationResult *result);

/// Serializes Discord Social SDK presence operations and callback pumping.
/// This client only configures the application ID and uses desktop RPC. It does
/// not connect an SDK account or start an OAuth flow.
@interface NokoDiscordSocialClient : NSObject {
@private
    void *_implementation;
}

- (instancetype)initWithApplicationID:(uint64_t)applicationID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

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
