#import "NokoDiscordSocialClient.h"

#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>

#include <atomic>
#include <cmath>
#include <limits>
#include <memory>
#include <optional>
#include <string>

@interface NokoDiscordOperationResult ()

@property(nonatomic, readwrite, getter=isSuccessful) BOOL successful;
@property(nonatomic, readwrite, copy) NSString *message;
@property(nonatomic, readwrite) BOOL invalidGrant;
@property(nonatomic, readwrite, getter=isRetryable) BOOL retryable;

- (instancetype)initWithSuccessful:(BOOL)successful
                       invalidGrant:(BOOL)invalidGrant
                          retryable:(BOOL)retryable
                            message:(NSString *)message;

@end

@interface NokoDiscordTokenResult ()

@property(nonatomic, readwrite, getter=isSuccessful) BOOL successful;
@property(nonatomic, readwrite) BOOL invalidGrant;
@property(nonatomic, readwrite) BOOL wasCancelled;
@property(nonatomic, readwrite, getter=isRetryable) BOOL retryable;
@property(nonatomic, readwrite) NSTimeInterval expiresIn;
@property(nonatomic, readwrite, copy, nullable) NSString *accessToken;
@property(nonatomic, readwrite, copy, nullable) NSString *refreshToken;

- (instancetype)initWithSuccessful:(BOOL)successful
                       invalidGrant:(BOOL)invalidGrant
                       wasCancelled:(BOOL)wasCancelled
                         retryable:(BOOL)retryable
                          expiresIn:(NSTimeInterval)expiresIn
                        accessToken:(nullable NSString *)accessToken
                       refreshToken:(nullable NSString *)refreshToken;

@end

namespace {

struct CallbackGate {
    std::atomic_bool active{true};
};

struct NativeImplementation {
    std::unique_ptr<discordpp::Client> client;
    std::shared_ptr<CallbackGate> callbackGate = std::make_shared<CallbackGate>();
    uint64_t applicationID = 0;
    std::atomic<NSInteger> currentStatus{NokoDiscordSocialClientStatusDisconnected};
};

std::optional<std::string> OptionalUTF8(NSString *value)
{
    if (value == nil || value.length == 0) {
        return std::nullopt;
    }

    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8 == nil) {
        return std::nullopt;
    }

    return std::string(static_cast<const char *>(utf8.bytes), utf8.length);
}

std::optional<uint64_t> UnixMilliseconds(NSDate *date)
{
    if (date == nil) {
        return std::nullopt;
    }

    const double milliseconds = std::floor(date.timeIntervalSince1970 * 1000.0);
    if (!std::isfinite(milliseconds) || milliseconds <= 0.0 || milliseconds >= std::ldexp(1.0, 64)) {
        return std::nullopt;
    }

    return static_cast<uint64_t>(milliseconds);
}

NSString *StringFromUTF8(const std::string &value)
{
    NSString *message = [[NSString alloc] initWithBytes:value.data()
                                                  length:value.size()
                                                encoding:NSUTF8StringEncoding];
    return message ?: @"Discord Social SDK returned an unreadable result.";
}

BOOL IsInvalidGrant(const discordpp::ClientResult &result)
{
    if (result.Type() != discordpp::ErrorType::HTTPError) {
        return NO;
    }

    const std::string response = result.ResponseBody();
    return response.find("invalid_grant") != std::string::npos ? YES : NO;
}

