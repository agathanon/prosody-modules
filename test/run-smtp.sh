#!/bin/sh
# Integration tests for modules that send email (mod_smtp_async,
# mod_recovery_email_notify, mod_recovery_email_reset): send real email from
# the test Prosody to Mailpit, and check what arrives.
#
# Usage: test/run-smtp.sh
set -eu

cd "$(dirname "$0")/.."
test/certs.sh

compose() {
	docker compose -f test/docker-compose.yml -p prosody-modules-test "$@"
}

shell() {
	compose exec -T prosody prosodyctl shell "$1" | sed -n 's/^Result: //p'
}

# send HOST TO SUBJECT: send a message from HOST's mod_smtp_async, wait for
# the outcome and print it ("ok" or "error: ...")
send() {
	shell "> local m = require'prosody.core.modulemanager'.get_module('$1', 'smtp_async');
		prosody.smtp_test = 'pending';
		m.send({ to = '$2'; subject = '$3'; body = 'Hello from $1.\nSecond line.' }):next(
			function () prosody.smtp_test = 'ok'; end,
			function (e) prosody.smtp_test = 'error: '..tostring(e.text); end);
		return 'started'" >/dev/null
	i=0
	while [ "$i" -lt 30 ]; do
		result=$(shell "> return prosody.smtp_test")
		if [ "$result" != "pending" ]; then
			echo "$result"
			return
		fi
		i=$((i + 1))
		sleep 1
	done
	echo "error: no result after 30s"
}

# messages SERVICE: Mailpit's message list as JSON
messages() {
	compose exec -T "$1" wget -qO- http://localhost:8025/api/v1/messages
}

failures=0
check() {
	if [ "$2" = "$3" ]; then
		echo "pass  $1"
	else
		echo "FAIL  $1: expected '$3', got '$2'"
		failures=$((failures + 1))
	fi
}
check_contains() {
	case "$2" in
		*"$3"*) echo "pass  $1" ;;
		*) echo "FAIL  $1: '$3' not found"; failures=$((failures + 1)) ;;
	esac
}

trap 'compose down -v >/dev/null 2>&1' EXIT
compose up -d --wait prosody >/dev/null 2>&1

check "STARTTLS, login and certificate check" \
	"$(send localhost alice@example.org 'STARTTLS test Grüße')" "ok"
check_contains "message arrived with its UTF-8 subject" "$(messages mailpit)" '"Subject":"STARTTLS test Grüße"'
check_contains "message has the configured sender" "$(messages mailpit)" '"Address":"noreply@localhost"'

check "implicit TLS" "$(send other.localhost bob@example.org 'Implicit TLS test')" "ok"
check_contains "message arrived over implicit TLS" "$(messages mailpit-tls)" '"Subject":"Implicit TLS test"'

check "certificate name mismatch is refused" \
	"$(send anon.localhost carol@example.org 'Should not arrive')" \
	"error: mail server certificate does not match wrongname"

check "untrusted certificate is refused" \
	"$(send untrusted.localhost dave@example.org 'Should not arrive')" \
	"error: TLS handshake failed: certificate verify failed"

check "invalid message is rejected" "$(send localhost 'not-an-address' 'x')" "error: invalid recipient address"

# mod_recovery_email_notify, end to end: codes and notices arrive by email

# mail_ids ADDRESS: IDs of messages Mailpit (STARTTLS) received for ADDRESS
mail_ids() {
	compose exec -T mailpit wget -qO- "http://localhost:8025/api/v1/search?query=to:$1" \
		| grep -o '"ID":"[^"]*"' | cut -d'"' -f4
}

# mail_text ID: the decoded plain-text body of a message
mail_text() {
	compose exec -T mailpit wget -qO- "http://localhost:8025/api/v1/message/$1" \
		| grep -o '"Text":"[^"]*"'
}

# wait_for_mail ADDRESS COUNT: wait until ADDRESS has COUNT messages
wait_for_mail() {
	i=0
	while [ "$i" -lt 20 ] && [ "$(mail_ids "$1" | wc -l)" -lt "$2" ]; do
		i=$((i + 1))
		sleep 0.5
	done
}

# code_for ADDRESS: the code in the most recent verification email to ADDRESS
code_for() {
	for id in $(mail_ids "$1"); do
		mail_text "$id" | grep -o 'code is: [0-9]\{6\}' | cut -d' ' -f3 && return
	done
}

verify() {
	shell "> return tostring((require'prosody.core.modulemanager'.get_module('localhost', 'recovery_email').verify('notify', '$1')))"
}

shell "recovery:set('notify@localhost', 'notify-one@example.org')" >/dev/null
wait_for_mail notify-one@example.org 1
code=$(code_for notify-one@example.org)
check "verification email carries a working code" "$(verify "$code")" "true"

