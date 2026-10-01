#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include "../../NokoCord/Native/NokoDiscordSocialClient.mm"

#include <atomic>
#include <memory>
#include <pthread.h>
#include <string>

namespace {

enum class CallbackKind {
    OperationActive,
    OperationInactive,
    TokenActive,
    TokenInactive,
};

struct TestState {
    CallbackKind kind;
    std::atomic<int> callbackCount{0};
    std::atomic<bool> callbackWasMain{false};
    std::atomic<bool> callbackWasSuccessful{false};
    std::atomic<bool> ownerAliveAfterCallerReturned{false};
    std::weak_ptr<CallbackGate> owner;
};

const char *Name(CallbackKind kind)
{
    switch (kind) {
        case CallbackKind::OperationActive: return "operation active";
        case CallbackKind::OperationInactive: return "operation inactive";
        case CallbackKind::TokenActive: return "token active";
        case CallbackKind::TokenInactive: return "token inactive";
    }
}

void Fail(const char *test, const char *message)
{
    NSLog(@"FAIL %s: %s", test, message);
    std::exit(1);
}

void StartCase(CallbackKind kind);

void FinishCase(const std::shared_ptr<TestState> &state)
{
    const char *name = Name(state->kind);
    const bool shouldCallback = state->kind == CallbackKind::OperationActive ||
                                state->kind == CallbackKind::TokenActive;

    if (state->ownerAliveAfterCallerReturned.load(std::memory_order_acquire) != shouldCallback) {
        Fail(name, shouldCallback
            ? "queued callback did not retain its gate after the caller returned"
            : "inactive callback unexpectedly retained its gate");
    }
    if (state->callbackCount.load(std::memory_order_acquire) != (shouldCallback ? 1 : 0)) {
        Fail(name, "callback count was not exactly the expected value");
    }
    if (shouldCallback && !state->callbackWasMain.load(std::memory_order_acquire)) {
        Fail(name, "completion was not delivered on the main thread");
    }
    if (shouldCallback && !state->callbackWasSuccessful.load(std::memory_order_acquire)) {
        Fail(name, "synthetic successful result was not preserved");
    }
    if (!state->owner.expired()) {
        Fail(name, "gate owner remained alive after the main-queue dispatch completed");
    }

    NSLog(@"PASS %s", name);
    const int next = static_cast<int>(state->kind) + 1;
    if (next <= static_cast<int>(CallbackKind::TokenInactive)) {
        StartCase(static_cast<CallbackKind>(next));
    } else {
        NSLog(@"PASS all production callback lifetime cases");
        CFRunLoopStop(CFRunLoopGetMain());
    }
}

void StartCase(CallbackKind kind)
{
    auto state = std::make_shared<TestState>();
    state->kind = kind;
    const bool active = kind == CallbackKind::OperationActive || kind == CallbackKind::TokenActive;
    auto queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_semaphore_t callerReturned = dispatch_semaphore_create(0);

    // Hold the main queue until the SDK-style caller frame has returned. This
    // makes the lifetime boundary deterministic instead of relying on timing.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_semaphore_wait(callerReturned, DISPATCH_TIME_FOREVER);
    });

    dispatch_async(queue, ^{
        std::weak_ptr<CallbackGate> weakGate;
        {
            auto gate = std::make_shared<CallbackGate>();
            gate->active.store(active, std::memory_order_release);
            state->owner = gate;
            weakGate = gate;

            if (kind == CallbackKind::OperationActive || kind == CallbackKind::OperationInactive) {
                NokoDiscordOperationCompletion completion = ^(NokoDiscordOperationResult *result) {
                    dispatch_assert_queue(dispatch_get_main_queue());
                    state->callbackWasMain.store(pthread_main_np() == 1, std::memory_order_release);
                    state->callbackWasSuccessful.store(result.isSuccessful &&
                        [result.message isEqualToString:@"synthetic operation result"],
                        std::memory_order_release);
                    state->callbackCount.fetch_add(1, std::memory_order_acq_rel);
                };
                CompleteOnMainQueue(gate, completion, YES, @"synthetic operation result");
            } else {
                NokoDiscordTokenCompletion completion = ^(NokoDiscordTokenResult *result) {
                    dispatch_assert_queue(dispatch_get_main_queue());
                    state->callbackWasMain.store(pthread_main_np() == 1, std::memory_order_release);
                    state->callbackWasSuccessful.store(result.isSuccessful &&
                        [result.accessToken isEqualToString:@"synthetic-access-token-fixture"] &&
                        [result.refreshToken isEqualToString:@"synthetic-refresh-token-fixture"] &&
                        result.expiresIn == 3600,
                        std::memory_order_release);
                    state->callbackCount.fetch_add(1, std::memory_order_acq_rel);
                };
                discordpp::ClientResult result({}, discordpp::DiscordObjectState::Owned);
                CompleteTokenOnMainQueue(gate,
                                         completion,
                                         result,
                                         "synthetic-access-token-fixture",
                                         "synthetic-refresh-token-fixture",
                                         3600);
            }
        }

        // The caller's local shared_ptr has now gone out of scope.
        state->ownerAliveAfterCallerReturned.store(!weakGate.expired(), std::memory_order_release);
        dispatch_semaphore_signal(callerReturned);

        dispatch_async(dispatch_get_main_queue(), ^{
            // This block is enqueued after the helper's completion. When it runs,
            // the completion block has returned and its captured shared_ptr must
            // have been released.
            FinishCase(state);
        });
    });
}

} // namespace

// ClientResult has no public value factory in this SDK release. Supply a tiny
// deterministic C-API fixture for its accessors so the production helper can
// receive a valid Owned wrapper without constructing/connecting a Discord
// client. The harness still links the installed framework for the production
// translation unit's remaining SDK symbols. No credentials or network calls
// are involved.
extern "C" {

void Discord_ClientResult_Clone(Discord_ClientResult *self, const Discord_ClientResult *other)
{
    *self = *other;
}

void Discord_ClientResult_Drop(Discord_ClientResult *) {}

Discord_ErrorType Discord_ClientResult_Type(Discord_ClientResult *)
{
    return Discord_ErrorType_None;
}

bool Discord_ClientResult_Successful(Discord_ClientResult *)
{
    return true;
}

bool Discord_ClientResult_Retryable(Discord_ClientResult *)
{
    return false;
}

} // extern "C"

int main()
{
    @autoreleasepool {
        StartCase(CallbackKind::OperationActive);
        CFRunLoopRun();
    }
}