// Pass ownership by value: Objective-C blocks retain C++ reference parameters
// as references, which would dangle when the SDK callback returns.
void CompleteTokenOnMainQueue(std::shared_ptr<CallbackGate> gate,
                              NokoDiscordTokenCompletion completion,
                              discordpp::ClientResult result,
                              std::string accessToken,
                              std::string refreshToken,
                              int32_t expiresIn)
{
    if (completion == nil || !gate->active.load(std::memory_order_acquire)) {
        return;
    }

    const BOOL invalidGrant = IsInvalidGrant(result);
    const BOOL wasCancelled = result.Type() == discordpp::ErrorType::Aborted ? YES : NO;
    const BOOL retryable = result.Retryable() ? YES : NO;
    const BOOL successful = result.Successful() && !accessToken.empty() &&
        !refreshToken.empty() && expiresIn > 0;
    NSString *access = successful ? StringFromUTF8(accessToken) : nil;
    NSString *refresh = successful ? StringFromUTF8(refreshToken) : nil;
    NokoDiscordTokenResult *tokenResult = [[NokoDiscordTokenResult alloc]
        initWithSuccessful:successful
              invalidGrant:invalidGrant
              wasCancelled:wasCancelled
                retryable:retryable
                 expiresIn:successful ? expiresIn : 0
               accessToken:access
              refreshToken:refresh];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gate->active.load(std::memory_order_acquire)) {
            return;
        }
        completion(tokenResult);
    });
}

void CompleteOnMainQueue(std::shared_ptr<CallbackGate> gate,
                         NokoDiscordOperationCompletion completion,
                         BOOL successful,
                         NSString *message,
                         BOOL invalidGrant = NO,
                         BOOL retryable = NO)
{
    if (completion == nil || !gate->active.load(std::memory_order_acquire)) {
        return;
    }

    NokoDiscordOperationResult *result = [[NokoDiscordOperationResult alloc]
        initWithSuccessful:successful
              invalidGrant:invalidGrant
                 retryable:retryable
                   message:message];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gate->active.load(std::memory_order_acquire)) {
            return;
        }
        completion(result);
    });
}

} // namespace

@implementation NokoDiscordOperationResult

- (instancetype)initWithSuccessful:(BOOL)successful
                       invalidGrant:(BOOL)invalidGrant
                          retryable:(BOOL)retryable
                            message:(NSString *)message
{
    self = [super init];
    if (self != nil) {
        _successful = successful;
        _invalidGrant = invalidGrant;
        _retryable = retryable;
        _message = [message copy];
    }
    return self;
}

@end

@implementation NokoDiscordTokenResult

- (instancetype)initWithSuccessful:(BOOL)successful
                       invalidGrant:(BOOL)invalidGrant
                       wasCancelled:(BOOL)wasCancelled
                         retryable:(BOOL)retryable
                          expiresIn:(NSTimeInterval)expiresIn
                        accessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken
{
    self = [super init];
    if (self != nil) {
        _successful = successful;
        _invalidGrant = invalidGrant;
        _wasCancelled = wasCancelled;
        _retryable = retryable;
        _expiresIn = expiresIn;
        _accessToken = [accessToken copy];
        _refreshToken = [refreshToken copy];
    }
    return self;
}

@end

@interface NokoDiscordSocialClient ()

@property(nonatomic, strong) dispatch_queue_t sdkQueue;

@end

@implementation NokoDiscordSocialClient

- (instancetype)initWithApplicationID:(uint64_t)applicationID
{
    self = [super init];
    if (self != nil) {
        self.sdkQueue = dispatch_queue_create("com.shiikatan.nokocord.discord-social-sdk",
                                              DISPATCH_QUEUE_SERIAL);

        auto *implementation = new NativeImplementation();
        implementation->applicationID = applicationID;
        _implementation = implementation;

        __weak NokoDiscordSocialClient *weakSelf = self;
        std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
        dispatch_sync(self.sdkQueue, ^{
            implementation->client = std::make_unique<discordpp::Client>();
            implementation->client->SetApplicationId(applicationID);
            implementation->client->SetStatusChangedCallback(
                [weakSelf, weakGate, implementation](discordpp::Client::Status status,
                                    discordpp::Client::Error error,
                                    int32_t errorDetail) {
                    implementation->currentStatus.store(static_cast<NSInteger>(status),
                                                        std::memory_order_release);
                    std::shared_ptr<CallbackGate> gate = weakGate.lock();
                    if (gate == nullptr || !gate->active.load(std::memory_order_acquire)) {
                        return;
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!gate->active.load(std::memory_order_acquire)) {
                            return;
                        }
                        NokoDiscordSocialClient *client = weakSelf;
                        NokoDiscordStatusChangedHandler handler = client.statusChangedHandler;
                        if (handler != nil) {
                            handler(static_cast<NSInteger>(status),
                                    static_cast<NSInteger>(error),
                                    errorDetail);
                        }
                    });
                });
            implementation->client->SetTokenExpirationCallback([weakSelf, weakGate]() {
                std::shared_ptr<CallbackGate> gate = weakGate.lock();
                if (gate == nullptr || !gate->active.load(std::memory_order_acquire)) {
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!gate->active.load(std::memory_order_acquire)) {
                        return;
                    }
                    NokoDiscordSocialClient *client = weakSelf;
                    NokoDiscordTokenExpirationHandler handler = client.tokenExpirationHandler;
                    if (handler != nil) {
                        handler();
                    }
                });
            });
        });
    }
    return self;
}

