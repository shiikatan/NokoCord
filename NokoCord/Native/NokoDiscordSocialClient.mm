#import "NokoDiscordSocialClient.h"

#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <memory>
#include <optional>
#include <string>

@interface NokoDiscordOperationResult ()

@property(nonatomic, readwrite, getter=isSuccessful) BOOL successful;
@property(nonatomic, readwrite, copy) NSString *message;

- (instancetype)initWithSuccessful:(BOOL)successful message:(NSString *)message;

@end

namespace {

struct CallbackGate {
    std::atomic_bool active{true};
};

struct NativeImplementation {
    std::unique_ptr<discordpp::Client> client;
    std::shared_ptr<CallbackGate> callbackGate = std::make_shared<CallbackGate>();
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

void CompleteOnMainQueue(const std::shared_ptr<CallbackGate> &gate,
                         NokoDiscordOperationCompletion completion,
                         BOOL successful,
                         NSString *message)
{
    if (completion == nil || !gate->active.load(std::memory_order_acquire)) {
        return;
    }

    NokoDiscordOperationResult *result = [[NokoDiscordOperationResult alloc]
        initWithSuccessful:successful
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

- (instancetype)initWithSuccessful:(BOOL)successful message:(NSString *)message
{
    self = [super init];
    if (self != nil) {
        _successful = successful;
        _message = [message copy];
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
        _implementation = implementation;

        dispatch_sync(self.sdkQueue, ^{
            implementation->client = std::make_unique<discordpp::Client>();
            if (getenv("NOKOCORD_ACTIVITY_DIAGNOSTICS") != nullptr) {
                implementation->client->AddLogCallback(
                    [](std::string message, discordpp::LoggingSeverity severity) {
                        std::fprintf(stderr, "Discord SDK [%s]: %s\n",
                                     discordpp::EnumToString(severity), message.c_str());
                    },
                    discordpp::LoggingSeverity::Verbose);
            }
            implementation->client->SetApplicationId(applicationID);
        });
    }
    return self;
}

- (void)updateRichPresenceWithDetails:(NSString *)details
                                state:(NSString *)state
                            startedAt:(NSDate *)startedAt
                              endsAt:(NSDate *)endsAt
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
        activity.SetDetails(OptionalUTF8(details));
        activity.SetState(OptionalUTF8(state));

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
                std::string resultMessage = sdkResult.ToString();
                if (resultMessage.empty()) {
                    resultMessage = successful ? "Rich presence updated." : "Rich presence update failed.";
                }
                CompleteOnMainQueue(gate,
                                    completion,
                                    successful,
                                    StringFromUTF8(resultMessage));
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
