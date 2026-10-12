package odid3_tests

import "core:testing"

@(require) import odid3 "../"

// Replaced by the first real tests once the package has a public API.
@(test)
package_builds :: proc(t: ^testing.T) {
	testing.expect(t, true)
}