- (void)authorizeWithCompletion:(NokoDiscordTokenCompletion)completion
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr || completion == nil) {
        return;
    }

    std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
    const uint64_t applicationID = implementation->applicationID;
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client == nullptr ||
            !implementation->callbackGate->active.load(std::memory_order_acquire)) {
            return;
        }

        discordpp::Client *client = implementation->client.get();
        discordpp::AuthorizationCodeVerifier codeVerifier = client->CreateAuthorizationCodeVerifier();
        discordpp::AuthorizationArgs args;
        args.SetClientId(applicationID);
        args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
        args.SetCodeChallenge(codeVerifier.Challenge());

        client->Authorize(std::move(args),
            [weakGate, client, applicationID, codeVerifier, completion](discordpp::ClientResult authResult,
                                                                         std::string code,
                                                                         std::string redirectURI) mutable {
                std::shared_ptr<CallbackGate> gate = weakGate.lock();
                if (gate == nullptr || !gate->active.load(std::memory_order_acquire)) {
                    return;
                }
                if (!authResult.Successful() || code.empty()) {
                    CompleteTokenOnMainQueue(gate, completion, authResult, {}, {}, 0);
                    return;
                }

                client->GetToken(applicationID,
                                 code,
                                 codeVerifier.Verifier(),
                                 redirectURI,
                                 [weakGate, completion](discordpp::ClientResult tokenResult,
                                                        std::string accessToken,
                                                        std::string refreshToken,
                                                        discordpp::AuthorizationTokenType,
                                                        int32_t expiresIn,
                                                        std::string) {
                                     std::shared_ptr<CallbackGate> tokenGate = weakGate.lock();
                                     if (tokenGate == nullptr ||
                                         !tokenGate->active.load(std::memory_order_acquire)) {
                                         return;
                                     }
                                     CompleteTokenOnMainQueue(tokenGate,
                                                             completion,
                                                             tokenResult,
                                                             std::move(accessToken),
                                                             std::move(refreshToken),
                                                             expiresIn);
                                 });
            });
    });
}

- (void)refreshToken:(NSString *)refreshToken completion:(NokoDiscordTokenCompletion)completion
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr || completion == nil) {
        return;
    }
    const std::optional<std::string> refreshValue = OptionalUTF8(refreshToken);
    if (!refreshValue.has_value()) {
        return;
    }

    std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
    const uint64_t applicationID = implementation->applicationID;
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client == nullptr ||
            !implementation->callbackGate->active.load(std::memory_order_acquire)) {
            return;
        }

        implementation->client->RefreshToken(
            applicationID,
            *refreshValue,
            [weakGate, completion](discordpp::ClientResult result,
                                  std::string accessToken,
                                  std::string rotatedRefreshToken,
                                  discordpp::AuthorizationTokenType,
                                  int32_t expiresIn,
                                  std::string) {
                std::shared_ptr<CallbackGate> gate = weakGate.lock();
                if (gate == nullptr || !gate->active.load(std::memory_order_acquire)) {
                    return;
                }
                CompleteTokenOnMainQueue(gate,
                                         completion,
                                         result,
                                         std::move(accessToken),
                                         std::move(rotatedRefreshToken),
                                         expiresIn);
            });
    });
}

