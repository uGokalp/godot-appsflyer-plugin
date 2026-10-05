#pragma once

#include <cstdint>

// Decides when the SDK's start must be called. Every method that can release the gate returns
// true when start must be called now; that consumes the current session's readiness.
struct SessionGate {
	bool start_requested = false;
	bool session_ready = false;
	// The SDK also reports readiness on inactive->active transitions (ATT or system sheets).
	bool started_this_foreground = false;
	bool awaiting_consent = false;
	bool consent_retried = false;
	uint64_t consent_generation = 0;

	bool request_start() {
		start_requested = true;
		return release();
	}

	bool on_session_ready() {
		session_ready = true;
		return release();
	}

	void on_background() {
		session_ready = false;
		started_this_foreground = false;
	}

	uint64_t begin_consent() {
		awaiting_consent = true;
		consent_retried = false;
		return ++consent_generation;
	}

	// The prompt came back undetermined: true means ask once more on the next activation,
	// false means give up waiting and resolve_consent() without an answer.
	bool retry_undetermined_consent(uint64_t p_generation) {
		if (!awaiting_consent || p_generation != consent_generation || consent_retried) {
			return false;
		}
		consent_retried = true;
		return true;
	}

	bool resolve_consent(uint64_t p_generation) {
		if (!awaiting_consent || p_generation != consent_generation) {
			return false;
		}
		awaiting_consent = false;
		return release();
	}

private:
	bool release() {
		if (!start_requested || !session_ready || awaiting_consent || started_this_foreground) {
			return false;
		}
		session_ready = false;
		started_this_foreground = true;
		return true;
	}
};
