import Darwin
import Foundation

do {
    let manifestURL = try ManualUpdateTransactionWorker.manifestURLFromArguments(CommandLine.arguments)
    try ManualUpdateTransactionWorker.run(manifestURL: manifestURL) { nonce in
        print("READY \(nonce)")
        fflush(stdout)
    }
    exit(EXIT_SUCCESS)
} catch {
    fputs("NokoCord updater: \(error.localizedDescription)\n", stderr)
    fflush(stderr)
    exit(EXIT_FAILURE)
}