- (void)updateToken:(NSString *)accessToken completion:(NokoDiscordOperationCompletion)completion
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr || completion == nil) {
        return;
    }
    const std::optional<std::string> tokenValue = OptionalUTF8(accessToken);
    if (!tokenValue.has_value()) {
        return;
    }

    std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client == nullptr ||
            !implementation->callbackGate->active.load(std::memory_order_acquire)) {
            return;
        }

        implementation->client->UpdateToken(
            discordpp::AuthorizationTokenType::Bearer,
            *tokenValue,
            [weakGate, completion](discordpp::ClientResult result) {
                std::shared_ptr<CallbackGate> gate = weakGate.lock();
                if (gate == nullptr || !gate->active.load(std::memory_order_acquire)) {
                    return;
                }
                CompleteOnMainQueue(gate,
                                    completion,
                                    result.Successful() ? YES : NO,
                                    result.Successful()
                                        ? @"Discord token accepted by the Social SDK."
                                        : @"Discord token could not be accepted.",
                                    IsInvalidGrant(result),
                                    result.Retryable() ? YES : NO);
            });
    });
}

- (void)connect
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr) {
        return;
    }
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client != nullptr &&
            implementation->callbackGate->active.load(std::memory_order_acquire)) {
            implementation->client->Connect();
        }
    });
}

- (void)disconnect
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr) {
        return;
    }
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client != nullptr &&
            implementation->callbackGate->active.load(std::memory_order_acquire)) {
            implementation->client->Disconnect();
        }
    });
}

- (void)abortAuthorization
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr) {
        return;
    }
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client != nullptr &&
            implementation->callbackGate->active.load(std::memory_order_acquire)) {
            implementation->client->AbortAuthorize();
        }
    });
}

- (NSInteger)connectionStatus
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr) {
        return NokoDiscordSocialClientStatusDisconnected;
    }
    return implementation->currentStatus.load(std::memory_order_acquire);
}

- (void)refreshConnectionStatusWithCompletion:(NokoDiscordConnectionStatusCompletion)completion
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr || completion == nil) {
        return;
    }

    std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
    dispatch_async(self.sdkQueue, ^{
        std::shared_ptr<CallbackGate> gate = weakGate.lock();
        if (implementation->client == nullptr || gate == nullptr ||
            !gate->active.load(std::memory_order_acquire)) {
            return;
        }

        const NSInteger status = static_cast<NSInteger>(implementation->client->GetStatus());
        implementation->currentStatus.store(status, std::memory_order_release);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gate->active.load(std::memory_order_acquire)) {
                completion(status);
            }
        });
    });
}

- (void)revokeToken:(NSString *)token completion:(NokoDiscordOperationCompletion)completion
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr || completion == nil) {
        return;
    }
    const std::optional<std::string> tokenValue = OptionalUTF8(token);
    if (!tokenValue.has_value()) {
        return;
    }

    std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
    const uint64_t applicationID = implementation->applicationID;
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client == nullptr ||
            !implementation->callbackGate->active.load(std::memory_order_acquire)) {
            return;
        }

        implementation->client->RevokeToken(
            applicationID,
            *tokenValue,
            [weakGate, completion](discordpp::ClientResult result) {
                std::shared_ptr<CallbackGate> gate = weakGate.lock();
                if (gate == nullptr || !gate->active.load(std::memory_order_acquire)) {
                    return;
                }
                CompleteOnMainQueue(gate,
                                    completion,
                                    result.Successful() ? YES : NO,
                                    result.Successful()
                                        ? @"Discord authorization revoked."
                                        : @"Discord authorization could not be revoked.");
            });
    });
}