shell "recovery:set('notify@localhost', 'notify-two@example.org')" >/dev/null
wait_for_mail notify-one@example.org 2
check "replacing a verified address notifies it" "$(mail_ids notify-one@example.org | wc -l | tr -d ' ')" "2"
notice=$(mail_text "$(mail_ids notify-one@example.org | head -n 1)")
check_contains "notice says an administrator made the change" "$notice" "by a server administrator"
check_contains "notice names the admin contact fallback" "$notice" "Contact the administrator of localhost."

wait_for_mail notify-two@example.org 1
check "new address gets its own code" "$(verify "$(code_for notify-two@example.org)")" "true"
shell "recovery:clear('notify@localhost')" >/dev/null
wait_for_mail notify-two@example.org 2
notice=$(mail_text "$(mail_ids notify-two@example.org | head -n 1)")
check_contains "removing a verified address notifies it" "$notice" "was removed"

# mod_recovery_email_reset, end to end: request a link, use it, sign in

# web PATH [POST-DATA]: fetch a reset page from reset.localhost, as a browser would
web() {
	if [ -n "${2:-}" ]; then
		compose exec -T prosody wget -qO- --content-on-error --header "Host: reset.localhost" \
			--post-data "$2" "http://127.0.0.1:5280$1" 2>/dev/null || true
	else
		compose exec -T prosody wget -qO- --content-on-error --header "Host: reset.localhost" \
			"http://127.0.0.1:5280$1" 2>/dev/null || true
	fi
}

users="require'prosody.core.usermanager'"
recovery="require'prosody.core.modulemanager'.get_module('reset.localhost', 'recovery_email')"
shell "> return tostring(($users.create_user('resetter', 'old password', 'reset.localhost')))" >/dev/null
shell "> return tostring(($recovery.set('resetter', 'resetter@example.org')))" >/dev/null
wait_for_mail resetter@example.org 1
reset_code=$(code_for resetter@example.org)
check "reset test account has a verified address" \
	"$(shell "> return tostring(($recovery.verify('resetter', '$reset_code')))")" "true"

requested=$(web /recovery_email_reset "jid=resetter%40reset.localhost")
check_contains "reset request is answered" "$requested" "we&apos;ve sent a link to it"
check "unknown account gets the same answer" "$(web /recovery_email_reset "jid=nobody%40reset.localhost")" "$requested"

wait_for_mail resetter@example.org 2
reset_path=$(for id in $(mail_ids resetter@example.org); do
	mail_text "$id" | grep -o '/recovery_email_reset/reset/[A-Za-z0-9_-]*' && break
done | head -n 1)
check_contains "reset link opens the password form" "$(web "$reset_path")" \
	"Choose a new password for <strong>resetter@reset.localhost</strong>"
check_contains "mismatched passwords are refused" \
	"$(web "$reset_path" "password=new+password+1&confirm=something+else")" "The passwords don&apos;t match."
check_contains "new password is accepted" \
	"$(web "$reset_path" "password=new+password+1&confirm=new+password+1")" "Your password has been changed."
check "new password works" \
	"$(shell "> return tostring(($users.test_password('resetter', 'reset.localhost', 'new password 1')))")" "true"
check "old password no longer works" \
	"$(shell "> return tostring(($users.test_password('resetter', 'reset.localhost', 'old password')))")" "nil"
check_contains "used link is refused" "$(web "$reset_path")" "This link is invalid or has expired."
wait_for_mail resetter@example.org 3
resetter_mail=$(compose exec -T mailpit wget -qO- "http://localhost:8025/api/v1/search?query=to:resetter@example.org")
check_contains "confirmation email arrives" "$resetter_mail" "The password for resetter@reset.localhost was reset"
check_contains "notifier uses smtp_async_from when recovery_email_from isn't set" \
	"$resetter_mail" '"Address":"accounts@reset.localhost"'


if compose logs prosody 2>&1 | grep -qF "${reset_path##*/}"; then
	echo "FAIL  logs contain a reset token"
	failures=$((failures + 1))
else
	echo "pass  logs contain no reset tokens"
fi

if compose logs prosody 2>&1 | grep -E "recovery_email" | grep -qE "$code|notify-one@|notify-two@"; then
	echo "FAIL  logs contain a verification code or a full address"
	failures=$((failures + 1))
else
	echo "pass  logs contain no verification codes or full addresses"
fi

if compose logs prosody 2>&1 | grep -E "smtp_async" | grep -qE "alice@|bob@|carol@|dave@|secret|Second line"; then
	echo "FAIL  logs contain a full address, the password or message content"
	failures=$((failures + 1))
else
	echo "pass  logs contain no full addresses, password or message content"
fi

if [ "$failures" -ne 0 ]; then
	compose logs prosody | grep -E "smtp_async|error|warn" | tail -n 30
	echo "$failures check(s) failed"
	exit 1
fi
echo "All checks passed"
