// Command mavis-session-transfer-client is the Linux counterpart of the
// darwin-x64 binary that the macOS DMG ships under
// resources/resources/session-transfer/darwin-x64/.
//
// The Electron main process (local-runtime-v2, adapters/transfer-client.ts)
// spawns it with NO arguments and an empty environment, writes one JSON
// configuration line to stdin, and reads newline-delimited JSON messages back
// on stdout until the process exits. This file implements exactly that wire
// protocol; see protocol.go for the message shapes and the strictness rules
// the host enforces on them.
package main

import (
	"fmt"
	"os"
)

func main() {
	if err := run(); err != nil {
		// The host ignores stderr entirely (stdio[2] = 'ignore'), so a
		// human-readable diagnostic is only useful when the binary is run
		// by hand. Always terminate with a non-zero code: the host treats
		// a non-zero exit as a failed transfer.
		fmt.Fprintf(errWriter(), "session-transfer: %v\n", err)
		emitResult(false, false)
		os.Exit(1)
	}
	emitResult(true, false)
}
