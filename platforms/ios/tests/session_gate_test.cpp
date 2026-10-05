#include "session_gate.h"

#include <cstdio>

static int failures = 0;

#define CHECK(condition)                                                    \
	do {                                                                    \
		if (!(condition)) {                                                 \
			std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #condition); \
			failures++;                                                     \
		}                                                                   \
	} while (0)

static void start_without_consent() {
	SessionGate gate;
	CHECK(!gate.request_start());
	CHECK(gate.on_session_ready());
}

static void start_requested_after_session_ready() {
	SessionGate gate;
	CHECK(!gate.on_session_ready());
	CHECK(gate.request_start());
}

static void pending_consent_blocks_start_until_resolved() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	CHECK(!gate.request_start());
	CHECK(!gate.on_session_ready());
	CHECK(gate.resolve_consent(generation));
	CHECK(!gate.resolve_consent(generation));
}

static void consent_resolved_before_start_requested() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	CHECK(!gate.on_session_ready());
	CHECK(!gate.resolve_consent(generation));
	CHECK(gate.request_start());
}

static void timeout_and_late_answer_release_once() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	gate.request_start();
	gate.on_session_ready();
	CHECK(gate.resolve_consent(generation));
	gate.on_background();
	CHECK(gate.on_session_ready());
	CHECK(!gate.resolve_consent(generation));
}

static void stale_generation_does_not_release_a_later_request() {
	SessionGate gate;
	uint64_t first = gate.begin_consent();
	gate.request_start();
	CHECK(!gate.on_session_ready());
	CHECK(gate.resolve_consent(first));
	gate.on_background();
	uint64_t second = gate.begin_consent();
	CHECK(!gate.on_session_ready());
	CHECK(!gate.resolve_consent(first));
	CHECK(gate.resolve_consent(second));
}

static void starts_once_per_foreground() {
	SessionGate gate;
	gate.request_start();
	CHECK(gate.on_session_ready());
	CHECK(!gate.request_start());
	gate.on_background();
	CHECK(!gate.request_start());
	CHECK(gate.on_session_ready());
}

static void background_resets_readiness_while_consent_pending() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	gate.request_start();
	gate.on_session_ready();
	gate.on_background();
	CHECK(!gate.resolve_consent(generation));
	CHECK(gate.on_session_ready());
}

static void consent_requested_after_a_started_session_gates_the_next_foreground() {
	SessionGate gate;
	gate.request_start();
	CHECK(gate.on_session_ready());
	uint64_t generation = gate.begin_consent();
	gate.on_background();
	CHECK(!gate.on_session_ready());
	CHECK(gate.resolve_consent(generation));
}

static void undetermined_consent_retries_once_then_releases() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	gate.request_start();
	CHECK(!gate.on_session_ready());
	CHECK(gate.retry_undetermined_consent(generation));
	CHECK(!gate.retry_undetermined_consent(generation));
	CHECK(gate.resolve_consent(generation));
}

static void undetermined_retry_is_per_request_and_ignores_stale_generations() {
	SessionGate gate;
	uint64_t first = gate.begin_consent();
	CHECK(gate.retry_undetermined_consent(first));
	gate.resolve_consent(first);
	CHECK(!gate.retry_undetermined_consent(first));
	uint64_t second = gate.begin_consent();
	CHECK(!gate.retry_undetermined_consent(first));
	CHECK(gate.retry_undetermined_consent(second));
}

static void session_ready_again_in_the_same_foreground_does_not_restart() {
	SessionGate gate;
	gate.request_start();
	CHECK(gate.on_session_ready());
	CHECK(!gate.on_session_ready());
	CHECK(!gate.request_start());
}

static void session_ready_after_background_starts_again() {
	SessionGate gate;
	gate.request_start();
	CHECK(gate.on_session_ready());
	gate.on_background();
	CHECK(gate.on_session_ready());
}

static void att_sheet_dismissal_does_not_start_a_second_session() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	gate.request_start();
	CHECK(!gate.on_session_ready());
	CHECK(gate.resolve_consent(generation));
	CHECK(!gate.on_session_ready());
}

static void suppressed_retry_expires_without_activation() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	gate.request_start();
	gate.on_session_ready();
	CHECK(gate.retry_undetermined_consent(generation));
	CHECK(gate.expire_consent_retry(generation));
	CHECK(!gate.begin_consent_retry(generation));
	CHECK(!gate.expire_consent_retry(generation));
}

static void activation_and_fallback_only_prompt_once_and_keep_waiting_for_answer() {
	SessionGate gate;
	uint64_t generation = gate.begin_consent();
	gate.request_start();
	gate.on_session_ready();
	CHECK(gate.retry_undetermined_consent(generation));
	CHECK(gate.begin_consent_retry(generation));
	CHECK(!gate.begin_consent_retry(generation));
	CHECK(!gate.expire_consent_retry(generation));
	CHECK(!gate.request_start());
	CHECK(gate.resolve_consent(generation));
}

static void stale_retry_cannot_prompt_or_release_a_new_request() {
	SessionGate gate;
	uint64_t first = gate.begin_consent();
	gate.request_start();
	gate.on_session_ready();
	CHECK(gate.retry_undetermined_consent(first));
	CHECK(gate.resolve_consent(first));
	gate.on_background();
	uint64_t second = gate.begin_consent();
	gate.on_session_ready();
	CHECK(!gate.begin_consent_retry(second));
	CHECK(gate.retry_undetermined_consent(second));
	CHECK(!gate.begin_consent_retry(first));
	CHECK(!gate.expire_consent_retry(first));
	CHECK(gate.expire_consent_retry(second));
}

int main() {
	start_without_consent();
	start_requested_after_session_ready();
	pending_consent_blocks_start_until_resolved();
	consent_resolved_before_start_requested();
	timeout_and_late_answer_release_once();
	stale_generation_does_not_release_a_later_request();
	starts_once_per_foreground();
	background_resets_readiness_while_consent_pending();
	consent_requested_after_a_started_session_gates_the_next_foreground();
	undetermined_consent_retries_once_then_releases();
	undetermined_retry_is_per_request_and_ignores_stale_generations();
	session_ready_again_in_the_same_foreground_does_not_restart();
	session_ready_after_background_starts_again();
	att_sheet_dismissal_does_not_start_a_second_session();
	suppressed_retry_expires_without_activation();
	activation_and_fallback_only_prompt_once_and_keep_waiting_for_answer();
	stale_retry_cannot_prompt_or_release_a_new_request();
	if (failures) {
		std::fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	std::puts("session_gate_test: all passed");
	return 0;
}
