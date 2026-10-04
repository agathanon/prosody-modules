#!/bin/sh
# Generate a throwaway CA and a certificate for the test mail server
# ("mailpit" and "mailpit-tls"), plus Mailpit's SMTP password file, in test/.certs/.
# Uses openssl from the Prosody image, so nothing is needed on the host.
set -eu

cd "$(dirname "$0")"
mkdir -p .certs
if [ -f .certs/mailpit.crt ]; then
	exit 0
fi

docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/.certs:/certs" -w /certs \
	--entrypoint sh prosodyim/prosody:13.0 -c '
	set -e
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Test CA" \
		-keyout ca.key -out ca.crt 2>/dev/null
	openssl req -newkey rsa:2048 -nodes -subj "/CN=mailpit" \
		-keyout mailpit.key -out mailpit.csr 2>/dev/null
	printf "subjectAltName=DNS:mailpit,DNS:mailpit-tls\n" > san.ext
	openssl x509 -req -in mailpit.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
		-days 3650 -extfile san.ext -out mailpit.crt 2>/dev/null
	rm -f mailpit.csr san.ext ca.srl
	chmod 644 ca.crt mailpit.crt mailpit.key
	printf "prosody:secret\n" > smtp-auth
'
echo "Generated test certificates in test/.certs/"