- (void)updateRichPresenceWithType:(NSString *)activityType
                              name:(NSString *)activityName
                           details:(NSString *)details
                                state:(NSString *)state
                            startedAt:(NSDate *)startedAt
                              endsAt:(NSDate *)endsAt
                 statusDisplayField:(NSString *)statusDisplayField
                         largeImage:(NSString *)largeImage
                    largeImageText:(NSString *)largeImageText
                           completion:(NokoDiscordOperationCompletion)completion
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr) {
        return;
    }

    std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
    dispatch_async(self.sdkQueue, ^{
        if (implementation->client == nullptr ||
            !implementation->callbackGate->active.load(std::memory_order_acquire)) {
            return;
        }

        discordpp::Activity activity;
        activity.SetType([activityType isEqualToString:@"listening"]
                             ? discordpp::ActivityTypes::Listening
                             : discordpp::ActivityTypes::Playing);
        if (activityName != nil) {
            const char *nameUTF8 = activityName.UTF8String;
            activity.SetName(nameUTF8 == nullptr ? std::string() : std::string(nameUTF8));
        }
        activity.SetDetails(OptionalUTF8(details));
        activity.SetState(OptionalUTF8(state));

        if ([statusDisplayField isEqualToString:@"state"]) {
            activity.SetStatusDisplayType(discordpp::StatusDisplayTypes::State);
        } else if ([statusDisplayField isEqualToString:@"details"]) {
            activity.SetStatusDisplayType(discordpp::StatusDisplayTypes::Details);
        } else if ([statusDisplayField isEqualToString:@"name"]) {
            activity.SetStatusDisplayType(discordpp::StatusDisplayTypes::Name);
        }

        if (const auto imageValue = OptionalUTF8(largeImage); imageValue.has_value()) {
            discordpp::ActivityAssets assets;
            assets.SetLargeImage(imageValue);
            assets.SetLargeText(OptionalUTF8(largeImageText));
            activity.SetAssets(std::move(assets));
        }

        const std::optional<uint64_t> start = UnixMilliseconds(startedAt);
        const std::optional<uint64_t> end = UnixMilliseconds(endsAt);
        if (start.has_value() || end.has_value()) {
            discordpp::ActivityTimestamps timestamps;
            if (start.has_value()) {
                timestamps.SetStart(*start);
            }
            if (end.has_value()) {
                timestamps.SetEnd(*end);
            }
            activity.SetTimestamps(std::move(timestamps));
        }

        implementation->client->UpdateRichPresence(
            std::move(activity),
            [weakGate, completion](discordpp::ClientResult sdkResult) {
                std::shared_ptr<CallbackGate> gate = weakGate.lock();
                if (gate == nullptr || !gate->active.load(std::memory_order_acquire)) {
                    return;
                }

                const BOOL successful = sdkResult.Successful() ? YES : NO;
                CompleteOnMainQueue(gate,
                                    completion,
                                    successful,
                                    successful ? @"Rich presence updated."
                                               : @"Rich presence update failed.");
            });
    });
}

- (void)clearRichPresenceWithCompletion:(NokoDiscordOperationCompletion)completion
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr) {
        return;
    }

    std::weak_ptr<CallbackGate> weakGate = implementation->callbackGate;
    dispatch_async(self.sdkQueue, ^{
        std::shared_ptr<CallbackGate> gate = weakGate.lock();
        if (implementation->client == nullptr || gate == nullptr ||
            !gate->active.load(std::memory_order_acquire)) {
            return;
        }

        implementation->client->ClearRichPresence();
        CompleteOnMainQueue(gate,
                            completion,
                            YES,
                            @"Rich presence clear request sent.");
    });
}

- (void)runCallbacks
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    if (implementation == nullptr) {
        return;
    }

    dispatch_async(self.sdkQueue, ^{
        if (implementation->client != nullptr &&
            implementation->callbackGate->active.load(std::memory_order_acquire)) {
            discordpp::RunCallbacks();
        }
    });
}

- (void)dealloc
{
    NativeImplementation *implementation = static_cast<NativeImplementation *>(_implementation);
    _implementation = nullptr;
    if (implementation == nullptr) {
        return;
    }

    implementation->callbackGate->active.store(false, std::memory_order_release);
    dispatch_queue_t cleanupQueue = self.sdkQueue;
    dispatch_async(cleanupQueue, ^{
        implementation->client.reset();
        delete implementation;
    });
}

@end
